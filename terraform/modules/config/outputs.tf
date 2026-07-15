output "recorder_name" {
  description = "Name of the regional customer-managed AWS Config recorder."
  value       = aws_config_configuration_recorder.this.name
}

output "delivery_bucket_arn" {
  description = "Shared S3 bucket ARN used by the regional delivery channel."
  value       = var.audit_bucket_arn
}

output "rule_ids" {
  description = "IDs of managed AWS Config rules keyed by their static input keys."
  value       = { for key, rule in aws_config_config_rule.managed : key => rule.id }
}
