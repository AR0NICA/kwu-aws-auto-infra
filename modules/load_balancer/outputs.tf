output "dns_name" {
  value = aws_lb.this.dns_name
}

output "hosted_zone_id" {
  value = aws_lb.this.zone_id
}
