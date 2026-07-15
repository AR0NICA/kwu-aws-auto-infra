variable "name_prefix" {
  description = "Prefix used for WAF resources."
  type        = string
}

variable "alb_arn" {
  description = "ARN of the regional Application Load Balancer to protect."
  type        = string
}

variable "count_mode" {
  description = "When true, AWS managed rule matches are counted instead of blocked."
  type        = bool
  default     = false
}

variable "enable_logging" {
  description = "Whether to retain blocked and counted WAF requests in CloudWatch Logs."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for WAF request logs."
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
