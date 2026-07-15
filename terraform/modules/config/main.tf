data "aws_region" "current" {}

locals {
  region        = data.aws_region.current.name
  recorder_name = "${var.name_prefix}-${local.region}"
}

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

resource "aws_config_configuration_recorder" "this" {
  name     = local.recorder_name
  role_arn = var.role_arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = var.include_global_resource_types
  }

  recording_mode {
    recording_frequency = var.recording_frequency
  }
}

resource "aws_config_delivery_channel" "this" {
  name           = local.recorder_name
  s3_bucket_name = var.audit_bucket_name
  s3_key_prefix  = var.s3_key_prefix

  snapshot_delivery_properties {
    delivery_frequency = var.snapshot_delivery_frequency
  }

  lifecycle {
    precondition {
      condition     = startswith(var.audit_bucket_arn, "arn:")
      error_message = "audit_bucket_arn must be a valid ARN."
    }
  }

  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}

resource "aws_config_config_rule" "managed" {
  for_each = var.managed_rules

  name                        = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  description                 = each.value.description
  input_parameters            = length(each.value.input_parameters) > 0 ? jsonencode(each.value.input_parameters) : null
  maximum_execution_frequency = each.value.maximum_execution_frequency

  dynamic "scope" {
    for_each = length(each.value.resource_types) > 0 ? [each.value.resource_types] : []

    content {
      compliance_resource_types = scope.value
    }
  }

  source {
    owner             = "AWS"
    source_identifier = each.value.source_identifier
  }

  tags = merge(var.tags, {
    Name = upper("${var.name_prefix}-${replace(each.key, "_", "-")}")
  })

  depends_on = [aws_config_configuration_recorder_status.this]
}
