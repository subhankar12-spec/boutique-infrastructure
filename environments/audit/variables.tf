variable "region" {
  type    = string
  default = "ap-south-1"
}
variable "owner" { type = string }
variable "name" {
  type    = string
  default = "boutique-account-audit"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,35}$", var.name))
    error_message = "Use a lowercase audit name between 3 and 36 characters."
  }
}
variable "s3_retention_days" {
  type    = number
  default = 365
  validation {
    condition     = var.s3_retention_days >= 180 && var.s3_retention_days == floor(var.s3_retention_days)
    error_message = "Audit retention must be an integer of at least 180 days."
  }
}
variable "cloudwatch_retention_days" {
  type    = number
  default = 90
  validation {
    condition     = contains([30, 60, 90, 120, 150, 180, 365], var.cloudwatch_retention_days)
    error_message = "Select a supported audit CloudWatch retention of at least 30 days."
  }
}
variable "alarm_email_addresses" {
  type    = set(string)
  default = []
}
variable "audited_s3_prefix_arns" {
  description = "Optional paid object-level events, e.g. state bucket/prefix ARN ending '/'. Keep the trail's own log bucket excluded."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for arn in var.audited_s3_prefix_arns : can(regex("^arn:aws:s3:::[a-z0-9.-]+/.*/?$", arn))])
    error_message = "Use explicit S3 bucket/prefix ARNs, e.g. arn:aws:s3:::YOUR-STATE-BUCKET/boutique/."
  }
}
