output "bastion_security_group_id" {
  value = aws_security_group.bastion.id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "nginx_security_group_id" {
  value = aws_security_group.nginx.id
}

output "tomcat_security_group_id" {
  value = aws_security_group.tomcat.id
}

output "database_security_group_id" {
  value = aws_security_group.database.id
}
