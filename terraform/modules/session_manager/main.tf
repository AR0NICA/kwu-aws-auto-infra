terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "name_prefix" { type = string }
variable "log_retention_days" {
  type    = number
  default = 30
}

resource "aws_cloudwatch_log_group" "sessions" {
  name              = "/aws/ssm/${var.name_prefix}/sessions"
  retention_in_days = var.log_retention_days
}

resource "aws_ssm_document" "session_preferences" {
  name            = "SSM-SessionManagerRunShell"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Audited Session Manager shell preferences for ${var.name_prefix}"
    sessionType   = "Standard_Stream"
    inputs = {
      s3BucketName           = ""
      s3KeyPrefix            = ""
      s3EncryptionEnabled    = false
      cloudWatchLogGroupName = aws_cloudwatch_log_group.sessions.name
      # CloudWatch Logs still encrypts data at rest with its AWS-owned key.
      # Setting this flag to true requires a customer-managed KMS key to be
      # associated with the log group and otherwise prevents sessions.
      cloudWatchEncryptionEnabled = false
      cloudWatchStreamingEnabled  = true
      idleSessionTimeout          = "20"
      maxSessionDuration          = ""
      runAsEnabled                = false
      runAsDefaultUser            = ""
      shellProfile = {
        linux   = "exec /bin/bash"
        windows = ""
      }
    }
  })
}

output "log_group_name" { value = aws_cloudwatch_log_group.sessions.name }
output "log_group_arn" { value = aws_cloudwatch_log_group.sessions.arn }
