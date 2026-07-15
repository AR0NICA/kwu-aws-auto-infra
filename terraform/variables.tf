variable "aws_region" { type = string }
variable "dev_region" {
  type    = string
  default = "us-east-1"
}
variable "domain_name" { type = string }
variable "waf_count_mode" {
  description = "Count WAF managed-rule matches instead of blocking them."
  type        = bool
  default     = false
}
variable "security_log_retention_days" {
  description = "CloudWatch retention for WAF, Flow Logs, SSM, and rotation logs."
  type        = number
  default     = 30
}
variable "audit_retention_days" {
  description = "S3 retention for CloudTrail and AWS Config audit objects."
  type        = number
  default     = 90
}
variable "rds_rotation_schedule" {
  description = "EventBridge schedule for the Lambda that requests RDS-managed secret rotation."
  type        = string
  default     = "rate(30 days)"
}
