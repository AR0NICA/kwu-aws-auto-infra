variable "name_prefix" {
  description = "Lowercase prefix used for audit resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.name_prefix))
    error_message = "name_prefix must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "bucket_name" {
  description = "Optional globally unique audit bucket name."
  type        = string
  default     = null
  nullable    = true
}

variable "trail_name" {
  description = "Optional CloudTrail name."
  type        = string
  default     = null
  nullable    = true
}

variable "config_regions" {
  description = "Regions whose AWS Config delivery channels may write to the audit bucket."
  type        = set(string)

  validation {
    condition     = length(var.config_regions) > 0
    error_message = "config_regions must contain at least one AWS Region."
  }
}

variable "force_destroy" {
  description = "Allow classroom teardown to remove non-empty audit storage."
  type        = bool
  default     = true
}

variable "retention_days" {
  description = "Number of days to retain current and noncurrent audit objects."
  type        = number
  default     = 90

  validation {
    condition     = var.retention_days >= 1
    error_message = "retention_days must be at least one day."
  }
}

variable "cloudtrail_prefix" {
  description = "S3 key prefix for CloudTrail log delivery."
  type        = string
  default     = "cloudtrail"
}

variable "config_prefix" {
  description = "Base S3 key prefix for regional AWS Config delivery."
  type        = string
  default     = "config"
}

variable "tags" {
  description = "Additional tags for resources that support tagging."
  type        = map(string)
  default     = {}
}
