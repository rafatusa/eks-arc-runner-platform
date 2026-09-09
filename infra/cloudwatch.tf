resource "aws_cloudwatch_log_group" "application" {
  name              = "/${var.project_name}/application"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.project_name}-application-logs"
  }
}

resource "aws_cloudwatch_log_group" "runners" {
  name              = "/${var.project_name}/runners"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.project_name}-runner-logs"
  }
}

# Surfaces node-group pressure: when runner demand pins the cluster at max size
# for a sustained period, the max node count is the thing to raise.
resource "aws_cloudwatch_metric_alarm" "node_group_at_capacity" {
  alarm_name          = "${var.project_name}-node-group-at-capacity"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "GroupInServiceInstances"
  namespace           = "AWS/AutoScaling"
  period              = 300
  statistic           = "Maximum"
  threshold           = var.node_max_size
  alarm_description   = "Worker node group has been at its maximum size for 15 minutes."
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = try(
      aws_eks_node_group.main.resources[0].autoscaling_groups[0].name,
      ""
    )
  }

  tags = {
    Name = "${var.project_name}-node-capacity-alarm"
  }
}
