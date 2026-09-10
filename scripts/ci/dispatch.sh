#!/usr/bin/env bash
#
# Dispatches one CI stage INTO the EKS cluster and mirrors its result.
#
# WHY THIS EXISTS
# ---------------
# The build and validation pipelines are meant to execute on the ephemeral ARC
# self-hosted runners. The UDAP pipeline spec has no runner-placement key (the
# renderer always emits `runs-on: ubuntu-latest`) and workflow files cannot be
# hand-authored, so a GitHub job cannot target `[self-hosted, eks]` directly.
#
# Instead the GitHub-hosted job acts as a thin controller: it submits a
# Kubernetes Job that runs the real stage inside the cluster on the SAME runner
# toolchain image the ARC runners use, streams its logs back, and exits with the
# in-cluster exit code. The work runs in Kubernetes; the job is honestly a shim,
# not an ARC runner. docs/self-hosted-workflows/ holds the native replacements.
#
# Usage: dispatch.sh <stage-id> <script-path-relative-to-repo-root> [deadline-seconds]

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

require_cmd kubectl
require_cmd aws
require_cmd terraform
require_cmd python3

STAGE_ID="${1:?stage id required}"
STAGE_COMMAND="${2:?stage script path required}"
DEADLINE_SECONDS="${3:-2400}"

CI_NAMESPACE="${CI_NAMESPACE:-ci-dispatch}"
COMMIT_SHA="${GITHUB_SHA:?GITHUB_SHA required}"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
: "${DISPATCH_GITHUB_TOKEN:?DISPATCH_GITHUB_TOKEN required (credential the in-cluster job clones with)}"
: "${TF_STATE_BUCKET:?TF_STATE_BUCKET required}"
: "${PROJECT_NAME:?PROJECT_NAME required}"
: "${AWS_REGION:?AWS_REGION required}"
# The dispatched job runs `terraform init` against the state bucket. The runner
# IRSA role deliberately has NO S3 access (docs/DEPLOYMENT.md), and its trust
# policy only admits system:serviceaccount:actions-runner-system:github-runner
# — the dispatched job runs in ${CI_NAMESPACE}, so AssumeRoleWithWebIdentity is
# rejected there outright. Static keys are therefore the job's ONLY working
# credential source, exactly as the hosted controller uses above.
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID required (the dispatched job's only credential for terraform init)}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY required (the dispatched job's only credential for terraform init)}"

log "Resolving cluster and runner image"
terraform -chdir="${INFRA_DIR}" init -input=false -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${PROJECT_NAME}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" >/dev/null

ECR_URL="$(tf_output ecr_repository_url)"
ECR_REPOSITORY="${ECR_URL##*/}"
RUNNER_TAG="${RUNNER_TAG:-runner-latest}"

# RESOLVE THE FLOATING TAG TO AN IMMUTABLE DIGEST.
#
# The Job template sets imagePullPolicy: IfNotPresent, so the kubelet's cache
# key is the image REFERENCE. With a mutable tag like `runner-latest` a node
# that pulled the tag once NEVER re-pulls it: repointing the tag in ECR has no
# effect on any node that already has it cached, and the Job silently boots a
# months-old toolchain. That is not hypothetical — it cost this project several
# recovery attempts: `runner-latest` in ECR carried the current image while the
# node still served an older digest that predated the terraform install, and
# every dispatched stage that ran terraform died with
# "required command not found: terraform" on an image that demonstrably had it.
#
# Pinning to @sha256:... makes the cache key content-addressed: a changed image
# is a changed reference, so IfNotPresent is correct AND the pull is skipped
# only when the bytes really are already there. Tags are mutable, digests are
# not (OCI image-spec).
log "Resolving the runner image digest"
RUNNER_DIGEST="$(aws ecr describe-images \
  --repository-name "${ECR_REPOSITORY}" \
  --region "${AWS_REGION}" \
  --image-ids "imageTag=${RUNNER_TAG}" \
  --query 'imageDetails[0].imageDigest' \
  --output text 2>/dev/null || true)"

if [ -z "${RUNNER_DIGEST}" ] || [ "${RUNNER_DIGEST}" = "None" ]; then
  fail "could not resolve a digest for ${ECR_URL}:${RUNNER_TAG} — the runner image must be built and pushed before stages can be dispatched"
fi

RUNNER_IMAGE="${ECR_URL}@${RUNNER_DIGEST}"
info "runner image: ${ECR_URL}:${RUNNER_TAG}"
info "resolved digest: ${RUNNER_DIGEST}"

ensure_kubeconfig

##############################################################################
log "Preparing the dispatch namespace"
##############################################################################
kubectl create namespace "${CI_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# The service account carries the runner role annotation for cluster RBAC and
# for any ECR call that the role's own policy allows. It is NOT the credential
# source for terraform: the role's trust policy is scoped to the
# actions-runner-system namespace, so IRSA does not resolve here. The static
# AWS_* keys in the secret below take precedence in the credential chain and
# are what actually authenticates the dispatched stages.
RUNNER_ROLE_ARN="$(tf_output runner_role_arn)"
kubectl -n "${CI_NAMESPACE}" create serviceaccount github-runner \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${CI_NAMESPACE}" annotate serviceaccount github-runner \
  "eks.amazonaws.com/role-arn=${RUNNER_ROLE_ARN}" --overwrite

kubectl create clusterrolebinding "ci-dispatch-${CI_NAMESPACE}" \
  --clusterrole=github-runner-deployer \
  --serviceaccount="${CI_NAMESPACE}:github-runner" \
  --dry-run=client -o yaml | kubectl apply -f -

# Values the in-cluster job needs. Written through private temp files rather
# than command-line arguments, so no value appears in a process listing; they
# live only in the cluster, never in a committed file.
CRED_DIR="$(mktemp -d)"
chmod 700 "${CRED_DIR}"
RENDERED="$(mktemp)"
trap 'rm -rf "${CRED_DIR}"; rm -f "${RENDERED}"' EXIT

(
  umask 077
  printf '%s' "${PROJECT_NAME}"           > "${CRED_DIR}/project_name"
  printf '%s' "${TF_STATE_BUCKET}"        > "${CRED_DIR}/tf_state_bucket"
  printf '%s' "${DISPATCH_GITHUB_TOKEN}"  > "${CRED_DIR}/github_token"
  printf '%s' "${AWS_ACCESS_KEY_ID}"      > "${CRED_DIR}/aws_access_key_id"
  printf '%s' "${AWS_SECRET_ACCESS_KEY}"  > "${CRED_DIR}/aws_secret_access_key"
)

kubectl -n "${CI_NAMESPACE}" create secret generic ci-dispatch-secrets \
  --from-file="project_name=${CRED_DIR}/project_name" \
  --from-file="tf_state_bucket=${CRED_DIR}/tf_state_bucket" \
  --from-file="github_token=${CRED_DIR}/github_token" \
  --from-file="aws_access_key_id=${CRED_DIR}/aws_access_key_id" \
  --from-file="aws_secret_access_key=${CRED_DIR}/aws_secret_access_key" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -rf "${CRED_DIR}"

##############################################################################
log "Submitting the Kubernetes Job for stage '${STAGE_ID}'"
##############################################################################
JOB_NAME="ci-${STAGE_ID//_/-}-${COMMIT_SHA:0:8}-$(date +%s)"
JOB_NAME="$(printf '%s' "${JOB_NAME}" | tr '[:upper:]' '[:lower:]' | cut -c1-60)"

JOB_NAME="${JOB_NAME}" \
CI_NAMESPACE="${CI_NAMESPACE}" \
STAGE_ID="${STAGE_ID}" \
STAGE_COMMAND="${STAGE_COMMAND}" \
COMMIT_SHA="${COMMIT_SHA}" \
GITHUB_REPOSITORY="${GITHUB_REPOSITORY}" \
RUNNER_IMAGE="${RUNNER_IMAGE}" \
AWS_REGION_VALUE="${AWS_REGION}" \
DEADLINE_SECONDS="${DEADLINE_SECONDS}" \
TEMPLATE="${REPO_ROOT}/k8s/ci-job/job-template.yaml" \
OUTPUT="${RENDERED}" \
python3 - <<'PY'
import os

mapping = {
    "__JOB_NAME__": os.environ["JOB_NAME"],
    "__CI_NAMESPACE__": os.environ["CI_NAMESPACE"],
    "__STAGE_ID__": os.environ["STAGE_ID"],
    "__STAGE_COMMAND__": os.environ["STAGE_COMMAND"],
    "__COMMIT_SHA__": os.environ["COMMIT_SHA"],
    "__GITHUB_REPOSITORY__": os.environ["GITHUB_REPOSITORY"],
    "__RUNNER_IMAGE__": os.environ["RUNNER_IMAGE"],
    "__AWS_REGION__": os.environ["AWS_REGION_VALUE"],
    "__DEADLINE_SECONDS__": os.environ["DEADLINE_SECONDS"],
}

with open(os.environ["TEMPLATE"], "r", encoding="utf-8") as fh:
    content = fh.read()
for placeholder, value in mapping.items():
    content = content.replace(placeholder, value)
with open(os.environ["OUTPUT"], "w", encoding="utf-8") as fh:
    fh.write(content)
PY

kubectl apply -f "${RENDERED}"
info "job: ${JOB_NAME}"

##############################################################################
log "Waiting for the pod to be scheduled"
##############################################################################
# Scheduling can legitimately take minutes: if no node has room, the Cluster
# Autoscaler must add one first. That IS the platform working as designed.
POD_NAME=""
for _ in $(seq 1 120); do
  POD_NAME="$(kubectl -n "${CI_NAMESPACE}" get pods \
    -l "job-name=${JOB_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${POD_NAME}" ]; then
    phase="$(kubectl -n "${CI_NAMESPACE}" get pod "${POD_NAME}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [ "${phase}" = "Running" ] || [ "${phase}" = "Succeeded" ] || [ "${phase}" = "Failed" ]; then
      break
    fi
  fi
  sleep 5
done

[ -n "${POD_NAME}" ] || fail "the dispatched job never produced a pod"
info "pod: ${POD_NAME}"

kubectl -n "${CI_NAMESPACE}" get pod "${POD_NAME}" -o wide || true

##############################################################################
log "Streaming stage output from the cluster"
##############################################################################
echo "----------------------------------------------------------------------"
# --follow ends when the CI container exits. The dind sidecar keeps running, so
# the Job itself never reports Complete — the CI container's exit code below is
# the real verdict.
kubectl -n "${CI_NAMESPACE}" logs "${POD_NAME}" -c ci --follow --timestamps=false || true
echo "----------------------------------------------------------------------"

##############################################################################
log "Collecting the exit code"
##############################################################################
EXIT_CODE=""
for _ in $(seq 1 60); do
  EXIT_CODE="$(kubectl -n "${CI_NAMESPACE}" get pod "${POD_NAME}" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="ci")].state.terminated.exitCode}' \
    2>/dev/null || true)"
  [ -n "${EXIT_CODE}" ] && break
  sleep 5
done

if [ -z "${EXIT_CODE}" ]; then
  kubectl -n "${CI_NAMESPACE}" describe pod "${POD_NAME}" || true
  fail "the CI container never reported a terminated state (stage '${STAGE_ID}')"
fi

# The pod is finished; the sidecar would otherwise hold the node until the TTL.
kubectl -n "${CI_NAMESPACE}" delete job "${JOB_NAME}" --wait=false >/dev/null 2>&1 || true

if [ "${EXIT_CODE}" -ne 0 ]; then
  fail "stage '${STAGE_ID}' failed in-cluster with exit code ${EXIT_CODE}"
fi

log "Stage '${STAGE_ID}' completed in-cluster (exit 0)"
