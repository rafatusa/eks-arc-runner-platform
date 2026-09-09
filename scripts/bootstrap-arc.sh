#!/usr/bin/env bash
#
# Installs Actions Runner Controller and registers the ephemeral runner pool.
#
# Order matters:
#   1. cert-manager  — ARC's admission webhooks need TLS certificates
#   2. ARC controller — with the GitHub credential it uses to register runners
#   3. Runner toolchain image — built and pushed to ECR
#   4. RunnerDeployment + HorizontalRunnerAutoscaler
#
# Idempotent; re-running upgrades in place.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd helm
require_cmd kubectl
require_cmd aws
require_cmd docker
require_cmd terraform

CERT_MANAGER_VERSION="v1.16.2"
ARC_CHART_VERSION="0.23.7"
ARC_NAMESPACE="actions-runner-system"

: "${GITHUB_PAT:?GITHUB_PAT must be set (repo-scoped PAT used by ARC to register runners)}"
: "${RUNNER_REPOSITORY:?RUNNER_REPOSITORY must be set (owner/repo)}"

log "Reading infrastructure outputs"
AWS_REGION_VALUE="$(tf_output aws_region)"
ECR_URL="$(tf_output ecr_repository_url)"
RUNNER_ROLE_ARN="$(tf_output runner_role_arn)"
ECR_REGISTRY="${ECR_URL%%/*}"
RUNNER_IMAGE="${ECR_URL}:runner-latest"
info "repository=${RUNNER_REPOSITORY}"
info "runner image=${RUNNER_IMAGE}"

ensure_kubeconfig

##############################################################################
log "Installing cert-manager (ARC webhook dependency)"
##############################################################################
kubectl apply -f \
  "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

kubectl -n cert-manager rollout status deployment/cert-manager --timeout=10m
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=10m
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=10m

# The webhook reports Ready before it reliably serves admission requests.
log "Waiting for the cert-manager webhook to serve admission requests"
retry 30 10 kubectl -n cert-manager get endpoints cert-manager-webhook \
  -o jsonpath='{.subsets[0].addresses[0].ip}' \
  || fail "cert-manager webhook never published an endpoint"
sleep 20

##############################################################################
log "Building the runner toolchain image"
##############################################################################
aws ecr get-login-password --region "${AWS_REGION_VALUE}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# Reuse the published image when it already exists: rebuilding a ~1.5GB
# toolchain on every deploy adds minutes without changing anything.
if aws ecr describe-images \
      --repository-name "$(tf_output ecr_repository_name)" \
      --image-ids imageTag=runner-latest \
      --region "${AWS_REGION_VALUE}" >/dev/null 2>&1; then
  info "runner image already present in ECR — skipping rebuild"
else
  info "building ${RUNNER_IMAGE}"
  docker build -t "${RUNNER_IMAGE}" "${REPO_ROOT}/runner-image"
  docker push "${RUNNER_IMAGE}"
fi

##############################################################################
log "Installing Actions Runner Controller"
##############################################################################
kubectl create namespace "${ARC_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# The controller reads its GitHub credential from this secret. The value is
# passed through a private temp file rather than a command-line argument, so it
# never appears in a process listing, and never in a committed manifest.
CRED_DIR="$(mktemp -d)"
chmod 700 "${CRED_DIR}"
trap 'rm -rf "${CRED_DIR}"' EXIT

( umask 077; printf '%s' "${GITHUB_PAT}" > "${CRED_DIR}/github_token" )

kubectl -n "${ARC_NAMESPACE}" create secret generic controller-manager \
  --from-file="github_token=${CRED_DIR}/github_token" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -f "${CRED_DIR}/github_token"

helm repo add actions-runner-controller \
  https://actions-runner-controller.github.io/actions-runner-controller >/dev/null
helm repo update >/dev/null

# NOTE: metrics.serviceMonitor is a TABLE in this chart
# ({enable, interval, namespace, timeout}). Setting the parent key to a scalar
# replaces the whole map and the chart's template then fails to render with
# "can't evaluate field enable in type interface {}". Always set the LEAF key.
# The ServiceMonitor stays disabled because there is no Prometheus Operator
# (and therefore no ServiceMonitor CRD) in this cluster.
helm upgrade --install actions-runner-controller \
  actions-runner-controller/actions-runner-controller \
  --namespace "${ARC_NAMESPACE}" \
  --version "${ARC_CHART_VERSION}" \
  --set authSecret.create=false \
  --set authSecret.name=controller-manager \
  --set replicaCount=1 \
  --set "githubWebhookServer.enabled=false" \
  --set "metrics.serviceMonitor.enable=false" \
  --wait --timeout 10m

kubectl -n "${ARC_NAMESPACE}" rollout status \
  deployment/actions-runner-controller --timeout=10m

##############################################################################
log "Applying the RunnerDeployment and HorizontalRunnerAutoscaler"
##############################################################################
RUNNER_REPOSITORY_NAME="${RUNNER_REPOSITORY##*/}"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "${CRED_DIR}" "${RENDER_DIR}"' EXIT

# Placeholder substitution keeps account/repo specifics out of the committed
# manifests; sed is avoided because ARNs and image refs contain slashes.
render() {
  local src="$1" dst="$2"
  RUNNER_ROLE_ARN="${RUNNER_ROLE_ARN}" \
  RUNNER_IMAGE="${RUNNER_IMAGE}" \
  AWS_REGION_VALUE="${AWS_REGION_VALUE}" \
  RUNNER_REPOSITORY="${RUNNER_REPOSITORY}" \
  RUNNER_REPOSITORY_NAME="${RUNNER_REPOSITORY_NAME}" \
  python3 - "$src" "$dst" <<'PY'
import os, sys

src, dst = sys.argv[1], sys.argv[2]
mapping = {
    "__RUNNER_ROLE_ARN__": os.environ["RUNNER_ROLE_ARN"],
    "__RUNNER_IMAGE__": os.environ["RUNNER_IMAGE"],
    "__AWS_REGION__": os.environ["AWS_REGION_VALUE"],
    "__GITHUB_REPOSITORY__": os.environ["RUNNER_REPOSITORY"],
    "__GITHUB_REPOSITORY_NAME__": os.environ["RUNNER_REPOSITORY_NAME"],
}

with open(src, "r", encoding="utf-8") as fh:
    content = fh.read()
for placeholder, value in mapping.items():
    content = content.replace(placeholder, value)
with open(dst, "w", encoding="utf-8") as fh:
    fh.write(content)
PY
}

render "${REPO_ROOT}/k8s/arc/runner-deployment.yaml" "${RENDER_DIR}/runner-deployment.yaml"
render "${REPO_ROOT}/k8s/arc/horizontal-runner-autoscaler.yaml" "${RENDER_DIR}/hra.yaml"

kubectl apply -f "${RENDER_DIR}/runner-deployment.yaml"
kubectl apply -f "${RENDER_DIR}/hra.yaml"

##############################################################################
log "Waiting for runners to register with GitHub"
##############################################################################
runner_is_ready() {
  local ready
  ready="$(kubectl -n "${ARC_NAMESPACE}" get runners \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -c '^Running$' || true)"
  [ "${ready}" -ge 1 ]
}

retry 40 15 runner_is_ready \
  || fail "no runner pod reached the Running phase — check 'kubectl -n ${ARC_NAMESPACE} describe runners' and the credential scopes"

log "Actions Runner Controller is live"
kubectl -n "${ARC_NAMESPACE}" get runnerdeployments,horizontalrunnerautoscalers,runners,pods
