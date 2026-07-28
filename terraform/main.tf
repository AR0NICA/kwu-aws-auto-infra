locals {
  project_name     = "kwu-prd-vpc"
  dev_project_name = "kwu-dev-vpc"
  prd_vpc_cidr     = "10.250.0.0/16"
  dev_vpc_cidr     = "10.230.0.0/16"
  vpn_test_cidr    = "10.231.240.0/24"
  vpn_test_ip      = "10.231.240.10"
  common_tags = {
    Project     = "aws-auto-infra"
    ManagedBy   = "Terraform"
    Environment = "training"
    Domain      = var.domain_name
  }

  public_subnets = {
    nginx_2a = { cidr = "10.250.1.0/24", availability_zone = "ap-northeast-2a" }
    nginx_2c = { cidr = "10.250.11.0/24", availability_zone = "ap-northeast-2c" }
  }
  tomcat_subnets = {
    tomcat_2a = { cidr = "10.250.2.0/24", availability_zone = "ap-northeast-2a", private_ip = "10.250.2.240" }
    tomcat_2c = { cidr = "10.250.12.0/24", availability_zone = "ap-northeast-2c", private_ip = "10.250.12.240" }
  }
  database_subnets = {
    db_2a = { cidr = "10.250.3.0/24", availability_zone = "ap-northeast-2a" }
    db_2c = { cidr = "10.250.13.0/24", availability_zone = "ap-northeast-2c" }
  }
  prd_config_rules = {
    vpc_flow_logs_enabled = {
      source_identifier = "VPC_FLOW_LOGS_ENABLED"
      description       = "Checks that VPC Flow Logs record all traffic."
      input_parameters  = { trafficType = "ALL" }
    }
    alb_waf_enabled = {
      source_identifier = "ALB_WAF_ENABLED"
      description       = "Checks that each Application Load Balancer is protected by WAF."
    }
    wafv2_logging_enabled = {
      source_identifier = "WAFV2_LOGGING_ENABLED"
      description       = "Checks that WAFv2 request logging is enabled."
    }
    multi_region_cloudtrail_enabled = {
      source_identifier = "MULTI_REGION_CLOUD_TRAIL_ENABLED"
      description       = "Checks that a multi-Region CloudTrail trail is active."
    }
    cloudtrail_log_file_validation_enabled = {
      source_identifier = "CLOUD_TRAIL_LOG_FILE_VALIDATION_ENABLED"
      description       = "Checks CloudTrail log file integrity validation."
    }
    ec2_instance_managed_by_ssm = {
      source_identifier = "EC2_INSTANCE_MANAGED_BY_SSM"
      description       = "Checks that EC2 instances are registered as SSM managed nodes."
    }
    rds_multi_az_support = {
      source_identifier = "RDS_MULTI_AZ_SUPPORT"
      description       = "Checks that RDS uses a Multi-AZ deployment."
    }
    rds_storage_encrypted = {
      source_identifier = "RDS_STORAGE_ENCRYPTED"
      description       = "Checks that RDS storage is encrypted."
    }
    secretsmanager_rotation_enabled = {
      source_identifier = "SECRETSMANAGER_ROTATION_ENABLED_CHECK"
      description       = "Checks that Secrets Manager rotation is enabled."
    }
    vpc_default_security_group_closed = {
      source_identifier = "VPC_DEFAULT_SECURITY_GROUP_CLOSED"
      description       = "Checks that default VPC security groups allow no traffic."
    }
  }
  dev_config_rules = {
    vpc_flow_logs_enabled = {
      source_identifier = "VPC_FLOW_LOGS_ENABLED"
      description       = "Checks that DEV VPC Flow Logs record all traffic."
      input_parameters  = { trafficType = "ALL" }
    }
    ec2_instance_managed_by_ssm = {
      source_identifier = "EC2_INSTANCE_MANAGED_BY_SSM"
      description       = "Checks that DEV EC2 instances are registered with SSM."
    }
    vpc_default_security_group_closed = {
      source_identifier = "VPC_DEFAULT_SECURITY_GROUP_CLOSED"
      description       = "Checks that the DEV default security group allows no traffic."
    }
  }
}

module "network" {
  source           = "./modules/network"
  name_prefix      = local.project_name
  vpc_cidr         = local.prd_vpc_cidr
  public_subnets   = local.public_subnets
  tomcat_subnets   = local.tomcat_subnets
  database_subnets = local.database_subnets
}

module "security" {
  source      = "./modules/security"
  name_prefix = local.project_name
  vpc_id      = module.network.vpc_id
  peer_cidr_blocks = [
    local.dev_vpc_cidr,
    local.vpn_test_cidr,
  ]
}

module "dns" {
  source      = "./modules/dns"
  domain_name = var.domain_name
}

module "database" {
  source            = "./modules/database"
  name_prefix       = local.project_name
  database_name     = "appdb"
  master_username   = "appadmin"
  subnet_ids        = values(module.network.database_subnet_ids)
  security_group_id = module.security.database_security_group_id
}

module "prd_session_manager" {
  source             = "./modules/session_manager"
  name_prefix        = local.project_name
  log_retention_days = var.security_log_retention_days
}

module "prd_endpoints" {
  source = "./modules/vpc_endpoints"

  name_prefix                = local.project_name
  vpc_id                     = module.network.vpc_id
  interface_subnet_ids       = module.network.endpoint_subnet_ids
  route_table_ids            = module.network.route_table_ids
  allowed_security_group_ids = module.security.managed_instance_security_group_ids
  enable_secretsmanager      = true
  enable_cloudwatch_logs     = true
}

module "compute" {
  source                       = "./modules/compute"
  name_prefix                  = local.project_name
  management_subnet_id         = module.network.management_subnet_id
  nginx_subnet_ids             = module.network.nginx_subnet_ids
  tomcat_subnet_ids            = module.network.tomcat_subnet_ids
  tomcat_private_ips           = { for key, value in local.tomcat_subnets : key => value.private_ip }
  management_security_group_id = module.security.management_security_group_id
  nginx_security_group_id      = module.security.nginx_security_group_id
  tomcat_security_group_id     = module.security.tomcat_security_group_id
  database_endpoint            = module.database.endpoint
  database_name                = "appdb"
  database_secret_arn          = module.database.master_secret_arn
  aws_region                   = var.aws_region
  session_log_group_arn        = module.prd_session_manager.log_group_arn

  depends_on = [module.prd_endpoints]
}

module "load_balancer" {
  source            = "./modules/load_balancer"
  name_prefix       = local.project_name
  vpc_id            = module.network.vpc_id
  subnet_ids        = values(module.network.nginx_subnet_ids)
  security_group_id = module.security.alb_security_group_id
  nginx_instances   = module.compute.nginx_instances
  certificate_arn   = module.dns.certificate_arn
}

module "waf" {
  source = "./modules/waf"

  name_prefix        = local.project_name
  alb_arn            = module.load_balancer.arn
  count_mode         = var.waf_count_mode
  enable_logging     = true
  log_retention_days = var.security_log_retention_days
}

module "rds_rotation" {
  source = "./modules/rotation"

  name_prefix            = local.project_name
  db_instance_identifier = module.database.identifier
  db_instance_arn        = module.database.arn
  database_secret_arn    = module.database.master_secret_arn
  schedule_expression    = var.rds_rotation_schedule
}

module "dev_session_manager" {
  source = "./modules/session_manager"
  providers = {
    aws = aws.use1
  }

  name_prefix        = local.dev_project_name
  log_retention_days = var.security_log_retention_days
}

module "dev_environment" {
  source = "./modules/dev_environment"
  providers = {
    aws = aws.use1
  }

  name_prefix           = local.dev_project_name
  vpc_cidr              = local.dev_vpc_cidr
  prd_cidr              = local.prd_vpc_cidr
  vpn_test_cidr         = local.vpn_test_cidr
  vpn_test_ip           = local.vpn_test_ip
  session_log_group_arn = module.dev_session_manager.log_group_arn
}

module "dev_endpoints" {
  source = "./modules/vpc_endpoints"
  providers = {
    aws = aws.use1
  }

  name_prefix          = local.dev_project_name
  vpc_id               = module.dev_environment.vpc_id
  interface_subnet_ids = module.dev_environment.endpoint_subnet_ids
  route_table_ids      = module.dev_environment.route_table_ids
  allowed_security_group_ids = merge(
    module.dev_environment.managed_instance_security_group_ids,
    { strongswan = module.vpn.strongswan_security_group_id },
  )
  enable_secretsmanager  = false
  enable_cloudwatch_logs = true
}

module "peering" {
  source = "./modules/peering"
  providers = {
    aws     = aws
    aws.dev = aws.use1
  }

  name_prefix = "kwu-prd-dev"
  prd_vpc_id  = module.network.vpc_id
  prd_cidr    = local.prd_vpc_cidr
  prd_route_table_ids = {
    public  = module.network.public_route_table_id
    private = module.network.private_route_table_id
  }
  dev_vpc_id = module.dev_environment.vpc_id
  dev_cidr   = local.dev_vpc_cidr
  dev_region = var.dev_region
  dev_route_table_ids = {
    public  = module.dev_environment.public_route_table_id
    private = module.dev_environment.private_route_table_id
  }
}

module "vpn" {
  source = "./modules/vpn"
  providers = {
    aws     = aws
    aws.dev = aws.use1
  }

  name_prefix = "kwu-prd-dev-vpn"
  prd_region  = var.aws_region

  prd_vpc_id             = module.network.vpc_id
  prd_test_cidr          = local.tomcat_subnets.tomcat_2a.cidr
  prd_vpn_route_table_id = module.network.private_route_table_id

  dev_vpc_id             = module.dev_environment.vpc_id
  dev_public_subnet_id   = module.dev_environment.public_subnet_id
  dev_test_cidr          = local.vpn_test_cidr
  dev_vpn_route_table_id = module.dev_environment.vpn_test_route_table_id

  strongswan_private_ip = "10.230.1.250"
  log_retention_days    = var.security_log_retention_days
  session_log_group_arn = module.dev_session_manager.log_group_arn

}

module "audit" {
  source = "./modules/audit"

  name_prefix    = local.project_name
  trail_name     = "kwu-prd-vpc-audit"
  config_regions = [var.aws_region, var.dev_region]
  retention_days = var.audit_retention_days
  force_destroy  = true
}

module "prd_flow_logs" {
  source = "./modules/vpc_flow_logs"

  name_prefix        = local.project_name
  vpc_id             = module.network.vpc_id
  traffic_type       = "ALL"
  log_retention_days = var.security_log_retention_days
}

module "dev_flow_logs" {
  source = "./modules/vpc_flow_logs"
  providers = {
    aws = aws.use1
  }

  name_prefix        = local.dev_project_name
  vpc_id             = module.dev_environment.vpc_id
  traffic_type       = "ALL"
  log_retention_days = var.security_log_retention_days
}

module "prd_config" {
  source = "./modules/config"

  name_prefix                   = "${local.project_name}-config"
  audit_bucket_name             = module.audit.bucket_name
  audit_bucket_arn              = module.audit.bucket_arn
  role_arn                      = module.audit.config_role_arn
  s3_key_prefix                 = module.audit.config_s3_prefixes[var.aws_region]
  include_global_resource_types = true
  managed_rules                 = local.prd_config_rules

  depends_on = [module.audit, module.prd_flow_logs, module.waf, module.rds_rotation]
}

module "dev_config" {
  source = "./modules/config"
  providers = {
    aws = aws.use1
  }

  name_prefix                   = "${local.dev_project_name}-config"
  audit_bucket_name             = module.audit.bucket_name
  audit_bucket_arn              = module.audit.bucket_arn
  role_arn                      = module.audit.config_role_arn
  s3_key_prefix                 = module.audit.config_s3_prefixes[var.dev_region]
  include_global_resource_types = false
  managed_rules                 = local.dev_config_rules

  depends_on = [module.audit, module.dev_flow_logs]
}

module "dev_threat_detection" {
  source = "./modules/threat_detection"
  providers = {
    aws = aws.use1
  }

  name_prefix = local.dev_project_name

  depends_on = [module.dev_config]
}

module "prd_threat_detection" {
  source = "./modules/threat_detection"

  name_prefix    = local.project_name
  linked_regions = [var.dev_region]

  depends_on = [module.prd_config, module.dev_threat_detection]
}

resource "aws_route53_record" "website" {
  for_each = toset([var.domain_name, "www.${var.domain_name}"])

  zone_id = module.dns.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = module.load_balancer.dns_name
    zone_id                = module.load_balancer.hosted_zone_id
    evaluate_target_health = true
  }
}
