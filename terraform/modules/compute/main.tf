variable "name_prefix" { type = string }
variable "key_name" { type = string }
variable "bastion_subnet_id" { type = string }
variable "nginx_subnet_ids" { type = map(string) }
variable "tomcat_subnet_ids" { type = map(string) }
variable "tomcat_private_ips" { type = map(string) }
variable "bastion_security_group_id" { type = string }
variable "nginx_security_group_id" { type = string }
variable "tomcat_security_group_id" { type = string }
variable "database_endpoint" { type = string }
variable "database_name" { type = string }
variable "database_secret_arn" { type = string }
variable "aws_region" { type = string }

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  nginx_instances = {
    nginx_2a = { subnet_id = var.nginx_subnet_ids.nginx_2a, private_ip = "10.250.1.240", zone = "2A" }
    nginx_2c = { subnet_id = var.nginx_subnet_ids.nginx_2c, private_ip = "10.250.11.240", zone = "2C" }
  }
  tomcat_instances = {
    tomcat_2a = { subnet_id = var.tomcat_subnet_ids.tomcat_2a, private_ip = var.tomcat_private_ips.tomcat_2a, zone = "2A" }
    tomcat_2c = { subnet_id = var.tomcat_subnet_ids.tomcat_2c, private_ip = var.tomcat_private_ips.tomcat_2c, zone = "2C" }
  }
}

data "aws_iam_policy_document" "tomcat_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "read_rds_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.database_secret_arn]
  }
}

resource "aws_iam_role" "tomcat" {
  name               = "${var.name_prefix}-tomcat-secret-role"
  assume_role_policy = data.aws_iam_policy_document.tomcat_assume_role.json
}

resource "aws_iam_role_policy" "read_rds_secret" {
  name   = "read-rds-managed-secret"
  role   = aws_iam_role.tomcat.id
  policy = data.aws_iam_policy_document.read_rds_secret.json
}

resource "aws_iam_instance_profile" "tomcat" {
  name = "${var.name_prefix}-tomcat-profile"
  role = aws_iam_role.tomcat.name
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  key_name                    = var.key_name
  subnet_id                   = var.bastion_subnet_id
  private_ip                  = "10.250.4.240"
  vpc_security_group_ids      = [var.bastion_security_group_id]
  associate_public_ip_address = true
  tags                        = { Name = "KWU-PRD-VPC-BASTION-PUB-2A" }
}

resource "aws_instance" "nginx" {
  for_each                    = local.nginx_instances
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  key_name                    = var.key_name
  subnet_id                   = each.value.subnet_id
  private_ip                  = each.value.private_ip
  vpc_security_group_ids      = [var.nginx_security_group_id]
  associate_public_ip_address = true
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/nginx-user-data.sh.tftpl", {
    zone               = each.value.zone
    tomcat_private_ips = values(var.tomcat_private_ips)
  })
  tags = { Name = "KWU-PRD-VPC-NGINX-PUB-${each.value.zone}" }
}

resource "aws_instance" "tomcat" {
  for_each                    = local.tomcat_instances
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  key_name                    = var.key_name
  subnet_id                   = each.value.subnet_id
  private_ip                  = each.value.private_ip
  vpc_security_group_ids      = [var.tomcat_security_group_id]
  iam_instance_profile        = aws_iam_instance_profile.tomcat.name
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/tomcat-user-data.sh.tftpl", {
    zone                = each.value.zone
    database_endpoint   = var.database_endpoint
    database_name       = var.database_name
    database_secret_arn = var.database_secret_arn
    aws_region          = var.aws_region
  })
  tags = { Name = "KWU-PRD-VPC-TOMCAT-PRI-${each.value.zone}" }
}

output "bastion_public_ip" { value = aws_instance.bastion.public_ip }
output "nginx_instances" { value = { for key, instance in aws_instance.nginx : key => { id = instance.id } } }
