#!/usr/bin/env bash
#
# Validation pipeline — k6 Load Test stage. k6 is baked into the runner image,
# so the load generator runs inside the cluster, next to the workload.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/ci/lib/resolve-url.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-url.sh"

require_cmd k6
require_cmd kubectl
require_cmd terraform

BASE_URL="$(resolve_base_url)"
export BASE_URL

mkdir -p "${REPO_ROOT}/reports"
cd "${REPO_ROOT}"

log "Running k6 load test against ${BASE_URL}"
# k6 exits non-zero when a threshold is breached, which fails this stage.
k6 run --summary-export="${REPO_ROOT}/reports/k6-metrics.json" \
  "${REPO_ROOT}/tests/k6/load-test.js" | tee "${REPO_ROOT}/reports/k6-output.txt"

log "Load test thresholds met"
