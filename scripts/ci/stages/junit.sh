#!/usr/bin/env bash
#
# Build pipeline — JUnit Tests stage (runs INSIDE the cluster).

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

log "JUnit tests on pod ${HOSTNAME:-unknown}"

cd "${REPO_ROOT}/app"
chmod +x ./gradlew
./gradlew test --no-daemon

log "Unit tests passed"
