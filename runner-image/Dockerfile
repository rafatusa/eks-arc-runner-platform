# syntax=docker/dockerfile:1
#
# Toolchain image for the ephemeral self-hosted runners.
#
# Baking the toolchain in matters: runner pods are destroyed after every job, so
# anything installed at job time is re-installed on every one of the up-to-20
# concurrent pods. This image is built once by the deploy pipeline and pushed to
# ECR, and it is what the RunnerDeployment actually runs.
FROM summerwind/actions-runner:ubuntu-22.04

USER root

ARG JAVA_VERSION=21
ARG KUBECTL_VERSION=v1.31.3
ARG HELM_VERSION=v3.16.3
ARG K6_VERSION=v0.54.0
ARG TERRAFORM_VERSION=1.9.8

# Temurin JDK 21 from Adoptium's apt repository — Ubuntu 22.04's own archive
# does not carry a JDK 21 package.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg unzip jq git bash tar gzip; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
        | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb jammy main" \
        > /etc/apt/sources.list.d/adoptium.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "temurin-${JAVA_VERSION}-jdk"; \
    rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/temurin-21-jdk-amd64
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# kubectl — used by the pipeline to verify rollouts.
RUN set -eux; \
    curl -fsSL -o /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"; \
    chmod +x /usr/local/bin/kubectl; \
    kubectl version --client

# Helm — used by the helm_upgrade stage.
RUN set -eux; \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tgz; \
    tar -xzf /tmp/helm.tgz -C /tmp; \
    mv /tmp/linux-amd64/helm /usr/local/bin/helm; \
    rm -rf /tmp/helm.tgz /tmp/linux-amd64; \
    helm version --short

# Terraform — REQUIRED for native self-hosted execution (Phase 2).
#
# Every stage reads infrastructure values itself via `terraform output` rather
# than threading them between jobs (the project name is a secret, so derived
# ECR/ALB identifiers are masked and dropped from job outputs). Under the
# Phase-1 dispatch shims the GitHub-hosted job supplied terraform via
# hashicorp/setup-terraform; when the job runs natively ON a runner pod there is
# no such step, so the binary must be in this image or scripts/lib/common.sh
# fails at `require_cmd terraform`.
RUN set -eux; \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
        -o /tmp/terraform.zip; \
    unzip -q /tmp/terraform.zip -d /tmp; \
    mv /tmp/terraform /usr/local/bin/terraform; \
    chmod +x /usr/local/bin/terraform; \
    rm -f /tmp/terraform.zip; \
    terraform version

# k6 — used by the validation pipeline's load stage.
RUN set -eux; \
    curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-amd64.tar.gz" -o /tmp/k6.tgz; \
    tar -xzf /tmp/k6.tgz -C /tmp; \
    mv "/tmp/k6-${K6_VERSION}-linux-amd64/k6" /usr/local/bin/k6; \
    rm -rf /tmp/k6.tgz "/tmp/k6-${K6_VERSION}-linux-amd64"; \
    k6 version

# AWS CLI v2 — ECR login and kubeconfig generation.
RUN set -eux; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip; \
    unzip -q /tmp/awscliv2.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/awscliv2.zip /tmp/aws; \
    aws --version

# Gradle caches survive only within a single job (pods are ephemeral), but a
# writable home directory is still required.
ENV GRADLE_USER_HOME=/home/runner/.gradle
RUN mkdir -p "${GRADLE_USER_HOME}" && chown -R runner:runner /home/runner

USER runner
