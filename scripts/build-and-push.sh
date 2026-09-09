#!/usr/bin/env bash
#
# Builds the Spring Boot application image and pushes it to ECR.
#
# Used by the deploy pipeline for the FIRST image (the self-hosted runners do
# not exist yet at that point). Afterwards the build pipeline does this on the
# runners via scripts/ci/docker-build.sh + ecr-push.sh.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker
require_cmd aws
require_cmd terraform

log "Reading infrastructure outputs"
AWS_REGION_VALUE="$(tf_output aws_region)"
ECR_URL="$(tf_output ecr_repository_url)"
ECR_REGISTRY="${ECR_URL%%/*}"

IMAGE_TAG="${IMAGE_TAG:-${GITHUB_SHA:-manual}}"
IMAGE_TAG="${IMAGE_TAG:0:40}"
IMAGE_REF="${ECR_URL}:${IMAGE_TAG}"

info "image=${IMAGE_REF}"

log "Authenticating to ECR"
aws ecr get-login-password --region "${AWS_REGION_VALUE}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

log "Building the application image"
DOCKER_BUILDKIT=1 docker build \
  -t "${IMAGE_REF}" \
  -t "${ECR_URL}:latest" \
  "${REPO_ROOT}/app"

log "Pushing to ECR"
docker push "${IMAGE_REF}"
docker push "${ECR_URL}:latest"

# Consumed by the next step in the SAME job only.
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "APP_IMAGE_TAG=${IMAGE_TAG}" >> "${GITHUB_ENV}"
fi

log "Image published: ${IMAGE_REF}"
