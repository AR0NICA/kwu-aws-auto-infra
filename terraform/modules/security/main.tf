variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "peer_cidr_blocks" {
  type    = list(string)
  default = []
}

locals {
  groups = {
    management = "${var.name_prefix}-management-sg"
    alb        = "${var.name_prefix}-alb-sg"
    nginx      = "${var.name_prefix}-nginx-sg"
    tomcat     = "${var.name_prefix}-tomcat-sg"
    database   = "${var.name_prefix}-database-sg"
  }
}

resource "aws_security_group" "this" {
  for_each    = local.groups
  name        = each.value
  description = "${each.key} security group managed by Terraform"
  vpc_id      = var.vpc_id
  tags        = { Name = upper(each.value) }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  for_each          = aws_security_group.this
  security_group_id = each.value.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.this["alb"].id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Public HTTP redirect"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.this["alb"].id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Public HTTPS"
}

resource "aws_vpc_security_group_ingress_rule" "nginx_http" {
  security_group_id            = aws_security_group.this["nginx"].id
  referenced_security_group_id = aws_security_group.this["alb"].id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "HTTP from ALB"
}

resource "aws_vpc_security_group_ingress_rule" "tomcat_http" {
  security_group_id            = aws_security_group.this["tomcat"].id
  referenced_security_group_id = aws_security_group.this["nginx"].id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "Tomcat from Nginx"
}

resource "aws_vpc_security_group_ingress_rule" "database_mysql" {
  security_group_id            = aws_security_group.this["database"].id
  referenced_security_group_id = aws_security_group.this["tomcat"].id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "MySQL from Tomcat"
}

resource "aws_vpc_security_group_ingress_rule" "peer_icmp" {
  for_each = {
    for pair in setproduct(["management", "nginx", "tomcat"], var.peer_cidr_blocks) :
    "${pair[0]}-${replace(pair[1], "/", "-")}" => {
      group = pair[0]
      cidr  = pair[1]
    }
  }

  security_group_id = aws_security_group.this[each.value.group].id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  description       = "ICMP from a connected training network"
}

output "management_security_group_id" { value = aws_security_group.this["management"].id }
output "alb_security_group_id" { value = aws_security_group.this["alb"].id }
output "nginx_security_group_id" { value = aws_security_group.this["nginx"].id }
output "tomcat_security_group_id" { value = aws_security_group.this["tomcat"].id }
output "database_security_group_id" { value = aws_security_group.this["database"].id }
output "managed_instance_security_group_ids" {
  value = {
    management = aws_security_group.this["management"].id
    nginx      = aws_security_group.this["nginx"].id
    tomcat     = aws_security_group.this["tomcat"].id
  }
}
