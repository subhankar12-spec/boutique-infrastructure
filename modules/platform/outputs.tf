output "cluster_name" { value = aws_eks_cluster.this.name }
output "cluster_endpoint" { value = aws_eks_cluster.this.endpoint }
output "secret_names" { value = { for k, v in aws_secretsmanager_secret.application : k => v.name } }
output "external_secrets_role_arns" { value = { for k, v in aws_iam_role.external_secrets : k => v.arn } }
output "rds_admin_secret_arns" { value = { for k, v in aws_db_instance.orders : k => v.master_user_secret[0].secret_arn } }
output "database_endpoints" { value = { for k, v in aws_db_instance.orders : k => v.address } }
