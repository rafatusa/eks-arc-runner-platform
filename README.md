# GitHub Self-Hosted Runner Platform on Amazon EKS

An Amazon EKS cluster that hosts **ephemeral GitHub Actions runners** managed by
[Actions Runner Controller (ARC)](https://github.com/actions/actions-runner-controller).
Runner pods are created on demand from queued workflow jobs, execute exactly one
job each, and are destroyed afterwards. A Spring Boot service is built, pushed to
Amazon ECR and deployed to the same cluster as the workload that proves it works.

```
Developer ──push──▶ GitHub Actions ──queued job──▶ ARC ──creates──▶ Runner Pod (EKS)
                                                                        │
                                                        build ▸ test ▸ push ▸ deploy
                                                                        ▼
                                                    Spring Boot pods behind an ALB
```

---

## What gets provisioned

| Layer | Components |
|---|---|
| **Network** | VPC `10.20.0.0/16`, 2 public + 2 private subnets across 2 AZs, Internet Gateway, NAT Gateway, route tables, security groups |
| **Compute** | EKS 1.31 control plane, managed node group (t3.large, 2–6 nodes, private subnets) |
| **Identity** | Cluster/node IAM roles, OIDC provider, IRSA roles for the LB controller, Cluster Autoscaler and runner pods |
| **Registry** | ECR repository with scan-on-push and a 20-image lifecycle policy |
| **Observability** | CloudWatch log groups (control plane, application, runners) + a node-capacity alarm |
| **Cluster add-ons** | Metrics Server, AWS Load Balancer Controller, Cluster Autoscaler, cert-manager |
| **Runner platform** | Actions Runner Controller, `RunnerDeployment` (ephemeral), `HorizontalRunnerAutoscaler` (1 → 20) |
| **Application** | Spring Boot 3.2 / Java 21 REST API, Helm chart, ALB ingress, HPA |

Estimated cost: **~USD 250–300/month** at idle (EKS control plane $73, two
t3.large nodes ~$120, NAT Gateway ~$33 + data, ALB ~$17). Scaling runners out
adds nodes and therefore cost — see [Scaling](#scaling-behaviour).

---

## Repository layout

```
app/                       Spring Boot 3.2 service (Gradle, Java 21)
  config/                  Checkstyle, PMD, SpotBugs rule sets
  Dockerfile               Multi-stage build, non-root runtime
infra/                     All Terraform (VPC, EKS, IAM/IRSA, ECR, CloudWatch)
helm/app/                  Helm chart for the Spring Boot service
k8s/arc/                   RunnerDeployment + HorizontalRunnerAutoscaler + RBAC
k8s/ci-job/                Job template used to run CI stages inside the cluster
runner-image/              Runner toolchain image (JDK 21, kubectl, helm, k6, awscli)
scripts/                   Bootstrap + deploy + verification scripts
  ci/                      Build and validation pipeline stages
tests/k6/                  Load test with pass/fail thresholds
docs/                      Deployment guide, pipeline diagram, Phase-2 workflows
.udap/architecture.d2      Architecture source of truth
.udap/pipeline.yaml        Pipeline spec (workflows are rendered from it)
```

---

## The application

| Endpoint | Purpose |
|---|---|
| `GET /` | HTML landing page showing the version and serving pod |
| `GET /health` | JSON status document used by probes, the ALB and smoke tests |
| `GET /hello?name=` | Greeting endpoint |
| `GET /actuator/health` | Spring Actuator liveness/readiness groups |

Quality gates enforced on every build: **Checkstyle**, **PMD**, **SpotBugs**,
**JUnit 5**, and **JaCoCo** with a 70% line-coverage floor. REST Assured tests
are tagged `e2e` and run only against a deployed instance.

Run it locally:

```bash
cd app
./gradlew bootRun        # http://localhost:8080
./gradlew check          # full static analysis + tests + coverage gate
```

---

## Pipelines

There are four workflows. **Two are rendered from `.udap/pipeline.yaml` and must
not be edited by hand.**

### `deploy` — creates the platform (GitHub-hosted)

`lint → test → build → provision → configure → verify`

`configure` is where the platform is assembled: Helm-installs Metrics Server,
the AWS Load Balancer Controller and the Cluster Autoscaler; installs
cert-manager and ARC; builds and pushes the runner toolchain image; applies the
`RunnerDeployment` and `HorizontalRunnerAutoscaler`; then builds, pushes and
deploys the application.

This workflow runs on GitHub-hosted runners **by design** — it is what creates
the self-hosted runners, so it cannot depend on them existing.

### `ci-build` — build pipeline

`Gradle Build → Checkstyle → PMD → SpotBugs → JUnit → JaCoCo → Docker Build → ECR Push → Helm Upgrade → Verify Rollout`

### `ci-validate` — validation pipeline

`Smoke Test → REST Assured → k6 Load Test → Deployment Verification → HTML Report`

### `destroy` — tears the platform down

Rendered automatically; runs `terraform destroy` against the same state backend.

> **How the build and validation pipelines reach the cluster.** Each job is a
> thin controller running on `ubuntu-latest`: it submits a Kubernetes Job that
> executes the real stage **inside the cluster** on the same toolchain image the
> ARC runners use, streams the logs back, and exits with the in-cluster exit
> code. The work runs in Kubernetes, but these jobs are not themselves ARC
> runners. See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#phase-2--native-self-hosted-execution)
> for the one-commit switch to native `runs-on: [self-hosted, eks]`.

---

## Scaling behaviour

**Runners.** The `HorizontalRunnerAutoscaler` watches
`TotalNumberOfQueuedAndInProgressWorkflowRuns` for this repository and scales the
pool between **1 and 20** pods. One runner stays warm so a queued job starts
immediately; scale-down waits 5 minutes after a scale-out so a queue that just
drained does not thrash the pool.

**Nodes.** When runner pods cannot be scheduled, the Cluster Autoscaler adds
nodes (up to 6) to the managed node group. A CloudWatch alarm fires when the
group sits at maximum size for 15 minutes — that is the signal to raise
`node_max_size`.

**Application.** A `HorizontalPodAutoscaler` scales the Spring Boot deployment
from 2 to 6 replicas at 70% CPU.

---

## Security notes

- Runner pods and dispatched CI jobs authenticate to AWS with **IRSA** — no
  static AWS credentials exist inside the cluster.
- The ARC GitHub token lives only in a Kubernetes secret created at deploy time
  from the `RUNNER_GITHUB_PAT` repository secret; it never appears in a manifest.
- Worker nodes run in **private subnets** with egress through a NAT Gateway;
  only the ALB is internet-facing.
- Application containers run as a non-root user with a read-only root filesystem
  and all capabilities dropped.
- Runner RBAC is scoped to the resources the pipelines actually touch — there is
  no `cluster-admin` binding.

**Ephemeral runners are a security property, not just a cleanliness one:** no job
inherits filesystem state, credentials or a Docker cache from a previous job.

---

## Getting started

See **[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)** for the full guide: prerequisites,
the GitHub PAT, deploying, verifying that runners registered, running the
pipelines, troubleshooting and teardown.

---

## Architecture

- Infrastructure: [`.udap/architecture.d2`](.udap/architecture.d2)
- CI/CD topology: [`docs/pipeline.d2`](docs/pipeline.d2)

Render either with `d2 <file>.d2 <file>.svg`.
