output "web_acl_arn" {
  description = "ARN of the regional WAFv2 Web ACL."
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_id" {
  description = "ID of the regional WAFv2 Web ACL."
  value       = aws_wafv2_web_acl.this.id
}

output "log_group_name" {
  description = "CloudWatch Logs group receiving blocked and counted requests."
  value       = try(aws_cloudwatch_log_group.this[0].name, null)
}
