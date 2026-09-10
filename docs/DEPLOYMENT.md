# Deployment Guide

How to deploy, verify, operate and tear down the GitHub Self-Hosted Runner
Platform. Read [Prerequisites](#prerequisites) before the first deploy — one
secret must be created by hand.

---

## Prerequisites

| Requirement | Detail |
|---|---|
| AWS account | With EKS/VPC/IAM/ECR permissions. Verified: account `241533126054`, region `us-east-1`. |
| VPC headroom | This stack creates its **own** VPC. The default AWS limit is 5 per region — confirm you have one free (`aws ec2 describe-vpcs --query 'length(Vpcs)'`). |
| Elastic IP headroom | One EIP is consumed by the NAT Gateway. |
| GitHub PAT | A classic PAT with the **`repo`** scope. ARC uses it to register runners. |
| Local tooling (optional) | `kubectl`, `helm`, `awscli` — only for manual inspection. |

### Creating the runner PAT

1. GitHub → Settings → Developer settings → **Personal access tokens (classic)**.
2. **Generate new token**, scope: **`repo`** (full control of private repositories).
   - For an organisation-wide runner pool you would additionally need `admin:org`;
     this platform registers runners at the **repository** level, so `repo` is enough.
3. Set an expiry you are willing to rotate. When it expires, runners stop registering.
4. Store it as the repository secret **`RUNNER_GITHUB_PAT`**.

Every other secret (`AWS_*`, `PROJECT_NAME`, `TF_STATE_BUCKET`) is injected by the
platform at deploy time.

---

## Phase 1 — deploy the platform

The deploy workflow runs on GitHub-hosted runners. That is deliberate: it is the
workflow that *creates* the self-hosted runners, so it cannot depend on them.

```
lint → test → build → provision → configure → verify
```

| Stage | What happens | Typical duration |
|---|---|---|
| `lint` | Checkstyle, PMD, SpotBugs | 2–3 min |
| `test` | JUnit + JaCoCo coverage gate | 2–4 min |
| `build` | `bootJar` | 1–2 min |
| `provision` | `terraform apply` — VPC, EKS, node group, IAM/OIDC, ECR, CloudWatch | **15–20 min** (EKS control plane alone is ~10 min) |
| `configure` | Helm add-ons, cert-manager, ARC, runner image build, app deploy | **15–25 min** (the runner image is ~1.5 GB on first build) |
| `verify` | Cluster, add-on, runner and endpoint checks | 3–8 min |

Expect **40–60 minutes** for a first deploy.

### What `configure` does, in order

1. `scripts/bootstrap-addons.sh` — waits for nodes, then Helm-installs
   Metrics Server, the AWS Load Balancer Controller (IRSA) and the Cluster
   Autoscaler (IRSA).
2. `scripts/bootstrap-arc.sh` — installs cert-manager, waits for its webhook to
   actually serve admission requests, builds and pushes the runner toolchain
   image to ECR, installs ARC with the PAT secret, applies the
   `RunnerDeployment` + `HorizontalRunnerAutoscaler`, and waits for a runner to
   reach phase `Running` **on the image this run published**.
3. `scripts/build-and-push.sh` — builds the application image and pushes it.
4. `scripts/deploy-app.sh` — `helm upgrade --install`, waits for the rollout and
   for the ALB hostname to be provisioned.

### Runner image versioning

The toolchain image is tagged with a **hash of `runner-image/`**
(`runner-<hash>`), and additionally pushed as `runner-latest`. Changing the
Dockerfile produces a new tag, so the rebuild actually happens and the pool
rolls onto it. An unchanged toolchain yields the same tag and the ~1.5 GB build
is skipped.

The `RunnerDeployment` uses **`imagePullPolicy: Always`**, so runner pods always
fetch the current `runner-latest` rather than a node's cached copy. This matters:
a tag is mutable, but a node's image cache is **not** invalidated by a re-push.
Any future component that consumes `runner-latest` with `IfNotPresent` must pin
to a digest instead, or it will silently boot a stale toolchain.

---

## Verifying the platform

`verify` runs `scripts/verify-platform.sh`, which checks all of the following and
fails the deploy if any check fails:

- every node is `Ready`
- Metrics Server, the LB controller and the Cluster Autoscaler are `Available`
- the ARC controller is `Available`
- **at least one runner is registered and `Running`**
- **`RunnerDeployment.spec.template.spec.ephemeral == true`**
- **the autoscaler bounds are exactly 1 and 20**
- the application deployment is `Available`
- `/`, `/health` and `/hello` all answer through the public ALB

### Confirming registration from GitHub

**Settings → Actions → Runners** should list runners labelled
`self-hosted, linux, x64, eks`. Their names change constantly — that is the
ephemeral lifecycle working.

### Confirming from the cluster

```bash
aws eks update-kubeconfig --name <project>-eks --region us-east-1

kubectl -n actions-runner-system get runners
kubectl -n actions-runner-system get horizontalrunnerautoscaler
kubectl -n actions-runner-system get pods
```

A healthy idle state is **one** runner in phase `Running` (the configured minimum).

---

## CI execution mode — native self-hosted runners

`ci-build` and `ci-validate` run **natively on the ARC runner pool**: every job
carries `runs-on: [self-hosted, eks]`, so GitHub schedules it directly onto an
ephemeral runner pod in EKS. There is no hosted controller in the middle.

### Workflow ownership — read this before editing

These two workflows are **NOT generated** from `.udap/pipeline.yaml`. They were
deliberately removed from its `pipelines:` block, because the UDAP spec has no
runner-placement key: the renderer always emits `runs-on: ubuntu-latest`, which
can never target the pool.

| Workflow | Source | Owner |
|---|---|---|
| `deploy.yml`, `destroy.yml` | rendered from `.udap/pipeline.yaml` | platform |
| `ci-build.yml`, `ci-validate.yml` | `docs/self-hosted-workflows/` | **hand-committed** |

> **Never re-add `ci-build` / `ci-validate` to `pipelines:`.** The next
> `write_pipeline` would render an `ubuntu-latest` shim **over** the native
> file, and CI would silently move off the cluster. The two mechanisms cannot
> own the same filename.

### Installing or updating the native workflows

The platform refuses agent writes under `.github/workflows/`, so this is a
human step:

```bash
# 1. Confirm the pool is live and carries the toolchain
kubectl -n actions-runner-system get runners      # >= 1 in phase Running

# 2. Install (or refresh) the native workflows
git pull
cp docs/self-hosted-workflows/ci-build.yml    .github/workflows/ci-build.yml
cp docs/self-hosted-workflows/ci-validate.yml .github/workflows/ci-validate.yml

git add .github/workflows/ci-build.yml .github/workflows/ci-validate.yml
git commit -m "ci: run build and validation natively on EKS self-hosted runners"
git push
```

Then trigger **CI Build (self-hosted)** from the Actions tab and watch jobs land:

```bash
kubectl -n actions-runner-system get pods -w
```

`docs/self-hosted-workflows/` remains the **source of truth** — edit there and
re-copy, so the two never drift.

### The native runner execution contract

Three things differ from a GitHub-hosted job, and the workflows depend on all three:

- **Toolchain comes from the image, not from `setup-*` actions.**
  `runner-image/Dockerfile` bakes in JDK 21, kubectl, helm, **terraform**, k6 and
  the AWS CLI. `scripts/lib/common.sh` calls `require_cmd terraform` on nearly
  every stage — a runner image without terraform fails every stage that reads an
  infrastructure output. Re-installing toolchains per job would also repeat on
  all 20 concurrent pods.
- **Docker comes from ARC.** The runner pod has a Docker daemon and ARC exports
  `DOCKER_HOST=unix:///run/docker.sock`. `wait_for_docker()` in
  `scripts/lib/common.sh` assigns its default only when `DOCKER_HOST` is
  **unset** (`:=`), so ARC's real value wins — do not change that to a plain
  assignment.
- **Credentials: IRSA + static keys, deliberately both.** Runner pods assume
  `<project>-runner-role` (ECR push + `eks:DescribeCluster`). That role
  intentionally has **no S3 access**, so `terraform init` against the state
  bucket needs the `AWS_*` secrets, which take precedence over IRSA in the
  credential chain. Removing them breaks every stage at `terraform init`.

### Job boundaries

Every job is a **separate ephemeral pod**. Nothing survives between jobs: not the
Docker daemon, not `reports/`, not a kubeconfig.

- `ecr_push` **rebuilds** the image rather than expecting `docker_build`'s layer
  cache; the header of `scripts/ci/ecr-push.sh` documents this.
- Validation stages resolve the app URL from the cluster every time
  (`scripts/ci/lib/resolve-url.sh`) instead of threading it through job outputs,
  which GitHub drops when the value derives from a secret.
- The HTML report generator re-runs the checks it needs on its own pod, since no
  earlier job's `reports/` directory is reachable.

---

## Running the pipelines

Both are `workflow_dispatch`; `ci-build` also runs on push to `main`, and
`ci-validate` chains off a successful `ci-build`.

### `ci-build`

`Gradle Build → Checkstyle → PMD → SpotBugs → JUnit → JaCoCo → Docker Build → ECR Push → Helm Upgrade → Verify Rollout`

### `ci-validate`

`Smoke Test → REST Assured → k6 Load Test → Deployment Verification → HTML Report`

The k6 stage **fails the pipeline** if error rate ≥ 1% or p95 latency ≥ 800 ms.
The final stage publishes `validation-report` as a workflow artifact — open
`index.html` for the rendered report.

Watch execution land in the cluster:

```bash
kubectl -n actions-runner-system get pods -w
```

---

## Scaling and cost

| Control | Where | Default |
|---|---|---|
| Runner min/max | `k8s/arc/horizontal-runner-autoscaler.yaml` | 1 / 20 |
| Scale-down delay | same file | 300 s after scale-out |
| Node min/max | `infra/variables.tf` (`node_min_size`, `node_max_size`) | 2 / 6 |
| Node type | `infra/variables.tf` (`node_instance_types`) | `t3.large` |
| App replicas | `helm/app/values.yaml` (`autoscaling`) | 2 → 6 at 70% CPU |

**20 runners will not fit on 6 t3.large nodes** if every job is heavy. Raise
`node_max_size`, or switch runner pods to a dedicated spot node group, before
relying on full concurrency. The CloudWatch alarm
`<project>-node-group-at-capacity` fires when the group sits at max for 15 min.

---

## Troubleshooting

### Runners never register

```bash
kubectl -n actions-runner-system logs deployment/actions-runner-controller --tail=100
kubectl -n actions-runner-system describe runners
```

Almost always the PAT: expired, missing the `repo` scope, or created against the
wrong account. Update `RUNNER_GITHUB_PAT` and re-run the deploy.

### A self-hosted job stays queued forever

This is the characteristic native-mode failure: an unmatched `runs-on` **queues**
rather than failing, so the job simply sits there. No runner carries the
requested labels. Check the pool exists and that the labels in
`k8s/arc/runner-deployment.yaml` match the workflow's `runs-on`:

```bash
kubectl -n actions-runner-system get runners -o wide   # LABELS column
```

Expected: `self-hosted, linux, x64, eks`.

### A stage fails with "required command not found"

**Check which image actually ran before rebuilding anything.** The tool may well
be in the image already — this failure has been caused by a *stale node cache*
rather than a missing tool:

```bash
# What the ARC runners run (imagePullPolicy: Always — always current)
kubectl -n actions-runner-system get pod <runner-pod> -o jsonpath='{.spec.containers[*].image}'

# What the node has cached
kubectl get node <node> -o jsonpath='{.status.images[*].names}'

# Prove the tool is or is not on the image
kubectl exec -n actions-runner-system <runner-pod> -c runner -- which terraform
```

"The binary is on the image" is **not** proof that the failing pod ran that
image. Compare the digests before concluding anything.

If the tool is genuinely absent, add it to `runner-image/Dockerfile` and re-run
the deploy — the content hash changes, so the image rebuilds and the pool rolls.
Do **not** paper over it with a `setup-*` action: that reinstalls on every one of
up to 20 pods.

### A stage fails at `terraform init` with AccessDenied

The `AWS_*` secrets are missing from the workflow `env:` block. IRSA alone cannot
read the state bucket — the runner role has no S3 access by design. See
"The native runner execution contract" above.

### Runner pods are `Pending`

```bash
kubectl -n actions-runner-system describe pod <pod> | tail -30
kubectl -n kube-system logs deployment/cluster-autoscaler-aws-cluster-autoscaler --tail=50
```

Usually no node has room and the Cluster Autoscaler is adding one (2–4 minutes),
or the node group is already at `node_max_size`.

### The ALB never gets a hostname

```bash
kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=100
kubectl -n runner-platform describe ingress runner-platform-api
```

Check that public subnets carry `kubernetes.io/role/elb=1` (Terraform sets this)
and that the controller's IRSA role resolved.

### Application pods `CrashLoopBackOff`

```bash
kubectl -n runner-platform logs <pod> --previous
```

---

## Teardown

Use the platform's **Destroy** action, which dispatches the rendered
`destroy.yml` (`terraform destroy` against the same backend and variables).

Before destroying, be aware:

- The ALB is created by the LB controller, **not** Terraform. Deleting the app's
  ingress first lets the controller remove it cleanly:
  ```bash
  kubectl -n runner-platform delete ingress runner-platform-api
  ```
  Otherwise a leftover ALB and its security group can block VPC deletion.
- The ECR repository is `force_delete = true`, so images are removed with it.
- Terraform state persists in the platform state bucket, so the project can be
  redeployed later without re-scaffolding.

After teardown, confirm nothing is left:

```bash
aws eks list-clusters --region us-east-1
aws ec2 describe-vpcs --filters "Name=tag:Project,Values=<project>" --region us-east-1
```
