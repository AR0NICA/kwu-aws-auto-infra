variable "name_prefix" {
  type = string
}

variable "ami_id" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "key_name" {
  type = string
}

variable "bastion_subnet_id" {
  type = string
}

variable "nginx_subnet_ids" {
  type = map(string)
}

variable "tomcat_subnet_ids" {
  type = map(string)
}

variable "bastion_security_group_id" {
  type = string
}

variable "nginx_security_group_id" {
  type = string
}

variable "tomcat_security_group_id" {
  type = string
}

variable "database_endpoint" {
  type = string
}

variable "tomcat_private_ips" {
  type = map(string)
}
