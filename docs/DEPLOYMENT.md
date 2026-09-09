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
workflow that *creates* the self-hosted runners.

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
(`runner-<hash>`), not just `runner-latest`. Changing the Dockerfile produces a
new tag, so the rebuild actually happens and the pool rolls onto it. An
unchanged toolchain yields the same tag and the ~1.5 GB build is skipped.

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

## Phase 2 — native self-hosted execution (CURRENT MODE)

The build and validation pipelines run **natively on the ARC runner pods** via
`runs-on: [self-hosted, eks]`.

### Why the workflow files are committed by hand

The UDAP pipeline spec has no runner-placement key — the renderer always emits
`runs-on: ubuntu-latest` — and files under `.github/workflows/` cannot be
authored through the platform. `ci-build` and `ci-validate` have therefore been
**removed from the `pipelines:` block** of `.udap/pipeline.yaml` (otherwise the
next render would overwrite them with `ubuntu-latest` shims), and the workflows
are committed directly from `docs/self-hosted-workflows/`.

`.udap/pipeline.yaml` still owns `deploy.yml` and `destroy.yml`, which must stay
on GitHub-hosted runners because they create the cluster the runners live in.

### Activating (one commit)

```bash
# 1. Confirm the pool is live
kubectl -n actions-runner-system get runners     # >= 1 in phase Running

# 2. Put the native workflows in place
cp docs/self-hosted-workflows/ci-build.yml    .github/workflows/ci-build.yml
cp docs/self-hosted-workflows/ci-validate.yml .github/workflows/ci-validate.yml

git add .github/workflows/ci-build.yml .github/workflows/ci-validate.yml
git commit -m "ci: run build and validation natively on EKS self-hosted runners"
git push
```

Then trigger **CI Build (self-hosted)** from the Actions tab. Each job queues
until a runner pod picks it up; watch the pool scale out with:

```bash
kubectl -n actions-runner-system get runners -w
```

### The runner execution contract

Two things differ from a GitHub-hosted job, and the workflows depend on both:

- **Toolchain comes from the image, not from `setup-*` actions.**
  `runner-image/Dockerfile` bakes in JDK 21, kubectl, helm, **terraform**, k6 and
  the AWS CLI. `scripts/lib/common.sh` calls `require_cmd terraform` on nearly
  every stage — a runner image without terraform fails every stage that reads an
  infrastructure output. Re-installing toolchains per job would also repeat on
  all 20 concurrent pods.
- **Credentials: IRSA + static keys, deliberately both.** Runner pods assume
  `<project>-runner-role` (ECR push + `eks:DescribeCluster`). That role
  intentionally has **no S3 access**, so `terraform init` against the state
  bucket needs the `AWS_*` secrets, which take precedence over IRSA in the
  credential chain. Removing them breaks every stage at `terraform init`.

### Job boundaries

Every job is a **separate ephemeral pod**. Nothing survives between jobs — not
the Docker daemon, not `reports/`, not a kubeconfig:

- `ecr_push` **rebuilds** the image rather than expecting `docker_build`'s layer
  cache; the header of `scripts/ci/ecr-push.sh` documents this.
- Validation stages resolve the app URL from the cluster every time
  (`scripts/ci/lib/resolve-url.sh`) instead of threading it through job outputs,
  which GitHub drops when the value derives from a secret.

### Reverting to dispatch mode

The dispatch mechanism (`scripts/ci/dispatch.sh`, `k8s/ci-job/`) is retained and
still works. To go back, delete the two workflow files and re-add the `ci-build`
/ `ci-validate` pipelines to `.udap/pipeline.yaml`.

---

## Running the pipelines

Both are `workflow_dispatch` (and `ci-build` also runs on push to `main`).

### `ci-build`

`Gradle Build → Checkstyle → PMD → SpotBugs → JUnit → JaCoCo → Docker Build → ECR Push → Helm Upgrade → Verify Rollout`

### `ci-validate`

`Smoke Test → REST Assured → k6 Load Test → Deployment Verification → HTML Report`

The k6 stage **fails the pipeline** if error rate ≥ 1% or p95 latency ≥ 800 ms.
The final stage publishes `validation-report` as a workflow artifact — open
`index.html` for the rendered report.

Watch execution land on the pool:

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

No runner carries the requested labels. Check the pool exists and that the
labels in `k8s/arc/runner-deployment.yaml` match the workflow's `runs-on`:

```bash
kubectl -n actions-runner-system get runners -o wide   # LABELS column
```

### A self-hosted job fails with "required command not found"

The runner image lacks that tool. Add it to `runner-image/Dockerfile` and re-run
the deploy — the content hash changes, so the image rebuilds and the pool rolls.
Do **not** paper over it with a `setup-*` action in the workflow: that reinstalls
on every one of up to 20 pods.

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
