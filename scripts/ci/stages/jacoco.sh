#!/usr/bin/env bash
#
# Build pipeline — JaCoCo Coverage stage (runs INSIDE the cluster).
# Fails when line coverage drops below the threshold in app/build.gradle.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

log "JaCoCo coverage on pod ${HOSTNAME:-unknown}"

cd "${REPO_ROOT}/app"
chmod +x ./gradlew
./gradlew jacocoTestReport jacocoTestCoverageVerification --no-daemon

log "Coverage threshold met"
