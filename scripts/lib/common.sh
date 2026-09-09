#!/usr/bin/env bash
#
# Shared helpers for the platform scripts. Sourced, never executed directly.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

INFRA_DIR="${REPO_ROOT}/infra"
export INFRA_DIR

log() {
  printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

info() {
  printf '    %s\n' "$*"
}

fail() {
  printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

# Reads one terraform output. Every stage re-runs `terraform init` itself with
# the same backend flags rather than threading values between jobs — GitHub
# drops job outputs whose value contains a secret substring, and the project
# name (a secret) appears in nearly every resource identifier here.
tf_output() {
  local name="$1"
  terraform -chdir="${INFRA_DIR}" output -raw "${name}"
}

# Ensures kubectl is pointed at this project's cluster.
ensure_kubeconfig() {
  local cluster_name region
  cluster_name="$(tf_output cluster_name)"
  region="$(tf_output aws_region)"
  aws eks update-kubeconfig --name "${cluster_name}" --region "${region}" >/dev/null
  kubectl config current-context >/dev/null || fail "kubeconfig was not configured"
}

# Retry wrapper for operations that race cluster readiness.
retry() {
  local attempts="$1"; shift
  local delay="$1"; shift
  local i=1
  until "$@"; do
    if [ "${i}" -ge "${attempts}" ]; then
      return 1
    fi
    info "attempt ${i}/${attempts} failed; retrying in ${delay}s: $*"
    i=$((i + 1))
    sleep "${delay}"
  done
  return 0
}
