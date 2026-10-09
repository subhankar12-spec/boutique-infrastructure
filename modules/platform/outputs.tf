output "cluster_name" { value = aws_eks_cluster.this.name }
output "cluster_endpoint" { value = aws_eks_cluster.this.endpoint }
output "secret_names" { value = { for k, v in aws_secretsmanager_secret.application : k => v.name } }
output "external_secrets_role_arns" { value = { for k, v in aws_iam_role.external_secrets : k => v.arn } }
output "rds_admin_secret_arns" { value = { for k, v in aws_db_instance.orders : k => v.master_user_secret[0].secret_arn } }
output "database_endpoints" { value = { for k, v in aws_db_instance.orders : k => v.address } }
output "monitoring" {
  description = "Nonsecret connection/bootstrap metadata. Null when the optional managed queue is disabled."
  value = var.enable_monitoring_database ? {
    database_endpoint           = aws_db_instance.monitoring[0].address
    database_name               = local.monitoring_database_name
    database_user               = local.monitoring_database_user
    database_subnet_cidrs       = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i + 4)]
    admin_secret_arn            = aws_db_instance.monitoring[0].master_user_secret[0].secret_arn
    queue_secret_name           = aws_secretsmanager_secret.monitoring_queue[0].name
    integrations_secret_name    = aws_secretsmanager_secret.monitoring_integrations[0].name
    external_secrets_role_arn   = aws_iam_role.monitoring_external_secrets[0].arn
    database_bootstrap_role_arn = aws_iam_role.monitoring_database_bootstrap[0].arn
  } : null
}
