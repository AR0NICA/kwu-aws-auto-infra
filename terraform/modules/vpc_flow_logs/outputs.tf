output "flow_log_id" {
  description = "ID of the VPC-level Flow Log subscription."
  value       = aws_flow_log.this.id
}

output "log_group_name" {
  description = "CloudWatch Logs group receiving the VPC Flow Logs."
  value       = aws_cloudwatch_log_group.this.name
}

output "delivery_role_arn" {
  description = "IAM role used by VPC Flow Logs for CloudWatch delivery."
  value       = aws_iam_role.this.arn
}
