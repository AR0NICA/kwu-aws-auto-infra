variable "name_prefix" {
  description = "Prefix used for regional threat-detection resources."
  type        = string
}

variable "guardduty_finding_publishing_frequency" {
  description = "Frequency for publishing subsequent GuardDuty finding occurrences."
  type        = string
  default     = "FIFTEEN_MINUTES"

  validation {
    condition = contains([
      "FIFTEEN_MINUTES", "ONE_HOUR", "SIX_HOURS"
    ], var.guardduty_finding_publishing_frequency)
    error_message = "GuardDuty publishing frequency must be FIFTEEN_MINUTES, ONE_HOUR, or SIX_HOURS."
  }
}

variable "guardduty_feature_statuses" {
  description = "Optional GuardDuty protection-plan statuses keyed by detector feature name."
  type        = map(string)
  default = {
    S3_DATA_EVENTS         = "DISABLED"
    EKS_AUDIT_LOGS         = "DISABLED"
    EBS_MALWARE_PROTECTION = "DISABLED"
    RDS_LOGIN_EVENTS       = "DISABLED"
    LAMBDA_NETWORK_LOGS    = "DISABLED"
    EKS_RUNTIME_MONITORING = "DISABLED"
  }

  validation {
    condition = alltrue([
      for name, status in var.guardduty_feature_statuses :
      contains([
        "S3_DATA_EVENTS",
        "EKS_AUDIT_LOGS",
        "EBS_MALWARE_PROTECTION",
        "RDS_LOGIN_EVENTS",
        "EKS_RUNTIME_MONITORING",
        "LAMBDA_NETWORK_LOGS",
        "RUNTIME_MONITORING"
      ], name) && contains(["ENABLED", "DISABLED"], status)
      ]) && !(
      contains(keys(var.guardduty_feature_statuses), "EKS_RUNTIME_MONITORING") &&
      contains(keys(var.guardduty_feature_statuses), "RUNTIME_MONITORING")
    )
    error_message = "GuardDuty feature names/statuses must be provider-supported, and EKS_RUNTIME_MONITORING cannot be combined with RUNTIME_MONITORING."
  }
}

variable "enable_fsbp_standard" {
  description = "Enable AWS Foundational Security Best Practices v1.0.0."
  type        = bool
  default     = true
}

variable "enable_cis_1_2_standard" {
  description = "Enable CIS AWS Foundations Benchmark v1.2.0 in addition to FSBP."
  type        = bool
  default     = false
}

variable "linked_regions" {
  description = "Regions whose Security Hub findings aggregate into this module's Region. Leave empty outside the home Region."
  type        = set(string)
  default     = []
}

variable "tags" {
  description = "Additional tags for GuardDuty resources."
  type        = map(string)
  default     = {}
}
