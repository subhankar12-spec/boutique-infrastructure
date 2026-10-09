variable "region" {
  type    = string
  default = "ap-south-1"
}
variable "kubernetes_version" {
  type    = string
  default = "1.34"
}
variable "admin_role_arn" { type = string }
variable "budget_email" { type = string }
variable "monthly_budget_usd" { type = number }
variable "owner" { type = string }
variable "enable_monitoring_database" {
  type    = bool
  default = true
}
variable "monitoring_postgresql_ca_file" {
  type     = string
  default  = null
  nullable = true
}

variable "alarm_email_addresses" {
  description = "Recipients must confirm SNS subscriptions. Empty leaves a topic available for operator integration."
  type        = set(string)
  default     = []
}
variable "enable_cloudwatch_observability" {
  description = "Enable paid Container Insights and container logs after reviewing cost/version."
  type        = bool
  default     = false
}
variable "cloudwatch_observability_addon_version" {
  description = "Explicit version returned by AWS describe-addon-versions for the selected EKS version."
  type        = string
  default     = ""
}
