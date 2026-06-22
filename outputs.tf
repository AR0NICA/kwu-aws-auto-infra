output "bastion_public_ip" {
  description = "Public IP address for SSH access to the Bastion host."
  value       = module.compute.bastion_public_ip
}

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer."
  value       = module.load_balancer.dns_name
}

output "website_url" {
  description = "Route 53 website URL."
  value       = "http://${var.domain_name}"
}

output "tomcat_application_url" {
  description = "Tomcat status dashboard exposed through Nginx."
  value       = "http://${var.domain_name}/app/"
}

output "rds_endpoint" {
  description = "Private RDS MySQL endpoint."
  value       = module.database.endpoint
}
