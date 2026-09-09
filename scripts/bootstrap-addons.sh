#!/usr/bin/env bash
#
# Installs the cluster add-ons that everything else depends on:
#   * Metrics Server        — resource metrics for HPA and the runner autoscaler
#   * AWS Load Balancer Ctl — turns the app Ingress into a real ALB
#   * Cluster Autoscaler    — adds nodes when runner pods cannot be scheduled
#
# Idempotent: `helm upgrade --install` is safe to re-run on every deploy.

set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd helm
require_cmd kubectl
require_cmd aws
require_cmd terraform

METRICS_SERVER_CHART_VERSION="3.12.2"
ALB_CONTROLLER_CHART_VERSION="1.10.1"
CLUSTER_AUTOSCALER_CHART_VERSION="9.43.2"

log "Reading infrastructure outputs"
CLUSTER_NAME="$(tf_output cluster_name)"
AWS_REGION_VALUE="$(tf_output aws_region)"
VPC_ID="$(tf_output vpc_id)"
ALB_ROLE_ARN="$(tf_output alb_controller_role_arn)"
CA_ROLE_ARN="$(tf_output cluster_autoscaler_role_arn)"
info "cluster=${CLUSTER_NAME} region=${AWS_REGION_VALUE} vpc=${VPC_ID}"

ensure_kubeconfig

log "Waiting for worker nodes to become Ready"
retry 40 15 kubectl wait --for=condition=Ready nodes --all --timeout=30s \
  || fail "no worker node reached the Ready condition"
kubectl get nodes -o wide

log "Adding Helm repositories"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null
helm repo update >/dev/null

##############################################################################
log "Installing Metrics Server"
##############################################################################
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --version "${METRICS_SERVER_CHART_VERSION}" \
  --set "args={--kubelet-preferred-address-types=InternalIP\,ExternalIP\,Hostname}" \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --wait --timeout 10m

##############################################################################
log "Installing AWS Load Balancer Controller"
##############################################################################
# The controller's CRDs are not managed by the chart's normal upgrade path.
kubectl apply --server-side --force-conflicts -f \
  "https://raw.githubusercontent.com/aws/eks-charts/v0.0.187/stable/aws-load-balancer-controller/crds/crds.yaml"

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version "${ALB_CONTROLLER_CHART_VERSION}" \
  --set "clusterName=${CLUSTER_NAME}" \
  --set "region=${AWS_REGION_VALUE}" \
  --set "vpcId=${VPC_ID}" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${ALB_ROLE_ARN}" \
  --set replicaCount=1 \
  --wait --timeout 10m

##############################################################################
log "Installing Cluster Autoscaler"
##############################################################################
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --version "${CLUSTER_AUTOSCALER_CHART_VERSION}" \
  --set "autoDiscovery.clusterName=${CLUSTER_NAME}" \
  --set "awsRegion=${AWS_REGION_VALUE}" \
  --set rbac.serviceAccount.create=true \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set "rbac.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${CA_ROLE_ARN}" \
  --set "extraArgs.scale-down-unneeded-time=5m" \
  --set "extraArgs.scale-down-delay-after-add=5m" \
  --set "extraArgs.skip-nodes-with-local-storage=false" \
  --set "extraArgs.skip-nodes-with-system-pods=false" \
  --set "extraArgs.balance-similar-node-groups=true" \
  --wait --timeout 10m

log "Add-on rollout status"
kubectl -n kube-system rollout status deployment/metrics-server --timeout=5m
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=5m
kubectl -n kube-system rollout status deployment/cluster-autoscaler-aws-cluster-autoscaler --timeout=5m

log "Cluster add-ons installed"
kubectl -n kube-system get deployments
