#!/usr/bin/env bash
#
# Validation pipeline — Smoke Test stage. The cheapest possible proof that the
# deployment is serving traffic before the heavier suites run.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/ci/lib/resolve-url.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-url.sh"

require_cmd curl
require_cmd kubectl
require_cmd terraform

BASE_URL="$(resolve_base_url)"
log "Smoke testing ${BASE_URL}"

mkdir -p "${REPO_ROOT}/reports"
RESULT_FILE="${REPO_ROOT}/reports/smoke-results.txt"
: > "${RESULT_FILE}"

FAILURES=0
probe() {
  local path="$1" expected="$2"
  local code
  code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --retry 20 --retry-delay 10 --retry-all-errors --max-time 20 \
    "${BASE_URL}${path}" || echo "000")"
  if [ "${code}" = "${expected}" ]; then
    printf '    [PASS] %-24s -> %s\n' "${path}" "${code}" | tee -a "${RESULT_FILE}"
  else
    printf '    [FAIL] %-24s -> %s (expected %s)\n' "${path}" "${code}" "${expected}" \
      | tee -a "${RESULT_FILE}"
    FAILURES=$((FAILURES + 1))
  fi
}

probe "/" "200"
probe "/health" "200"
probe "/hello" "200"
probe "/actuator/health" "200"

log "Response body from /health"
curl --silent --max-time 20 "${BASE_URL}/health" | tee -a "${RESULT_FILE}"; echo

[ "${FAILURES}" -eq 0 ] || fail "${FAILURES} smoke check(s) failed"

log "Smoke tests passed"
