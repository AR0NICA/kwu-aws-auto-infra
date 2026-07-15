terraform {
  required_providers {
    archive = {
      source = "hashicorp/archive"
    }
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "name_prefix" { type = string }
variable "db_instance_identifier" { type = string }
variable "db_instance_arn" { type = string }
variable "database_secret_arn" { type = string }
variable "schedule_expression" {
  type    = string
  default = "rate(30 days)"
}

locals {
  function_name = "${var.name_prefix}-rds-rotation"
}

data "archive_file" "rotation" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.root}/.terraform/${local.function_name}.zip"
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rotation" {
  name               = "${local.function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "rotation" {
  statement {
    sid       = "RotateOnlyManagedDatabase"
    actions   = ["rds:ModifyDBInstance"]
    resources = [var.db_instance_arn]
  }

  statement {
    sid       = "RotateOnlyManagedDatabaseSecret"
    actions   = ["secretsmanager:RotateSecret"]
    resources = [var.database_secret_arn]
  }

  statement {
    sid = "WriteFunctionLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.rotation.arn}:*"]
  }
}

resource "aws_iam_role_policy" "rotation" {
  name   = "rotate-rds-managed-secret"
  role   = aws_iam_role.rotation.id
  policy = data.aws_iam_policy_document.rotation.json
}

resource "aws_cloudwatch_log_group" "rotation" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 30
}

resource "aws_lambda_function" "rotation" {
  function_name = local.function_name
  description   = "Requests an immediate rotation of the RDS-managed master secret"
  role          = aws_iam_role.rotation.arn
  runtime       = "python3.12"
  handler       = "handler.lambda_handler"
  filename      = data.archive_file.rotation.output_path

  source_code_hash = data.archive_file.rotation.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      DB_INSTANCE_IDENTIFIER = var.db_instance_identifier
    }
  }

  depends_on = [aws_iam_role_policy.rotation]
}

resource "aws_cloudwatch_event_rule" "rotation" {
  name                = "${local.function_name}-schedule"
  description         = "Periodically requests RDS-managed master password rotation"
  schedule_expression = var.schedule_expression
}

resource "aws_cloudwatch_event_target" "rotation" {
  rule      = aws_cloudwatch_event_rule.rotation.name
  target_id = "RdsManagedSecretRotation"
  arn       = aws_lambda_function.rotation.arn
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridgeRotationSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rotation.arn
}

output "function_name" { value = aws_lambda_function.rotation.function_name }
output "schedule_arn" { value = aws_cloudwatch_event_rule.rotation.arn }
