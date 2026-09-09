#!/usr/bin/env bash
#
# Validation pipeline — REST Assured stage. Executes the @Tag("e2e") suite
# against the live deployment from inside the cluster's runner pod.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/ci/lib/resolve-url.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-url.sh"

require_cmd kubectl
require_cmd terraform

BASE_URL="$(resolve_base_url)"
export BASE_URL

log "Running REST Assured tests against ${BASE_URL}"
cd "${REPO_ROOT}/app"
chmod +x ./gradlew
./gradlew restAssuredTest --no-daemon -i

log "Collecting the test report"
mkdir -p "${REPO_ROOT}/reports/rest-assured"
if [ -d "${REPO_ROOT}/app/build/reports/tests/restAssuredTest" ]; then
  cp -r "${REPO_ROOT}/app/build/reports/tests/restAssuredTest/." \
     "${REPO_ROOT}/reports/rest-assured/"
fi

log "REST Assured suite passed"
