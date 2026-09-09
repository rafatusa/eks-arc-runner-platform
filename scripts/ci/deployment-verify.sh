#!/usr/bin/env bash
#
# Validation pipeline — Deployment Verification stage. Confirms the cluster is
# in the state the platform promises: healthy app replicas, ephemeral runners
# registered, and the autoscaler bounds intact.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_cmd kubectl
require_cmd terraform
require_cmd aws

APP_NAMESPACE="${APP_NAMESPACE:-runner-platform}"
RELEASE_NAME="${RELEASE_NAME:-runner-platform-api}"
ARC_NAMESPACE="actions-runner-system"

terraform -chdir="${INFRA_DIR}" init -input=false -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${PROJECT_NAME}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" >/dev/null

ensure_kubeconfig

mkdir -p "${REPO_ROOT}/reports"
REPORT="${REPO_ROOT}/reports/deployment-verification.txt"
: > "${REPORT}"

FAILURES=0
record() {
  printf '%s\n' "$1" | tee -a "${REPORT}"
}

check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    record "[PASS] ${label}"
  else
    record "[FAIL] ${label}"
    FAILURES=$((FAILURES + 1))
  fi
}

log "Application"
check "deployment is Available" \
  kubectl -n "${APP_NAMESPACE}" wait --for=condition=Available \
  "deployment/${RELEASE_NAME}" --timeout=180s

ready_replicas() {
  local ready
  ready="$(kubectl -n "${APP_NAMESPACE}" get deployment "${RELEASE_NAME}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  [ "${ready:-0}" -ge 1 ]
}
check "at least one ready replica" ready_replicas

no_restarting_pods() {
  local restarts
  restarts="$(kubectl -n "${APP_NAMESPACE}" get pods \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' \
    2>/dev/null | sort -rn | head -1)"
  [ "${restarts:-0}" -lt 3 ]
}
check "no pod is crash-looping" no_restarting_pods

log "Runner platform"
check "ARC controller Available" \
  kubectl -n "${ARC_NAMESPACE}" wait --for=condition=Available \
  deployment/actions-runner-controller --timeout=180s

runner_present() {
  local count
  count="$(kubectl -n "${ARC_NAMESPACE}" get runners --no-headers 2>/dev/null | wc -l)"
  [ "${count}" -ge 1 ]
}
check "runner pool is registered" runner_present

ephemeral_true() {
  [ "$(kubectl -n "${ARC_NAMESPACE}" get runnerdeployment eks-runners \
      -o jsonpath='{.spec.template.spec.ephemeral}' 2>/dev/null)" = "true" ]
}
check "runners are ephemeral" ephemeral_true

hra_present() {
  kubectl -n "${ARC_NAMESPACE}" get horizontalrunnerautoscaler eks-runners-autoscaler
}
check "HorizontalRunnerAutoscaler exists" hra_present

log "Cluster capacity"
kubectl top nodes 2>/dev/null | tee -a "${REPORT}" || record "[INFO] metrics not available yet"

record ""
record "This validation job itself executed on runner pod: ${HOSTNAME:-unknown}"

kubectl -n "${ARC_NAMESPACE}" get runners,pods | tee -a "${REPORT}"

[ "${FAILURES}" -eq 0 ] || fail "${FAILURES} deployment verification check(s) failed"

log "Deployment verification passed"
