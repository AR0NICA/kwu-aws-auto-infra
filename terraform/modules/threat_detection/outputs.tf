output "guardduty_detector_id" {
  description = "Regional GuardDuty detector ID."
  value       = aws_guardduty_detector.this.id
}

output "securityhub_arn" {
  description = "Regional Security Hub CSPM hub ARN."
  value       = aws_securityhub_account.this.arn
}

output "enabled_standard_ids" {
  description = "Enabled Security Hub CSPM standards keyed by their static names."
  value       = { for key, standard in aws_securityhub_standards_subscription.this : key => standard.id }
}

output "finding_aggregator_arn" {
  description = "Security Hub finding aggregator ARN in the home Region, if configured."
  value       = try(aws_securityhub_finding_aggregator.this[0].id, null)
}
