#!/usr/bin/env bash
#
# Resolves the public base URL of the deployed application. Sourced by the
# validation pipeline stages.
#
# Each stage runs on a fresh ephemeral pod, so the URL is resolved from the
# cluster every time rather than passed between jobs — the ALB hostname is
# derived from the project name, which GitHub masks and drops from job outputs.

resolve_base_url() {
  local namespace="${APP_NAMESPACE:-runner-platform}"
  local release="${RELEASE_NAME:-runner-platform-api}"

  terraform -chdir="${INFRA_DIR}" init -input=false -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=${PROJECT_NAME}/terraform.tfstate" \
    -backend-config="region=${AWS_REGION}" >/dev/null

  ensure_kubeconfig

  local host=""
  local i=1
  while [ "${i}" -le 30 ]; do
    host="$(kubectl -n "${namespace}" get ingress "${release}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [ -n "${host}" ]; then
      break
    fi
    sleep 10
    i=$((i + 1))
  done

  [ -n "${host}" ] || fail "could not resolve the ALB hostname for ${release}"
  printf 'http://%s' "${host}"
}
