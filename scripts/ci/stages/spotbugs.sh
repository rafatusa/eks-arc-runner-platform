#!/usr/bin/env bash
#
# Build pipeline — SpotBugs stage (runs INSIDE the cluster).

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

log "SpotBugs on pod ${HOSTNAME:-unknown}"

cd "${REPO_ROOT}/app"
chmod +x ./gradlew
./gradlew spotbugsMain --no-daemon

log "SpotBugs passed"
