#!/usr/bin/env bash
#
# Build pipeline — Helm Upgrade stage. Deploys the freshly pushed image from a
# runner pod using the IRSA identity attached to the runner service account.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_cmd helm
require_cmd kubectl
require_cmd aws
require_cmd terraform

APP_NAMESPACE="${APP_NAMESPACE:-runner-platform}"
RELEASE_NAME="${RELEASE_NAME:-runner-platform-api}"

IMAGE_TAG="${GITHUB_SHA:-latest}"
IMAGE_TAG="${IMAGE_TAG:0:40}"

log "Reading infrastructure outputs"
terraform -chdir="${INFRA_DIR}" init -input=false -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${PROJECT_NAME}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" >/dev/null

ECR_URL="$(tf_output ecr_repository_url)"
ALB_SG_ID="$(tf_output alb_security_group_id)"

ensure_kubeconfig

log "Upgrading release ${RELEASE_NAME} to ${ECR_URL}:${IMAGE_TAG}"
helm upgrade --install "${RELEASE_NAME}" "${REPO_ROOT}/helm/app" \
  --namespace "${APP_NAMESPACE}" \
  --create-namespace \
  --set "image.repository=${ECR_URL}" \
  --set "image.tag=${IMAGE_TAG}" \
  --set "ingress.securityGroupId=${ALB_SG_ID}" \
  --set "env.APP_VERSION=${IMAGE_TAG}" \
  --wait --timeout 10m

log "Helm upgrade complete"
helm -n "${APP_NAMESPACE}" history "${RELEASE_NAME}" --max 5
