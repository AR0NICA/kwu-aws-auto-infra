variable "name_prefix" { type = string }
variable "vpc_cidr" { type = string }
variable "public_subnets" { type = map(object({ cidr = string, availability_zone = string })) }
variable "tomcat_subnets" { type = map(object({ cidr = string, availability_zone = string, private_ip = string })) }
variable "database_subnets" { type = map(object({ cidr = string, availability_zone = string })) }

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "KWU-PRD-VPC" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "KWU-PRD-VPC-IGW" }
}

resource "aws_subnet" "public" {
  for_each                = var.public_subnets
  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = true
  tags                    = { Name = "KWU-PRD-VPC-${upper(replace(each.key, "_", "-"))}-PUB" }
}

resource "aws_subnet" "tomcat" {
  for_each          = var.tomcat_subnets
  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.availability_zone
  tags              = { Name = "KWU-PRD-VPC-${upper(replace(each.key, "_", "-"))}-PRI" }
}

resource "aws_subnet" "database" {
  for_each          = var.database_subnets
  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.availability_zone
  tags              = { Name = "KWU-PRD-VPC-${upper(replace(each.key, "_", "-"))}-PRI" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "KWU-PRD-VPC-RT-PUB" }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "KWU-PRD-VPC-NGW-EIP-2A" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["nginx_2a"].id
  depends_on    = [aws_internet_gateway.this]
  tags          = { Name = "KWU-PRD-VPC-NGW-2A" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "KWU-PRD-VPC-RT-PRI" }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "tomcat" {
  for_each       = aws_subnet.tomcat
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "database" {
  for_each       = aws_subnet.database
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

output "vpc_id" { value = aws_vpc.this.id }
output "vpc_cidr" { value = var.vpc_cidr }
output "public_route_table_id" { value = aws_route_table.public.id }
output "private_route_table_id" { value = aws_route_table.private.id }
output "bastion_subnet_id" { value = aws_subnet.public["bastion"].id }
output "nginx_subnet_ids" { value = { for key, subnet in aws_subnet.public : key => subnet.id if startswith(key, "nginx_") } }
output "tomcat_subnet_ids" { value = { for key, subnet in aws_subnet.tomcat : key => subnet.id } }
output "database_subnet_ids" { value = { for key, subnet in aws_subnet.database : key => subnet.id } }
