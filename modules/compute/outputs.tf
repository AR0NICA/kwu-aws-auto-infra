output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}

output "nginx_instances" {
  value = { for key, instance in aws_instance.nginx : key => { id = instance.id } }
}
