# Native self-hosted workflows — SOURCE OF TRUTH, install by hand

These two files are the **only** definition of the build and validation
pipelines. Every job carries `runs-on: [self-hosted, eks]`, so it runs *as* an
ephemeral ARC runner pod in the EKS cluster, with no GitHub-hosted controller in
between.

## Status

`ci-build` and `ci-validate` have been **removed** from the `pipelines:` block of
`.udap/pipeline.yaml`, and the old dispatch layer (`scripts/ci/dispatch.sh`,
`scripts/ci/fetch-report.sh`, `k8s/ci-job/`) is deleted. `.github/workflows/`
now contains only the platform-rendered `deploy.yml` and `destroy.yml`.

**Until these files are copied into `.github/workflows/`, the repository has no
CI build or validation workflow.**

## Install (or refresh) them

```bash
git pull
cp ci-build.yml    ../../.github/workflows/ci-build.yml
cp ci-validate.yml ../../.github/workflows/ci-validate.yml

cd ../..
git add .github/workflows/ci-build.yml .github/workflows/ci-validate.yml
git commit -m "ci: run build and validation natively on EKS self-hosted runners"
git push
```

This must be a human commit: the platform refuses agent writes anywhere under
`.github/workflows/`.

Keep editing **these** files and re-copying, so the two locations never drift.

## Do not re-add them to the pipeline spec

If `ci-build` / `ci-validate` reappear in `pipelines:`, the next
`write_pipeline` renders an `ubuntu-latest` shim **over** the native file and CI
silently moves off the cluster. The two mechanisms cannot own the same filename.

## Before the first run

```bash
kubectl -n actions-runner-system get runners -o wide
```

At least one runner in phase `Running`, with labels
`self-hosted, linux, x64, eks`. An unmatched `runs-on` makes jobs **queue
indefinitely** rather than fail, so check this first if nothing starts.

## What the runner pod provides

| Concern | Source |
|---|---|
| Toolchain (JDK 21, kubectl, helm, terraform, k6, AWS CLI) | baked into `runner-image/Dockerfile` — no `setup-*` actions |
| Docker | ARC's daemon; `DOCKER_HOST=unix:///run/docker.sock` is exported by ARC |
| AWS credentials | `AWS_*` repo secrets in the workflow `env:` (IRSA alone cannot read the terraform state bucket) |
| Artifacts between jobs | nothing survives — each job is a fresh pod |

Full prerequisites, execution contract and troubleshooting:
`docs/DEPLOYMENT.md` → "CI execution mode — native self-hosted runners".
