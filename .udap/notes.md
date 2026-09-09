# eks-arc-runner-platform — working notes

## Goal
GitHub Self-Hosted Runner Platform on Amazon EKS. Terraform provisions VPC/EKS/ECR/IRSA;
Helm bootstraps Metrics Server + AWS LB Controller + Cluster Autoscaler + ARC (legacy CRDs).
Ephemeral runners via RunnerDeployment + HorizontalRunnerAutoscaler (min 1, max 20,
queued-job metrics). Spring Boot 3.2 / Java 21 / Gradle sample app on ECR behind an ALB.

## Key decisions
- ARC **legacy** (actions-runner-controller, `actions.summerwind.dev/v1alpha1`) — the user
  named RunnerDeployment + HorizontalRunnerAutoscaler, which only exist in legacy ARC.
- Custom runner toolchain image (`runner-image/Dockerfile`): JDK 21, kubectl, helm, k6,
  awscli baked in. Pods are ephemeral, so job-time installs would repeat on all 20 pods.
- Runner pods use IRSA (`github-runner` SA) — no static AWS keys in the cluster.
- Each stage re-reads terraform outputs itself (SELF-SUFFICIENT JOB RULE). PROJECT_NAME is
  a secret, so derived ALB hostnames / ECR URLs are masked and dropped from job outputs.
- app/gradlew self-bootstraps gradle-wrapper.jar (binary files cannot be written to the
  workspace). Do NOT "fix" this by deleting the bootstrap block.
- Scaffold shipped Spring Boot 4.1.1 with starters that don't exist under 3.2 naming.
  Rewrote build.gradle for 3.2.11 (spring-boot-starter-web / -test).
- Landing page moved to `src/main/resources/static/index.html` (served by Spring at `/`).
  Reason: keeps long HTML/CSS lines out of Java, so Checkstyle LineLength=120 stays strict
  instead of being relaxed. The page fetches /health to show version + serving pod.
- JaCoCo 70% line gate excludes RunnerPlatformApplication.class (framework glue, no logic).
  The THRESHOLD was not lowered — only the bootstrap class left the denominator.
- App Dockerfile installs curl in the runtime stage: the healthcheck uses curl, and the
  earlier /dev/tcp form needed bash (runtime /bin/sh is dash).

## PLATFORM CONSTRAINT (verified, not assumed)
The build + validation pipelines cannot natively target ARC runners on UDAP:
1. `runs_on` rejected by the spec: `unknown key 'runs_on' — allowed: [approval, env, id,
   kind, needs, outputs, steps, timeout_minutes]`. Renderer hardcodes `runs-on: ubuntu-latest`.
2. `write_file` on `.github/workflows/*.yml` is REFUSED (workflows render from the spec).

### Resolution — staged Option C (user decision)
- Phase 1 (DONE, shipping now): ci-build + ci-validate pipelines are **dispatch shims**.
  Each ubuntu-latest job submits a Kubernetes Job (k8s/ci-job/job-template.yaml) that runs
  the real stage in-cluster on the runner toolchain image, streams logs, and exits with the
  in-cluster exit code. See scripts/ci/dispatch.sh.
- Phase 2 (AFTER runners are live): switch to native `runs-on: [self-hosted, eks]` by
  copying docs/self-hosted-workflows/*.yml into .github/workflows/ AND removing ci-build /
  ci-validate from the spec's `pipelines:` block (else the next render overwrites them).
  Documented in docs/DEPLOYMENT.md "Phase 2".

## Dispatch design notes
- Job has a dind sidecar → the Job NEVER reports Complete (sidecar keeps running).
  dispatch.sh therefore watches the **ci container's** terminated.exitCode, not job status.
- The in-cluster pod clones the repo itself (shallow, at GITHUB_SHA) using a token from the
  ci-dispatch-secrets secret.
- Report handoff: pods are destroyed at stage end, so generate-report.sh publishes the HTML
  into a ConfigMap (validation-report-<sha8>) and fetch-report.sh pulls it back for upload.
- Secrets are written via `--from-file` from umask-077 temp files, never `--from-literal`
  (keeps values out of process listings; also what the secret scanner requires).

## Status
- [x] Meta / architecture / design / plan approved
- [x] app/, infra/, helm/, k8s/, runner-image/, scripts/, tests/, docs/
- [x] Dispatch shim + pipelines rendered (deploy, destroy, ci-build, ci-validate)
- [x] validate_project PASS (75 files); known-issue warnings reviewed, none apply
- [~] test_project SKIPPED — sandbox detects language from repo root; Gradle project is
      under app/. Sandbox gap, not a project defect; does not block the push.
- [ ] push repo → set RUNNER_GITHUB_PAT → deploy → verify runners

## Secrets
- `RUNNER_GITHUB_PAT` — classic PAT, `repo` scope. Used by ARC to register runners AND by
  the dispatch jobs to clone. MUST be set AFTER create_repo_and_push, BEFORE deploy.

## Gotchas
- cert-manager webhook reports Ready before it serves admission — bootstrap-arc.sh waits
  for the endpoint then sleeps 20s.
- Node group desired_size has ignore_changes: the Cluster Autoscaler owns it.
- Deleting the app ingress before teardown lets the LB controller remove the ALB cleanly;
  a leftover ALB + SG can block VPC deletion.
- Account has 4/5 VPCs used — this stack creates the 5th. At the limit.
