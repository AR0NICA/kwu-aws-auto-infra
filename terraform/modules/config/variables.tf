variable "name_prefix" {
  description = "Prefix used for regional AWS Config resources."
  type        = string
}

variable "audit_bucket_name" {
  description = "Name of the shared audit S3 bucket."
  type        = string
}

variable "audit_bucket_arn" {
  description = "ARN of the shared audit S3 bucket."
  type        = string
}

variable "role_arn" {
  description = "IAM role assumed by this regional AWS Config recorder."
  type        = string
}

variable "s3_key_prefix" {
  description = "Regional prefix authorized by the shared audit bucket policy."
  type        = string
}

variable "include_global_resource_types" {
  description = "Record legacy global IAM resource types in this Region. Enable only in the home Region."
  type        = bool
  default     = false
}

variable "recording_frequency" {
  description = "Default AWS Config recording frequency."
  type        = string
  default     = "CONTINUOUS"

  validation {
    condition     = contains(["CONTINUOUS", "DAILY"], var.recording_frequency)
    error_message = "recording_frequency must be CONTINUOUS or DAILY."
  }
}

variable "snapshot_delivery_frequency" {
  description = "Frequency for configuration snapshot delivery to S3."
  type        = string
  default     = "TwentyFour_Hours"

  validation {
    condition = contains([
      "One_Hour", "Three_Hours", "Six_Hours", "Twelve_Hours", "TwentyFour_Hours"
    ], var.snapshot_delivery_frequency)
    error_message = "snapshot_delivery_frequency must be supported by AWS Config."
  }
}

variable "managed_rules" {
  description = "Static-key map of regional AWS managed Config rules."
  type = map(object({
    source_identifier           = string
    description                 = optional(string)
    input_parameters            = optional(map(string), {})
    maximum_execution_frequency = optional(string)
    resource_types              = optional(list(string), [])
  }))
  default = {}
}

variable "tags" {
  description = "Additional tags for Config rules."
  type        = map(string)
  default     = {}
}
