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

# Blocks until the Docker-in-Docker sidecar is actually serving its API.
#
# The `ci` and `dind` containers of a dispatched CI Job start in PARALLEL —
# Kubernetes gives no ordering guarantee between them. dockerd needs a few
# seconds to initialise storage and bind its unix socket, so a stage that runs
# `docker build` immediately dies with:
#
#   Cannot connect to the Docker daemon at unix:///var/run/docker/docker.sock.
#
# The socket's mere existence is not enough (dockerd binds before it is ready to
# serve), so readiness is probed with `docker info`, which round-trips to the
# daemon. Same failure class as the cert-manager webhook wait.
#
# The socket lives in the DEDICATED /var/run/docker directory, not bare
# /var/run: the kubelet projects the pod's ServiceAccount and IRSA identity
# files under /var/run/secrets, and a volume mounted at /var/run shadows them
# unless the projected volumes are re-mounted on top at their more specific
# paths. See k8s/ci-job/job-template.yaml.
#
# Call this in every stage that talks to docker, AFTER `require_cmd docker`.
wait_for_docker() {
  local attempts="${1:-60}"
  local delay="${2:-2}"
  local i=1
  local err

  : "${DOCKER_HOST:=unix:///var/run/docker/docker.sock}"
  export DOCKER_HOST

  log "Waiting for the Docker daemon at ${DOCKER_HOST}"
  while ! docker info >/dev/null 2>&1; do
    # A PERMISSION error is not a readiness problem and will never clear by
    # waiting: it means dockerd created the socket without granting the
    # runner's group access (dind needs --group=<runner gid>). Fail fast with
    # the cause named rather than burning the full timeout on it.
    err="$(docker info 2>&1 || true)"
    case "${err}" in
      *"permission denied"*|*"Permission denied"*)
        printf '\n--- docker error ---\n%s\n' "${err}" >&2
        fail "cannot access ${DOCKER_HOST}: permission denied for $(id -un) (uid $(id -u), groups $(id -Gn)). The dind sidecar must run dockerd with --group=<runner gid> so the socket is group-accessible."
        ;;
    esac

    if [ "${i}" -ge "${attempts}" ]; then
      printf '\n--- last docker error ---\n%s\n' "${err}" >&2
      fail "the Docker daemon did not become ready after $((attempts * delay))s at ${DOCKER_HOST}"
    fi
    if [ "${i}" -eq 1 ] || [ $((i % 5)) -eq 0 ]; then
      info "daemon not ready yet (attempt ${i}/${attempts}); retrying in ${delay}s"
    fi
    i=$((i + 1))
    sleep "${delay}"
  done

  info "Docker daemon is ready"
  docker version --format 'client={{.Client.Version}} server={{.Server.Version}}'
}

# Verifies the pod's kubelet-projected identity files survived the volume
# mounts before a stage tries to use them. A volume mounted over /var/run
# silently erases the projected identity directory, which surfaces much later as
# an opaque AWS credential error — this turns it into a named failure at the
# point of cause.
require_pod_credentials() {
  local sa_identity="/var/run/secrets/kubernetes.io/serviceaccount"
  [ -r "${sa_identity}/ca.crt" ] \
    || fail "ServiceAccount identity missing at ${sa_identity} — a volume is shadowing /var/run/secrets"

  local irsa_identity="${AWS_WEB_IDENTITY_TOKEN_FILE:-}"
  if [ -n "${irsa_identity}" ] && [ ! -r "${irsa_identity}" ]; then
    fail "IRSA identity file missing at ${irsa_identity} — a volume is shadowing /var/run/secrets"
  fi
  info "pod identity present (ServiceAccount${irsa_identity:+ + IRSA})"
}
