#!/usr/bin/env bash
#
# Deploys (or upgrades) the Spring Boot application with Helm and waits for the
# rollout plus the ALB address to become available.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd helm
require_cmd kubectl
require_cmd terraform

APP_NAMESPACE="${APP_NAMESPACE:-runner-platform}"
RELEASE_NAME="${RELEASE_NAME:-runner-platform-api}"

log "Reading infrastructure outputs"
ECR_URL="$(tf_output ecr_repository_url)"
ALB_SG_ID="$(tf_output alb_security_group_id)"

IMAGE_TAG="${APP_IMAGE_TAG:-${IMAGE_TAG:-${GITHUB_SHA:-latest}}}"
IMAGE_TAG="${IMAGE_TAG:0:40}"
info "deploying ${ECR_URL}:${IMAGE_TAG} into namespace ${APP_NAMESPACE}"

ensure_kubeconfig

kubectl create namespace "${APP_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

log "Running helm upgrade --install"
helm upgrade --install "${RELEASE_NAME}" "${REPO_ROOT}/helm/app" \
  --namespace "${APP_NAMESPACE}" \
  --set "image.repository=${ECR_URL}" \
  --set "image.tag=${IMAGE_TAG}" \
  --set "ingress.securityGroupId=${ALB_SG_ID}" \
  --set "env.APP_VERSION=${IMAGE_TAG}" \
  --wait --timeout 10m

log "Waiting for the deployment rollout"
kubectl -n "${APP_NAMESPACE}" rollout status "deployment/${RELEASE_NAME}" --timeout=10m

log "Waiting for the ALB address to be provisioned"
alb_address() {
  local addr
  addr="$(kubectl -n "${APP_NAMESPACE}" get ingress "${RELEASE_NAME}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "${addr}" ]
}

retry 40 15 alb_address \
  || fail "the ingress never received an ALB hostname — check the aws-load-balancer-controller logs"

ALB_HOST="$(kubectl -n "${APP_NAMESPACE}" get ingress "${RELEASE_NAME}" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

log "Application deployed"
kubectl -n "${APP_NAMESPACE}" get pods,svc,ingress
info "ALB hostname resolved (verification stage will health-check it)"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "ALB_HOST=${ALB_HOST}" >> "${GITHUB_ENV}"
fi
