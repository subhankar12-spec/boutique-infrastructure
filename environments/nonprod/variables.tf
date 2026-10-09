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
  default = false
}
variable "monitoring_postgresql_ca_file" {
  type     = string
  default  = null
  nullable = true
}
