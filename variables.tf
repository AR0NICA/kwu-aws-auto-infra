variable "aws_region" {
  description = "AWS deployment region. This stack is designed for ap-northeast-2."
  type        = string
  default     = "ap-northeast-2"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.250.0.0/16"
}

variable "domain_name" {
  description = "Apex domain with an existing public Route 53 hosted zone."
  type        = string
}

variable "admin_cidr" {
  description = "CIDR allowed to SSH to the Bastion host."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.admin_cidr))
    error_message = "admin_cidr must be a valid CIDR block, for example 203.0.113.10/32."
  }
}

variable "ami_id" {
  description = "Ubuntu AMI used by Bastion, Nginx, and Tomcat instances."
  type        = string
  default     = "ami-0765f9741eedf9c7b"
}

variable "instance_type" {
  description = "EC2 instance type for all instances."
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Existing EC2 key pair name."
  type        = string
  default     = "kwuaws"
}

variable "database_name" {
  description = "Initial MySQL database name."
  type        = string
  default     = "appdb"
}

variable "db_master_username" {
  description = "RDS MySQL master user name."
  type        = string
  default     = "appadmin"
}

variable "db_master_password" {
  description = "RDS MySQL master password. Supply it through TF_VAR_db_master_password."
  type        = string
  sensitive   = true
}
