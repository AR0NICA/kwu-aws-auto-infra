variable "aws_region" { type = string }
variable "dev_region" {
  type    = string
  default = "us-east-1"
}
variable "domain_name" { type = string }
variable "key_name" { type = string }
variable "dev_key_name" { type = string }
variable "admin_cidr" { type = string }
