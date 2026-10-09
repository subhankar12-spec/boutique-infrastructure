# Application credentials and their Secrets Manager delivery.

resource "random_password" "redis" {
  for_each = var.environments
  length   = 40
  special  = false
}

resource "random_password" "session" {
  for_each = var.environments
  length   = 64
  special  = false
}

resource "random_password" "database" {
  for_each = var.environments
  length   = 40
  special  = false
}

resource "aws_secretsmanager_secret" "application" {
  for_each                = var.environments
  name                    = "${var.name}/${each.key}/application"
  kms_key_id              = aws_kms_key.platform.arn
  recovery_window_in_days = 30
  tags                    = merge(local.tags, { Environment = each.key })
}

resource "aws_secretsmanager_secret_version" "application" {
  for_each  = var.environments
  secret_id = aws_secretsmanager_secret.application[each.key].id
  secret_string = jsonencode({
    session_secret    = random_password.session[each.key].result,
    redis_url         = "rediss://:${random_password.redis[each.key].result}@${aws_elasticache_replication_group.redis[each.key].primary_endpoint_address}:6379/0",
    database_url      = "jdbc:postgresql://${aws_db_instance.orders[each.key].address}:5432/boutique?sslmode=verify-full&sslrootcert=/app/certs/global-bundle.pem",
    database_username = "boutique",
    database_password = random_password.database[each.key].result
  })
}
