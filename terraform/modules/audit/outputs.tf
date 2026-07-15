output "bucket_name" {
  description = "Name of the shared CloudTrail and AWS Config audit bucket."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "ARN of the shared CloudTrail and AWS Config audit bucket."
  value       = aws_s3_bucket.this.arn
}

output "cloudtrail_arn" {
  description = "ARN of the multi-Region CloudTrail trail."
  value       = aws_cloudtrail.this.arn
}

output "config_role_arn" {
  description = "Shared IAM role for regional customer-managed AWS Config recorders."
  value       = aws_iam_role.config.arn

  depends_on = [
    aws_iam_role_policy_attachment.config_managed,
    aws_iam_role_policy.config_delivery
  ]
}

output "config_s3_prefixes" {
  description = "S3 prefixes to pass to each regional AWS Config module."
  value = {
    for region in sort(tolist(var.config_regions)) :
    region => "${var.config_prefix}/${region}"
  }
}
