variable "project_name" {
  description = "Branch-scoped project name used as the prefix for every resource."
  type        = string
}

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the platform VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets (one per AZ)."
  type        = list(string)
  default     = ["10.20.0.0/20", "10.20.16.0/20"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets (one per AZ)."
  type        = list(string)
  default     = ["10.20.32.0/20", "10.20.48.0/20"]
}

variable "kubernetes_version" {
  description = "EKS control plane version (must be in standard support)."
  type        = string
  default     = "1.31"
}

variable "node_instance_types" {
  description = "Instance types for the managed node group hosting runners and the app."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes at steady state."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes the Cluster Autoscaler may create."
  type        = number
  default     = 6
}

variable "node_disk_size" {
  description = "Root volume size (GiB) for worker nodes; runner pods pull container images."
  type        = number
  default     = 50
}

variable "log_retention_days" {
  description = "Retention period for CloudWatch log groups."
  type        = number
  default     = 14
}
