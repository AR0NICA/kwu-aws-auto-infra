variable "name_prefix" { type = string }
variable "prd_vpc_id" { type = string }
variable "prd_cidr" { type = string }
variable "prd_route_table_ids" { type = list(string) }
variable "dev_vpc_id" { type = string }
variable "dev_cidr" { type = string }
variable "dev_region" { type = string }
variable "dev_route_table_ids" { type = list(string) }

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.dev]
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_vpc_peering_connection" "this" {
  vpc_id        = var.prd_vpc_id
  peer_vpc_id   = var.dev_vpc_id
  peer_owner_id = data.aws_caller_identity.current.account_id
  peer_region   = var.dev_region
  auto_accept   = false

  tags = {
    Name = "KWU-PRD-VPC-PCX"
    Side = "Requester"
  }
}

resource "aws_vpc_peering_connection_accepter" "this" {
  provider                  = aws.dev
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
  auto_accept               = true

  tags = {
    Name = "KWU-PRD-VPC-PCX"
    Side = "Accepter"
  }
}

resource "aws_route" "prd_to_dev" {
  for_each                  = toset(var.prd_route_table_ids)
  route_table_id            = each.value
  destination_cidr_block    = var.dev_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
  depends_on                = [aws_vpc_peering_connection_accepter.this]
}

resource "aws_route" "dev_to_prd" {
  provider                  = aws.dev
  for_each                  = toset(var.dev_route_table_ids)
  route_table_id            = each.value
  destination_cidr_block    = var.prd_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
  depends_on                = [aws_vpc_peering_connection_accepter.this]
}

output "peering_connection_id" { value = aws_vpc_peering_connection.this.id }
