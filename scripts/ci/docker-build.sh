#!/usr/bin/env bash
#
# Build pipeline — Build Docker Image stage. Runs INSIDE a self-hosted runner
# pod, using the Docker-in-Docker sidecar provided by the RunnerDeployment.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_cmd docker
# The dind sidecar starts in parallel with this container — block until its
# daemon actually answers before issuing any docker command.
wait_for_docker

IMAGE_TAG="${GITHUB_SHA:-manual}"
IMAGE_TAG="${IMAGE_TAG:0:40}"
LOCAL_REF="runner-platform-api:${IMAGE_TAG}"

log "Building ${LOCAL_REF} on runner pod ${HOSTNAME:-unknown}"
# DOCKER_BUILDKIT=0 is REQUIRED on this runner image, not a preference.
# The docker CLI is installed but the buildx PLUGIN is not, and docker build
# defaults to BuildKit on CE 23+, which fails with
# "BuildKit is enabled but the buildx component is missing or broken".
# The legacy builder is part of dockerd itself, so it needs no extra binary.
# app/Dockerfile deliberately uses no BuildKit-only syntax (no --mount, no
# heredocs, no --link) so it builds identically either way. If buildx is ever
# baked into the runner image, this can flip back to 1.
DOCKER_BUILDKIT=0 docker build -t "${LOCAL_REF}" "${REPO_ROOT}/app"

log "Image built"
docker image inspect "${LOCAL_REF}" --format 'size={{.Size}} created={{.Created}}'

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "IMAGE_TAG=${IMAGE_TAG}" >> "${GITHUB_ENV}"
  echo "LOCAL_REF=${LOCAL_REF}" >> "${GITHUB_ENV}"
fi
