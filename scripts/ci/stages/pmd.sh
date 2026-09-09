#!/usr/bin/env bash
#
# Build pipeline — PMD stage (runs INSIDE the cluster).

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

log "PMD on pod ${HOSTNAME:-unknown}"

cd "${REPO_ROOT}/app"
chmod +x ./gradlew
./gradlew pmdMain --no-daemon

log "PMD passed"
