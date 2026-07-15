data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  standards = merge(
    var.enable_fsbp_standard ? {
      fsbp = "arn:${data.aws_partition.current.partition}:securityhub:${data.aws_region.current.name}::standards/aws-foundational-security-best-practices/v/1.0.0"
    } : {},
    var.enable_cis_1_2_standard ? {
      cis_1_2 = "arn:${data.aws_partition.current.partition}:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.2.0"
    } : {}
  )
}

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

resource "aws_guardduty_detector" "this" {
  enable                       = true
  finding_publishing_frequency = var.guardduty_finding_publishing_frequency
  tags                         = merge(var.tags, { Name = upper("${var.name_prefix}-guardduty") })
}

resource "aws_guardduty_detector_feature" "this" {
  for_each = var.guardduty_feature_statuses

  detector_id = aws_guardduty_detector.this.id
  name        = each.key
  status      = each.value
}

resource "aws_securityhub_account" "this" {
  enable_default_standards  = false
  control_finding_generator = "SECURITY_CONTROL"
  auto_enable_controls      = true
}

resource "aws_securityhub_standards_subscription" "this" {
  for_each = local.standards

  standards_arn = each.value

  depends_on = [aws_securityhub_account.this]
}

resource "aws_securityhub_finding_aggregator" "this" {
  count = length(var.linked_regions) > 0 ? 1 : 0

  linking_mode      = "SPECIFIED_REGIONS"
  specified_regions = sort(tolist(var.linked_regions))

  depends_on = [aws_securityhub_account.this]
}
