output "vpn_connection_id" {
  value = aws_vpn_connection.this.id
}

output "virtual_private_gateway_id" {
  value = aws_vpn_gateway.this.id
}

output "customer_gateway_id" {
  value = aws_customer_gateway.this.id
}

output "strongswan_instance_id" {
  value = aws_instance.strongswan.id
}

output "strongswan_network_interface_id" {
  value = aws_instance.strongswan.primary_network_interface_id
}

output "strongswan_security_group_id" {
  value = aws_security_group.strongswan.id
}

output "strongswan_public_ip" {
  value = aws_eip.strongswan.public_ip
}

output "strongswan_private_ip" {
  value = aws_instance.strongswan.private_ip
}

output "tunnel_outside_ips" {
  value = {
    tunnel1 = aws_vpn_connection.this.tunnel1_address
    tunnel2 = aws_vpn_connection.this.tunnel2_address
  }
}

output "test_networks" {
  value = {
    prd = var.prd_test_cidr
    dev = var.dev_test_cidr
  }
}

output "tunnel_log_group_name" {
  value = aws_cloudwatch_log_group.vpn.name
}
