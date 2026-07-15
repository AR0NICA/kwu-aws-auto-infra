terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "interface_subnet_ids" { type = map(string) }
variable "route_table_ids" { type = map(string) }
variable "allowed_security_group_ids" { type = map(string) }
variable "enable_secretsmanager" {
  type    = bool
  default = false
}
variable "enable_cloudwatch_logs" {
  type    = bool
  default = true
}

data "aws_region" "current" {}

locals {
  required_interface_services = {
    ssm         = "ssm"
    ssmmessages = "ssmmessages"
    ec2messages = "ec2messages"
  }
  optional_interface_services = merge(
    var.enable_secretsmanager ? { secretsmanager = "secretsmanager" } : {},
    var.enable_cloudwatch_logs ? { logs = "logs" } : {}
  )
  interface_services = merge(local.required_interface_services, local.optional_interface_services)
}

resource "aws_security_group" "endpoints" {
  name        = "${var.name_prefix}-endpoints-sg"
  description = "PrivateLink interface endpoint access managed by Terraform"
  vpc_id      = var.vpc_id
  tags        = { Name = upper("${var.name_prefix}-endpoints-sg") }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each = var.allowed_security_group_ids

  security_group_id            = aws_security_group.endpoints.id
  referenced_security_group_id = each.value
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "HTTPS from ${each.key} managed nodes"
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_services

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = values(var.interface_subnet_ids)
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = upper("${var.name_prefix}-${each.key}-endpoint") }

  depends_on = [aws_vpc_security_group_ingress_rule.https]
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = values(var.route_table_ids)

  tags = { Name = upper("${var.name_prefix}-s3-endpoint") }
}

output "interface_endpoint_ids" {
  value = { for key, endpoint in aws_vpc_endpoint.interface : key => endpoint.id }
}
output "s3_endpoint_id" { value = aws_vpc_endpoint.s3.id }
output "endpoint_security_group_id" { value = aws_security_group.endpoints.id }
