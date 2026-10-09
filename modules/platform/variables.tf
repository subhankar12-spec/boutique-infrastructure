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
