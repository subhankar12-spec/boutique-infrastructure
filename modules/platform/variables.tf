variable "name" { type = string }
variable "region" { type = string }
variable "vpc_cidr" { type = string }
variable "environments" { type = set(string) }
variable "production" { type = bool }
variable "kubernetes_version" { type = string }
variable "admin_role_arn" { type = string }
variable "node_instance_type" { type = string }
variable "node_count" { type = number }
variable "tags" { type = map(string) }
variable "budget_email" { type = string }
variable "monthly_budget_usd" { type = number }
variable "enable_monitoring_database" {
  description = "Provision a dedicated RDS incident queue and scoped monitoring secret roles."
  type        = bool
  default     = false
}
variable "monitoring_postgresql_ca_file" {
  description = "Absolute path to a reviewed official RDS CA PEM bundle; required when the managed queue is enabled."
  type        = string
  default     = null
  nullable    = true
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
