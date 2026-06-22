variable "name_prefix" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "public_subnets" {
  type = map(object({ cidr = string, availability_zone = string }))
}

variable "tomcat_subnets" {
  type = map(object({ cidr = string, availability_zone = string, private_ip = string }))
}

variable "database_subnets" {
  type = map(object({ cidr = string, availability_zone = string }))
}
