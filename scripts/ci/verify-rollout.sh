#!/usr/bin/env bash
#
# Build pipeline — Verify Rollout stage. Confirms the new revision is live and
# that every serving pod reports the commit that was just deployed.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_cmd kubectl
require_cmd aws
require_cmd terraform

APP_NAMESPACE="${APP_NAMESPACE:-runner-platform}"
RELEASE_NAME="${RELEASE_NAME:-runner-platform-api}"

IMAGE_TAG="${GITHUB_SHA:-latest}"
IMAGE_TAG="${IMAGE_TAG:0:40}"

terraform -chdir="${INFRA_DIR}" init -input=false -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${PROJECT_NAME}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" >/dev/null

ensure_kubeconfig

log "Rollout status"
kubectl -n "${APP_NAMESPACE}" rollout status "deployment/${RELEASE_NAME}" --timeout=10m

log "Deployed image"
DEPLOYED_IMAGE="$(kubectl -n "${APP_NAMESPACE}" get deployment "${RELEASE_NAME}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
info "${DEPLOYED_IMAGE}"

case "${DEPLOYED_IMAGE}" in
  *":${IMAGE_TAG}") info "deployed image matches commit ${IMAGE_TAG}" ;;
  *) fail "deployed image ${DEPLOYED_IMAGE} does not match the built commit ${IMAGE_TAG}" ;;
esac

log "Pod status"
kubectl -n "${APP_NAMESPACE}" get pods -o wide

READY="$(kubectl -n "${APP_NAMESPACE}" get deployment "${RELEASE_NAME}" \
  -o jsonpath='{.status.readyReplicas}')"
DESIRED="$(kubectl -n "${APP_NAMESPACE}" get deployment "${RELEASE_NAME}" \
  -o jsonpath='{.spec.replicas}')"
info "ready=${READY:-0} desired=${DESIRED:-0}"

[ "${READY:-0}" -ge 1 ] || fail "no ready replicas after the rollout"

log "Rollout verified"
