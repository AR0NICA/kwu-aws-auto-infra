output "website_url" { value = "https://${var.domain_name}" }
output "www_website_url" { value = "https://www.${var.domain_name}" }
output "application_health_url" { value = "https://${var.domain_name}/app/health.jsp" }
output "alb_dns_name" { value = module.load_balancer.dns_name }
output "alb_target_group_arn" { value = module.load_balancer.target_group_arn }
output "bastion_public_ip" { value = module.compute.bastion_public_ip }
output "rds_endpoint" { value = module.database.endpoint }
