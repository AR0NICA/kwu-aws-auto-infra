variable "name_prefix" {
  description = "Prefix used for VPN resource names."
  type        = string
}

variable "prd_region" {
  description = "AWS Region that owns the virtual private gateway and VPN secret."
  type        = string
}

variable "prd_vpc_id" {
  description = "Production VPC ID attached to the AWS virtual private gateway."
  type        = string
}

variable "prd_test_cidr" {
  description = "Dedicated production-side CIDR whose traffic must use the VPN."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.prd_test_cidr))
    error_message = "prd_test_cidr must be a valid IPv4 CIDR."
  }
}

variable "prd_vpn_route_table_id" {
  description = "Route table associated with the production VPN test subnet."
  type        = string
}

variable "dev_vpc_id" {
  description = "DEV/on-premises simulation VPC ID."
  type        = string
}

variable "dev_public_subnet_id" {
  description = "Public DEV subnet in which the StrongSwan customer gateway is launched."
  type        = string
}

variable "dev_test_cidr" {
  description = "Dedicated DEV/on-premises-side CIDR whose traffic must use the VPN."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.dev_test_cidr))
    error_message = "dev_test_cidr must be a valid IPv4 CIDR."
  }
}

variable "dev_vpn_route_table_id" {
  description = "Route table associated with the DEV VPN test subnet."
  type        = string
}

variable "session_log_group_arn" {
  description = "ARN of the DEV CloudWatch log group used for Session Manager streaming."
  type        = string
}

variable "strongswan_private_ip" {
  description = "Optional fixed private IPv4 address for the StrongSwan instance."
  type        = string
  default     = null
  nullable    = true
}

variable "strongswan_instance_type" {
  description = "EC2 instance type for the StrongSwan customer gateway."
  type        = string
  default     = "t3.micro"
}

variable "tunnel1_inside_cidr" {
  description = "Link-local /30 used inside VPN tunnel 1."
  type        = string
  default     = "169.254.100.0/30"
}

variable "tunnel2_inside_cidr" {
  description = "Link-local /30 used inside VPN tunnel 2."
  type        = string
  default     = "169.254.101.0/30"
}

variable "log_retention_days" {
  description = "Retention period for AWS Site-to-Site VPN tunnel logs."
  type        = number
  default     = 30
}

variable "alarm_actions" {
  description = "Optional SNS topic ARNs invoked by per-tunnel down alarms."
  type        = list(string)
  default     = []
}
