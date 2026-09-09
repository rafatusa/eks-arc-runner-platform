#!/usr/bin/env bash
#
# Build pipeline — Gradle Build stage (runs INSIDE the cluster).

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

log "Gradle build on pod ${HOSTNAME:-unknown}"
java -version

cd "${REPO_ROOT}/app"
chmod +x ./gradlew
./gradlew clean classes testClasses --no-daemon

log "Compilation complete"
