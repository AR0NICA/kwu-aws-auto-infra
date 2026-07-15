output "website_url" { value = "https://${var.domain_name}" }
output "www_website_url" { value = "https://www.${var.domain_name}" }
output "application_health_url" { value = "https://${var.domain_name}/app/health.jsp" }
output "alb_dns_name" { value = module.load_balancer.dns_name }
output "alb_target_group_arn" { value = module.load_balancer.target_group_arn }
output "management_instance_id" { value = module.compute.management_instance_id }
output "management_private_ip" { value = module.compute.management_private_ip }
output "rds_endpoint" { value = module.database.endpoint }
output "rds_rotation_lambda_name" { value = module.rds_rotation.function_name }
output "dev_nginx_public_ip" { value = module.dev_environment.nginx_public_ip }
output "dev_private_ips" { value = module.dev_environment.private_ips }
output "vpc_peering_connection_id" { value = module.peering.peering_connection_id }
output "vpn_connection_id" { value = module.vpn.vpn_connection_id }
output "vpn_test_ip" { value = module.dev_environment.vpn_test_private_ip }
output "vpn_test_instance_id" { value = module.dev_environment.vpn_test_instance_id }
output "strongswan_instance_id" { value = module.vpn.strongswan_instance_id }
output "strongswan_network_interface_id" { value = module.vpn.strongswan_network_interface_id }
output "strongswan_public_ip" { value = module.vpn.strongswan_public_ip }
output "virtual_private_gateway_id" { value = module.vpn.virtual_private_gateway_id }
output "waf_web_acl_arn" { value = module.waf.web_acl_arn }
output "cloudtrail_arn" { value = module.audit.cloudtrail_arn }
output "guardduty_detector_ids" {
  value = {
    prd = module.prd_threat_detection.guardduty_detector_id
    dev = module.dev_threat_detection.guardduty_detector_id
  }
}
output "securityhub_arns" {
  value = {
    prd = module.prd_threat_detection.securityhub_arn
    dev = module.dev_threat_detection.securityhub_arn
  }
}
