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

resource "aws_instance" "bastion" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = var.bastion_subnet_id
  private_ip                  = "10.250.4.240"
  vpc_security_group_ids      = [var.bastion_security_group_id]
  associate_public_ip_address = true

  tags = { Name = "${upper(var.name_prefix)}-BASTION-PUB-2A" }
}

resource "aws_instance" "nginx" {
  for_each = local.nginx_instances

  ami                         = var.ami_id
  instance_type               = var.instance_type
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

  tags = { Name = "${upper(var.name_prefix)}-NGINX-PUB-${each.value.zone}" }
}

resource "aws_instance" "tomcat" {
  for_each = local.tomcat_instances

  ami                         = var.ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = each.value.subnet_id
  private_ip                  = each.value.private_ip
  vpc_security_group_ids      = [var.tomcat_security_group_id]
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/tomcat-user-data.sh.tftpl", {
    zone              = each.value.zone
    database_endpoint = var.database_endpoint
  })

  tags = { Name = "${upper(var.name_prefix)}-TOMCAT-PRI-${each.value.zone}" }
}
