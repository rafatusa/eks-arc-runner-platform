# Native self-hosted workflows (OPT-IN — not currently active)

These two files are true `runs-on: [self-hosted, eks]` workflows: every job runs
*as* an ephemeral ARC runner pod, with no GitHub-hosted controller in between.

**They are not active.** The repository currently runs CI through the **dispatch
shims** generated from the `pipelines:` block of `.udap/pipeline.yaml`
(`.github/workflows/ci-build.yml` and `ci-validate.yml`). Those shims work with
no manual step: a hosted job submits a Kubernetes Job that runs the real stage
in-cluster on the same runner image, and mirrors its exit code.

## Why activating these requires a hand commit

The UDAP pipeline spec has no runner-placement key — the renderer always emits
`runs-on: ubuntu-latest` — and files under `.github/workflows/` cannot be
authored through the platform.

## Order matters

Remove `ci-build` and `ci-validate` from the `pipelines:` block of
`.udap/pipeline.yaml` **first**, and let a deploy re-render so
`.github/workflows/` contains only `deploy.yml` and `destroy.yml`.

If both mechanisms exist, the next `write_pipeline` re-renders an
`ubuntu-latest` shim **over** your native file. The two cannot own the same
filename.

Full procedure, prerequisites and the runner execution contract:
`docs/DEPLOYMENT.md` → "Optional — switch to native self-hosted execution".

## What changes behaviourally

| | Dispatch shim (active) | Native (these files) |
|---|---|---|
| GitHub job runner | `ubuntu-latest` controller | the ARC runner pod itself |
| Where stages run | in-cluster Job pod | the runner pod |
| Toolchain source | runner image | runner image |
| HTML report | generated in-cluster, pulled back via ConfigMap and uploaded as an artifact | regenerated on the reporting pod |
| Manual setup | none | one hand commit |
