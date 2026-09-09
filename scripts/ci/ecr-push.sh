#!/usr/bin/env bash
#
# Build pipeline — Push Image to Amazon ECR stage.
#
# Each stage is a separate job on a NEW ephemeral runner pod, so the image built
# in the previous stage is not on this pod's docker daemon. The image is rebuilt
# here from the same commit (BuildKit layer reuse does not span pods) and pushed.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_cmd docker
require_cmd aws
require_cmd terraform

IMAGE_TAG="${GITHUB_SHA:-manual}"
IMAGE_TAG="${IMAGE_TAG:0:40}"

log "Resolving the ECR repository"
terraform -chdir="${INFRA_DIR}" init -input=false -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${PROJECT_NAME}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" >/dev/null

ECR_URL="$(tf_output ecr_repository_url)"
ECR_REGISTRY="${ECR_URL%%/*}"
IMAGE_REF="${ECR_URL}:${IMAGE_TAG}"

log "Authenticating to ECR"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

log "Building and pushing ${IMAGE_REF}"
DOCKER_BUILDKIT=1 docker build \
  -t "${IMAGE_REF}" \
  -t "${ECR_URL}:latest" \
  "${REPO_ROOT}/app"

docker push "${IMAGE_REF}"
docker push "${ECR_URL}:latest"

log "Image pushed for commit ${IMAGE_TAG}"
