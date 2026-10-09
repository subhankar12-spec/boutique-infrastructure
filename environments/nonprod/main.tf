terraform {
  required_version = ">= 1.11.0, < 2.0"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.100" }
    random = { source = "hashicorp/random", version = "~> 3.7" }
    tls    = { source = "hashicorp/tls", version = "~> 4.1" }
  }
  backend "s3" { use_lockfile = true }
}
provider "aws" { region = var.region }
module "platform" {
  source                                 = "../../modules/platform"
  name                                   = "boutique-nonprod"
  region                                 = var.region
  vpc_cidr                               = "10.10.0.0/16"
  environments                           = ["dev", "staging"]
  production                             = false
  kubernetes_version                     = var.kubernetes_version
  admin_role_arn                         = var.admin_role_arn
  node_instance_type                     = "t3.medium"
  node_count                             = 2
  budget_email                           = var.budget_email
  monthly_budget_usd                     = var.monthly_budget_usd
  enable_monitoring_database             = var.enable_monitoring_database
  monitoring_postgresql_ca_file          = var.monitoring_postgresql_ca_file
  alarm_email_addresses                  = var.alarm_email_addresses
  enable_cloudwatch_observability        = var.enable_cloudwatch_observability
  cloudwatch_observability_addon_version = var.cloudwatch_observability_addon_version
  tags                                   = { Owner = var.owner }
}
output "platform" { value = module.platform }
