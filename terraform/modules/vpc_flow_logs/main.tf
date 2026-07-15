data "aws_caller_identity" "current" {}
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  region         = data.aws_region.current.name
  log_group_name = "/aws/vpc/flow-logs/${var.name_prefix}/${local.region}"
  role_name      = "${var.name_prefix}-${local.region}-flow-logs"
  log_format = join(" ", [
    "$${version}",
    "$${account-id}",
    "$${interface-id}",
    "$${vpc-id}",
    "$${subnet-id}",
    "$${instance-id}",
    "$${srcaddr}",
    "$${dstaddr}",
    "$${pkt-srcaddr}",
    "$${pkt-dstaddr}",
    "$${srcport}",
    "$${dstport}",
    "$${protocol}",
    "$${packets}",
    "$${bytes}",
    "$${start}",
    "$${end}",
    "$${action}",
    "$${log-status}",
    "$${flow-direction}",
    "$${traffic-path}",
    "$${region}",
    "$${az-id}"
  ])
}

resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  tags              = merge(var.tags, { Name = upper("${var.name_prefix}-${local.region}-flow-logs") })
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:${data.aws_partition.current.partition}:ec2:${local.region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"
      ]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = local.role_name
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = merge(var.tags, { Name = upper(local.role_name) })
}

data "aws_iam_policy_document" "delivery" {
  statement {
    sid    = "WriteVPCFlowLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  statement {
    sid    = "DescribeCloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "delivery" {
  name   = "${local.role_name}-delivery"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.delivery.json
}

resource "aws_flow_log" "this" {
  vpc_id                   = var.vpc_id
  traffic_type             = var.traffic_type
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.this.arn
  iam_role_arn             = aws_iam_role.this.arn
  max_aggregation_interval = var.max_aggregation_interval
  log_format               = local.log_format

  tags = merge(var.tags, { Name = upper("${var.name_prefix}-${local.region}-vpc-flow-log") })

  depends_on = [aws_iam_role_policy.delivery]
}
