variable "name_prefix" {
  description = "Prefix used for VPC Flow Logs resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID whose network interfaces are recorded."
  type        = string
}

variable "traffic_type" {
  description = "Traffic disposition to record."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.traffic_type)
    error_message = "traffic_type must be ACCEPT, REJECT, or ALL."
  }
}

variable "max_aggregation_interval" {
  description = "Maximum Flow Logs aggregation window in seconds."
  type        = number
  default     = 60

  validation {
    condition     = contains([60, 600], var.max_aggregation_interval)
    error_message = "max_aggregation_interval must be 60 or 600 seconds."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for VPC Flow Logs."
  type        = number
  default     = 30

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545,
      731, 1096, 1827, 2192, 2557, 2922, 3288, 3653
    ], var.log_retention_days)
    error_message = "log_retention_days must be a retention period supported by CloudWatch Logs."
  }
}

variable "tags" {
  description = "Additional tags for resources that support tagging."
  type        = map(string)
  default     = {}
}
