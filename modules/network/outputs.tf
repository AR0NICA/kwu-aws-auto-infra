output "vpc_id" {
  value = aws_vpc.this.id
}

output "bastion_subnet_id" {
  value = aws_subnet.public["bastion"].id
}

output "nginx_subnet_ids" {
  value = {
    nginx_2a = aws_subnet.public["nginx_2a"].id
    nginx_2c = aws_subnet.public["nginx_2c"].id
  }
}

output "tomcat_subnet_ids" {
  value = { for key, subnet in aws_subnet.tomcat : key => subnet.id }
}

output "database_subnet_ids" {
  value = { for key, subnet in aws_subnet.database : key => subnet.id }
}
