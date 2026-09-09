#!/usr/bin/env bash
#
# Build pipeline — Checkstyle stage (runs INSIDE the cluster).

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

log "Checkstyle on pod ${HOSTNAME:-unknown}"

cd "${REPO_ROOT}/app"
chmod +x ./gradlew
./gradlew checkstyleMain --no-daemon

log "Checkstyle passed"
