#!/usr/bin/env bash
#
# End-to-end verification of the deploy: cluster health, add-ons, ARC runner
# registration, and the application answering through the public ALB.
#
# Every value it needs is read from terraform state in THIS job — nothing is
# threaded from an earlier job, because identifiers derived from the project
# name are masked by GitHub and dropped from job outputs.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd kubectl
require_cmd terraform
require_cmd curl

APP_NAMESPACE="${APP_NAMESPACE:-runner-platform}"
RELEASE_NAME="${RELEASE_NAME:-runner-platform-api}"
ARC_NAMESPACE="actions-runner-system"

FAILURES=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '    \033[1;32m[PASS]\033[0m %s\n' "${label}"
  else
    printf '    \033[1;31m[FAIL]\033[0m %s\n' "${label}"
    FAILURES=$((FAILURES + 1))
  fi
}

ensure_kubeconfig

##############################################################################
log "1/5 Cluster and nodes"
##############################################################################
kubectl get nodes -o wide
check "all nodes Ready" kubectl wait --for=condition=Ready nodes --all --timeout=60s

##############################################################################
log "2/5 Cluster add-ons"
##############################################################################
check "metrics-server available" \
  kubectl -n kube-system wait --for=condition=Available deployment/metrics-server --timeout=180s
check "aws-load-balancer-controller available" \
  kubectl -n kube-system wait --for=condition=Available deployment/aws-load-balancer-controller --timeout=180s
check "cluster-autoscaler available" \
  kubectl -n kube-system wait --for=condition=Available \
  deployment/cluster-autoscaler-aws-cluster-autoscaler --timeout=180s

# Metrics Server is only genuinely working once it serves the metrics API.
log "Metrics API"
retry 20 15 kubectl top nodes || info "kubectl top nodes not answering yet (metrics warm-up)"

##############################################################################
log "3/5 Actions Runner Controller and ephemeral runners"
##############################################################################
kubectl -n "${ARC_NAMESPACE}" get runnerdeployments,horizontalrunnerautoscalers,runners

check "ARC controller available" \
  kubectl -n "${ARC_NAMESPACE}" wait --for=condition=Available \
  deployment/actions-runner-controller --timeout=180s

runner_registered() {
  local count
  count="$(kubectl -n "${ARC_NAMESPACE}" get runners \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -c '^Running$' || true)"
  [ "${count}" -ge 1 ]
}
check "at least one runner registered and Running" retry 30 15 runner_registered

ephemeral_configured() {
  local value
  value="$(kubectl -n "${ARC_NAMESPACE}" get runnerdeployment eks-runners \
    -o jsonpath='{.spec.template.spec.ephemeral}' 2>/dev/null || true)"
  [ "${value}" = "true" ]
}
check "runners are ephemeral" ephemeral_configured

hra_bounds_correct() {
  local min max
  min="$(kubectl -n "${ARC_NAMESPACE}" get horizontalrunnerautoscaler eks-runners-autoscaler \
    -o jsonpath='{.spec.minReplicas}' 2>/dev/null || true)"
  max="$(kubectl -n "${ARC_NAMESPACE}" get horizontalrunnerautoscaler eks-runners-autoscaler \
    -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || true)"
  [ "${min}" = "1" ] && [ "${max}" = "20" ]
}
check "autoscaler bounds are 1..20" hra_bounds_correct

##############################################################################
log "4/5 Application workload"
##############################################################################
kubectl -n "${APP_NAMESPACE}" get pods,svc,ingress
check "application deployment available" \
  kubectl -n "${APP_NAMESPACE}" wait --for=condition=Available \
  "deployment/${RELEASE_NAME}" --timeout=300s

##############################################################################
log "5/5 Public endpoint through the ALB"
##############################################################################
ALB_HOST="$(kubectl -n "${APP_NAMESPACE}" get ingress "${RELEASE_NAME}" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

if [ -z "${ALB_HOST}" ]; then
  printf '    \033[1;31m[FAIL]\033[0m ingress has no ALB hostname\n'
  FAILURES=$((FAILURES + 1))
else
  info "ALB endpoint acquired; probing /health"
  # A freshly created ALB needs its targets to pass health checks first, so this
  # retries generously rather than curling once.
  if curl --fail --silent --show-error \
       --retry 30 --retry-delay 15 --retry-all-errors --max-time 20 \
       "http://${ALB_HOST}/health" -o /tmp/health.json; then
    printf '    \033[1;32m[PASS]\033[0m /health responded\n'
    cat /tmp/health.json; echo
  else
    printf '    \033[1;31m[FAIL]\033[0m /health did not respond through the ALB\n'
    FAILURES=$((FAILURES + 1))
  fi

  for path in "/" "/hello"; do
    if curl --fail --silent --show-error --retry 5 --retry-delay 10 \
         --retry-all-errors --max-time 20 "http://${ALB_HOST}${path}" >/dev/null; then
      printf '    \033[1;32m[PASS]\033[0m %s responded\n' "${path}"
    else
      printf '    \033[1;31m[FAIL]\033[0m %s did not respond\n' "${path}"
      FAILURES=$((FAILURES + 1))
    fi
  done

  log "Application URL: http://${ALB_HOST}"
fi

##############################################################################
if [ "${FAILURES}" -gt 0 ]; then
  fail "${FAILURES} verification check(s) failed"
fi

log "Platform verification passed"
