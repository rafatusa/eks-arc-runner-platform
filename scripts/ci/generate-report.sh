#!/usr/bin/env bash
#
# Validation pipeline — Generate HTML Report stage (runs INSIDE the cluster).
#
# Each stage runs in its own dispatched pod, so artifacts written by earlier
# stages are NOT on this pod's filesystem. Rather than pretend otherwise, this
# stage re-collects the live evidence itself (endpoint responses, cluster state,
# runner inventory) and renders a self-contained HTML report.
#
# The pod is destroyed when the stage ends, so the finished report is published
# into a ConfigMap that scripts/ci/fetch-report.sh reads from the GitHub job.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=scripts/ci/lib/resolve-url.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/resolve-url.sh"

require_cmd kubectl
require_cmd terraform
require_cmd curl
require_cmd python3

APP_NAMESPACE="${APP_NAMESPACE:-runner-platform}"
RELEASE_NAME="${RELEASE_NAME:-runner-platform-api}"
ARC_NAMESPACE="actions-runner-system"
CI_NAMESPACE="${CI_NAMESPACE:-ci-dispatch}"

REPORT_DIR="${REPO_ROOT}/reports"
mkdir -p "${REPORT_DIR}"

BASE_URL="$(resolve_base_url)"
log "Collecting evidence from ${BASE_URL}"

collect() {
  local path="$1"
  curl --silent --show-error --max-time 20 --retry 5 --retry-delay 5 \
    --write-out '\nHTTP %{http_code} in %{time_total}s\n' \
    "${BASE_URL}${path}" 2>&1 || echo "request failed"
}

HEALTH_BODY="$(collect /health)"
HELLO_BODY="$(collect '/hello?name=validation')"
ROOT_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --max-time 20 "${BASE_URL}/" || echo 000)"

PODS="$(kubectl -n "${APP_NAMESPACE}" get pods -o wide 2>&1 || echo 'unavailable')"
DEPLOY="$(kubectl -n "${APP_NAMESPACE}" get deployment "${RELEASE_NAME}" -o wide 2>&1 || echo 'unavailable')"
INGRESS="$(kubectl -n "${APP_NAMESPACE}" get ingress -o wide 2>&1 || echo 'unavailable')"
RUNNERS="$(kubectl -n "${ARC_NAMESPACE}" get runners 2>&1 || echo 'unavailable')"
RUNNER_PODS="$(kubectl -n "${ARC_NAMESPACE}" get pods -o wide 2>&1 || echo 'unavailable')"
HRA="$(kubectl -n "${ARC_NAMESPACE}" get horizontalrunnerautoscaler -o wide 2>&1 || echo 'unavailable')"
NODES="$(kubectl get nodes -o wide 2>&1 || echo 'unavailable')"
IMAGE="$(kubectl -n "${APP_NAMESPACE}" get deployment "${RELEASE_NAME}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo unknown)"

log "Rendering the HTML report"

REPORT_DIR="${REPORT_DIR}" \
BASE_URL="${BASE_URL}" \
ROOT_STATUS="${ROOT_STATUS}" \
HEALTH_BODY="${HEALTH_BODY}" \
HELLO_BODY="${HELLO_BODY}" \
PODS="${PODS}" DEPLOY="${DEPLOY}" INGRESS="${INGRESS}" \
RUNNERS="${RUNNERS}" RUNNER_PODS="${RUNNER_PODS}" HRA="${HRA}" NODES="${NODES}" \
DEPLOYED_IMAGE="${IMAGE}" \
RUNNER_HOST="${HOSTNAME:-unknown}" \
GIT_SHA="${GITHUB_SHA:-unknown}" \
python3 - <<'PY'
import datetime
import html
import os

env = os.environ
report_dir = env["REPORT_DIR"]


def block(text):
    return html.escape(text.strip() or "no data")


sections = [
    ("Endpoint: /health", env["HEALTH_BODY"]),
    ("Endpoint: /hello?name=validation", env["HELLO_BODY"]),
    ("Application deployment", env["DEPLOY"]),
    ("Application pods", env["PODS"]),
    ("Ingress / ALB", env["INGRESS"]),
    ("Runner inventory (ARC)", env["RUNNERS"]),
    ("Runner pods", env["RUNNER_PODS"]),
    ("HorizontalRunnerAutoscaler", env["HRA"]),
    ("Cluster nodes", env["NODES"]),
]

root_ok = env["ROOT_STATUS"] == "200"
generated = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

rows = "\n".join(
    f"<tr><th>{html.escape(k)}</th><td><code>{html.escape(v)}</code></td></tr>"
    for k, v in [
        ("Base URL", env["BASE_URL"]),
        ("Deployed image", env["DEPLOYED_IMAGE"]),
        ("Commit", env["GIT_SHA"]),
        ("Executed in pod", env["RUNNER_HOST"]),
        ("Landing page status", env["ROOT_STATUS"]),
    ]
)

body = "\n".join(
    f'<section><h2>{html.escape(title)}</h2><pre>{block(content)}</pre></section>'
    for title, content in sections
)

document = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Validation Report — GitHub Self-Hosted Runner Platform</title>
<style>
  body {{ font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
          margin: 0; padding: 2.5rem; background: #0d1117; color: #e6edf3; }}
  .wrap {{ max-width: 60rem; margin: 0 auto; }}
  h1 {{ font-size: 1.6rem; margin: 0 0 .3rem; }}
  p.meta {{ color: #8b949e; margin: 0 0 2rem; }}
  .verdict {{ display: inline-block; padding: .35rem .9rem; border-radius: 999px;
              font-weight: 600; font-size: .85rem; margin-bottom: 1.5rem; }}
  .ok {{ background: #23863622; color: #3fb950; border: 1px solid #3fb95055; }}
  .bad {{ background: #f8514922; color: #f85149; border: 1px solid #f8514955; }}
  table {{ border-collapse: collapse; width: 100%; margin-bottom: 2rem; }}
  th, td {{ text-align: left; padding: .5rem .75rem; border-bottom: 1px solid #30363d;
            font-size: .9rem; vertical-align: top; }}
  th {{ color: #8b949e; font-weight: 500; width: 14rem; }}
  section {{ margin-bottom: 1.75rem; }}
  h2 {{ font-size: 1rem; color: #79c0ff; margin: 0 0 .5rem; }}
  pre {{ background: #161b22; border: 1px solid #30363d; border-radius: 8px;
         padding: 1rem; overflow-x: auto; font-size: .82rem; line-height: 1.45;
         white-space: pre-wrap; word-break: break-word; }}
  code {{ font-size: .85rem; }}
  footer {{ margin-top: 2.5rem; padding-top: 1.25rem; border-top: 1px solid #30363d;
            color: #6e7681; font-size: .82rem; }}
</style>
</head>
<body>
<div class="wrap">
  <h1>Validation Report</h1>
  <p class="meta">GitHub Self-Hosted Runner Platform on Amazon EKS &middot; generated {generated}</p>
  <span class="verdict {'ok' if root_ok else 'bad'}">
    {'Application responding' if root_ok else 'Application NOT responding'}
  </span>
  <table>{rows}</table>
  {body}
  <footer>
    Collected live from the cluster by the validation pipeline, executing inside
    the same EKS cluster that hosts the workload and the runner pool.
  </footer>
</div>
</body>
</html>
"""

with open(os.path.join(report_dir, "index.html"), "w", encoding="utf-8") as fh:
    fh.write(document)

print(f"report written to {report_dir}/index.html")
PY

##############################################################################
log "Publishing the report so the GitHub job can collect it"
##############################################################################
# This pod is destroyed when the stage ends, so the report is handed off through
# a ConfigMap that scripts/ci/fetch-report.sh reads.
CONFIGMAP_NAME="validation-report-${GITHUB_SHA:0:8}"

kubectl -n "${CI_NAMESPACE}" create configmap "${CONFIGMAP_NAME}" \
  --from-file="index.html=${REPORT_DIR}/index.html" \
  --dry-run=client -o yaml | kubectl apply -f -

log "HTML report generated and published as ${CONFIGMAP_NAME}"
ls -la "${REPORT_DIR}"
