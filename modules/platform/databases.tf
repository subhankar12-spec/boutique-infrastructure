# Per-environment PostgreSQL and Redis data services.

resource "aws_db_instance" "orders" {
  for_each                        = var.environments
  identifier                      = "${var.name}-${each.key}-orders"
  engine                          = "postgres"
  engine_version                  = "16"
  instance_class                  = var.production ? "db.t4g.medium" : "db.t4g.micro"
  allocated_storage               = 20
  max_allocated_storage           = 100
  storage_type                    = "gp3"
  storage_encrypted               = true
  kms_key_id                      = aws_kms_key.platform.arn
  db_name                         = "boutique"
  username                        = "boutique_admin"
  manage_master_user_password     = true
  master_user_secret_kms_key_id   = aws_kms_key.platform.arn
  multi_az                        = var.production
  db_subnet_group_name            = module.vpc.database_subnet_group_name
  vpc_security_group_ids          = [aws_security_group.data.id]
  publicly_accessible             = false
  backup_retention_period         = var.production ? 14 : 3
  backup_window                   = "03:00-04:00"
  maintenance_window              = "sun:04:00-sun:05:00"
  auto_minor_version_upgrade      = true
  deletion_protection             = true
  skip_final_snapshot             = false
  final_snapshot_identifier       = "${var.name}-${each.key}-orders-final"
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  depends_on                      = [aws_cloudwatch_log_group.orders]
  tags                            = merge(local.tags, { Environment = each.key })
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.name}-redis"
  subnet_ids = module.vpc.database_subnets
}

resource "aws_elasticache_replication_group" "redis" {
  for_each                   = var.environments
  replication_group_id       = "${var.name}-${each.key}-cart"
  description                = "${each.key} isolated carts"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = var.production ? "cache.t4g.small" : "cache.t4g.micro"
  num_cache_clusters         = var.production ? 2 : 1
  automatic_failover_enabled = var.production
  multi_az_enabled           = var.production
  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.data.id]
  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.platform.arn
  transit_encryption_enabled = true
  auth_token                 = random_password.redis[each.key].result
  dynamic "log_delivery_configuration" {
    for_each = toset(["slow-log", "engine-log"])
    content {
      destination      = aws_cloudwatch_log_group.redis["${each.key}/${log_delivery_configuration.value}"].name
      destination_type = "cloudwatch-logs"
      log_format       = "json"
      log_type         = log_delivery_configuration.value
    }
  }
  snapshot_retention_limit = var.production ? 7 : 1
  tags                     = merge(local.tags, { Environment = each.key })
}
