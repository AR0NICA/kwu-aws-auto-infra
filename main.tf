locals {
  project_name = "kwu-prd-vpc"
  common_tags = {
    Project     = local.project_name
    ManagedBy   = "Terraform"
    Environment = "production"
  }

  public_subnets = {
    nginx_2a = { cidr = "10.250.1.0/24", availability_zone = "ap-northeast-2a" }
    nginx_2c = { cidr = "10.250.11.0/24", availability_zone = "ap-northeast-2c" }
    bastion  = { cidr = "10.250.4.0/24", availability_zone = "ap-northeast-2a" }
  }
  tomcat_subnets = {
    tomcat_2a = { cidr = "10.250.2.0/24", availability_zone = "ap-northeast-2a", private_ip = "10.250.2.240" }
    tomcat_2c = { cidr = "10.250.12.0/24", availability_zone = "ap-northeast-2c", private_ip = "10.250.12.240" }
  }
  database_subnets = {
    db_2a = { cidr = "10.250.3.0/24", availability_zone = "ap-northeast-2a" }
    db_2c = { cidr = "10.250.13.0/24", availability_zone = "ap-northeast-2c" }
  }
}

module "network" {
  source = "./modules/network"

  name_prefix      = local.project_name
  vpc_cidr         = var.vpc_cidr
  public_subnets   = local.public_subnets
  tomcat_subnets   = local.tomcat_subnets
  database_subnets = local.database_subnets
}

module "security" {
  source = "./modules/security"

  name_prefix = local.project_name
  vpc_id      = module.network.vpc_id
  admin_cidr  = var.admin_cidr
}

module "database" {
  source = "./modules/database"

  name_prefix       = local.project_name
  database_name     = var.database_name
  master_username   = var.db_master_username
  master_password   = var.db_master_password
  subnet_ids        = values(module.network.database_subnet_ids)
  security_group_id = module.security.database_security_group_id
}

module "compute" {
  source = "./modules/compute"

  name_prefix               = local.project_name
  ami_id                    = var.ami_id
  instance_type             = var.instance_type
  key_name                  = var.key_name
  bastion_subnet_id         = module.network.bastion_subnet_id
  nginx_subnet_ids          = module.network.nginx_subnet_ids
  tomcat_subnet_ids         = module.network.tomcat_subnet_ids
  bastion_security_group_id = module.security.bastion_security_group_id
  nginx_security_group_id   = module.security.nginx_security_group_id
  tomcat_security_group_id  = module.security.tomcat_security_group_id
  database_endpoint         = module.database.endpoint
  tomcat_private_ips        = { for key, value in local.tomcat_subnets : key => value.private_ip }
}

module "load_balancer" {
  source = "./modules/load_balancer"

  name_prefix       = local.project_name
  vpc_id            = module.network.vpc_id
  subnet_ids        = values(module.network.nginx_subnet_ids)
  security_group_id = module.security.alb_security_group_id
  nginx_instances   = module.compute.nginx_instances
}

module "dns" {
  source = "./modules/dns"

  domain_name        = var.domain_name
  alb_dns_name       = module.load_balancer.dns_name
  alb_hosted_zone_id = module.load_balancer.hosted_zone_id
}
