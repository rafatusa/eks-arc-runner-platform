output "cluster_name" {
  description = "EKS cluster name — used by aws eks update-kubeconfig."
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "Kubernetes version of the control plane."
  value       = aws_eks_cluster.main.version
}

output "aws_region" {
  description = "Region every stage should operate in."
  value       = var.aws_region
}

output "vpc_id" {
  description = "Platform VPC id."
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnets hosting the worker nodes."
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnets used by the ALB."
  value       = aws_subnet.public[*].id
}

output "ecr_repository_url" {
  description = "ECR repository URL for the application image."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_name" {
  description = "ECR repository name."
  value       = aws_ecr_repository.app.name
}

output "alb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller."
  value       = aws_iam_role.alb_controller.arn
}

output "cluster_autoscaler_role_arn" {
  description = "IRSA role ARN for the Cluster Autoscaler."
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "runner_role_arn" {
  description = "IRSA role ARN assumed by the self-hosted runner pods."
  value       = aws_iam_role.runner.arn
}

output "alb_security_group_id" {
  description = "Security group the ingress attaches to the public ALB."
  value       = aws_security_group.alb.id
}

output "application_log_group" {
  description = "CloudWatch log group for application logs."
  value       = aws_cloudwatch_log_group.application.name
}
