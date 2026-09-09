#!/usr/bin/env bash
#
# Build pipeline — Build Docker Image stage. Runs INSIDE a self-hosted runner
# pod, using the Docker-in-Docker sidecar provided by the RunnerDeployment.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_cmd docker

IMAGE_TAG="${GITHUB_SHA:-manual}"
IMAGE_TAG="${IMAGE_TAG:0:40}"
LOCAL_REF="runner-platform-api:${IMAGE_TAG}"

log "Building ${LOCAL_REF} on runner pod ${HOSTNAME:-unknown}"
DOCKER_BUILDKIT=1 docker build -t "${LOCAL_REF}" "${REPO_ROOT}/app"

log "Image built"
docker image inspect "${LOCAL_REF}" --format 'size={{.Size}} created={{.Created}}'

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "IMAGE_TAG=${IMAGE_TAG}" >> "${GITHUB_ENV}"
  echo "LOCAL_REF=${LOCAL_REF}" >> "${GITHUB_ENV}"
fi
