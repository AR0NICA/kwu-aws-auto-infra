resource "aws_security_group" "bastion" {
  name        = "${var.name_prefix}-bastion-sg"
  description = "Bastion SSH access"
  vpc_id      = var.vpc_id

  tags = { Name = "${upper(var.name_prefix)}-BASTION-SG" }
}

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Public ALB HTTP access"
  vpc_id      = var.vpc_id

  tags = { Name = "${upper(var.name_prefix)}-ALB-SG" }
}

resource "aws_security_group" "nginx" {
  name        = "${var.name_prefix}-nginx-sg"
  description = "Nginx access from ALB and Bastion"
  vpc_id      = var.vpc_id

  tags = { Name = "${upper(var.name_prefix)}-NGINX-SG" }
}

resource "aws_security_group" "tomcat" {
  name        = "${var.name_prefix}-tomcat-sg"
  description = "Tomcat access from Nginx and Bastion"
  vpc_id      = var.vpc_id

  tags = { Name = "${upper(var.name_prefix)}-TOMCAT-SG" }
}

resource "aws_security_group" "database" {
  name        = "${var.name_prefix}-database-sg"
  description = "MySQL access from Tomcat"
  vpc_id      = var.vpc_id

  tags = { Name = "${upper(var.name_prefix)}-DATABASE-SG" }
}

resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH from administrator CIDR"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Public HTTP"
}

resource "aws_vpc_security_group_ingress_rule" "nginx_http" {
  security_group_id            = aws_security_group.nginx.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "HTTP from ALB"
}

resource "aws_vpc_security_group_ingress_rule" "nginx_ssh" {
  security_group_id            = aws_security_group.nginx.id
  referenced_security_group_id = aws_security_group.bastion.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  description                  = "SSH from Bastion"
}

resource "aws_vpc_security_group_ingress_rule" "tomcat_http" {
  security_group_id            = aws_security_group.tomcat.id
  referenced_security_group_id = aws_security_group.nginx.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "Tomcat from Nginx"
}

resource "aws_vpc_security_group_ingress_rule" "tomcat_ssh" {
  security_group_id            = aws_security_group.tomcat.id
  referenced_security_group_id = aws_security_group.bastion.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  description                  = "SSH from Bastion"
}

resource "aws_vpc_security_group_ingress_rule" "database_mysql" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.tomcat.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "MySQL from Tomcat"
}
