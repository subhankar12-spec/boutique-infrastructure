locals {
  monitoring_database_name = "boutique_incidents"
  monitoring_database_user = "boutique_incident"
  monitoring_identifier    = "${var.name}-incidents"
}

# This queue is independent of the orders database and has its own credentials,
# backup policy and authorization boundary. Disable it explicitly for cheaper
# nonproduction deployments; production enables it in the root by default.
resource "aws_security_group" "monitoring_database" {
  count       = var.enable_monitoring_database ? 1 : 0
  name_prefix = "${var.name}-incident-data-"
  description = "Incident queue: PostgreSQL from this cluster and bootstrap host"
  vpc_id      = module.vpc.vpc_id
  tags        = merge(local.tags, { Component = "incident-queue" })
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_cluster" {
  count                        = var.enable_monitoring_database ? 1 : 0
  security_group_id            = aws_security_group.monitoring_database[0].id
  referenced_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_operator" {
  count                        = var.enable_monitoring_database ? 1 : 0
  security_group_id            = aws_security_group.monitoring_database[0].id
  referenced_security_group_id = aws_security_group.operator.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_parameter_group" "monitoring" {
  count       = var.enable_monitoring_database ? 1 : 0
  name_prefix = "${var.name}-incidents-"
  family      = "postgres16"
  description = "Require TLS for the incident queue"
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }
  tags = local.tags
}

resource "random_id" "monitoring_snapshot" {
  count       = var.enable_monitoring_database ? 1 : 0
  byte_length = 4
  keepers     = { identifier = local.monitoring_identifier }
}

resource "aws_cloudwatch_log_group" "monitoring_database" {
  for_each          = var.enable_monitoring_database ? toset(["postgresql", "upgrade"]) : toset([])
  name              = "/aws/rds/instance/${local.monitoring_identifier}/${each.key}"
  retention_in_days = var.production ? 90 : 30
  tags              = merge(local.tags, { Component = "incident-queue" })
}

resource "aws_db_instance" "monitoring" {
  count                                 = var.enable_monitoring_database ? 1 : 0
  identifier                            = local.monitoring_identifier
  engine                                = "postgres"
  engine_version                        = "16"
  instance_class                        = var.production ? "db.t4g.medium" : "db.t4g.micro"
  allocated_storage                     = 20
  max_allocated_storage                 = 100
  storage_type                          = "gp3"
  storage_encrypted                     = true
  kms_key_id                            = aws_kms_key.platform.arn
  db_name                               = local.monitoring_database_name
  username                              = "boutique_incident_admin"
  manage_master_user_password           = true
  master_user_secret_kms_key_id         = aws_kms_key.platform.arn
  db_subnet_group_name                  = module.vpc.database_subnet_group_name
  vpc_security_group_ids                = [aws_security_group.monitoring_database[0].id]
  parameter_group_name                  = aws_db_parameter_group.monitoring[0].name
  publicly_accessible                   = false
  multi_az                              = var.production
  backup_retention_period               = var.production ? 35 : 7
  backup_window                         = "02:00-03:00"
  maintenance_window                    = "sun:03:00-sun:04:00"
  auto_minor_version_upgrade            = true
  copy_tags_to_snapshot                 = true
  deletion_protection                   = true
  skip_final_snapshot                   = false
  final_snapshot_identifier             = "${local.monitoring_identifier}-final-${random_id.monitoring_snapshot[0].hex}"
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
  performance_insights_enabled          = var.production
  performance_insights_kms_key_id       = var.production ? aws_kms_key.platform.arn : null
  performance_insights_retention_period = var.production ? 7 : null
  depends_on                            = [aws_cloudwatch_log_group.monitoring_database]
  tags                                  = merge(local.tags, { Component = "incident-queue" })
}

resource "random_password" "monitoring_database" {
  count   = var.enable_monitoring_database ? 1 : 0
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "monitoring_queue" {
  count                   = var.enable_monitoring_database ? 1 : 0
  name                    = "${var.name}/monitoring/incident-queue"
  kms_key_id              = aws_kms_key.platform.arn
  recovery_window_in_days = 30
  tags                    = merge(local.tags, { Component = "incident-queue" })
}

resource "aws_secretsmanager_secret_version" "monitoring_queue" {
  count     = var.enable_monitoring_database ? 1 : 0
  secret_id = aws_secretsmanager_secret.monitoring_queue[0].id
  secret_string = jsonencode({
    QUEUE_DATABASE_URL = "postgresql://${local.monitoring_database_user}:${random_password.monitoring_database[0].result}@${aws_db_instance.monitoring[0].address}:5432/${local.monitoring_database_name}?sslmode=verify-full&sslrootcert=/run/queue-ca/ca.crt",
    postgresql_ca      = var.monitoring_postgresql_ca_file == null ? "" : file(var.monitoring_postgresql_ca_file)
  })
  lifecycle {
    precondition {
      condition     = var.monitoring_postgresql_ca_file != null && can(regex("-----BEGIN CERTIFICATE-----", file(var.monitoring_postgresql_ca_file)))
      error_message = "Monitoring requires a reviewed RDS CA PEM file; run scripts/fetch-monitoring-rds-ca.sh and set monitoring_postgresql_ca_file."
    }
  }
}

# Only metadata is managed here. Populate this secret in Secrets Manager using
# the console or a secure stdin/file workflow. No Slack/ServiceNow credentials
# belong in Terraform variables, plans, logs or repository files.
resource "aws_secretsmanager_secret" "monitoring_integrations" {
  count                   = var.enable_monitoring_database ? 1 : 0
  name                    = "${var.name}/monitoring/integrations"
  kms_key_id              = aws_kms_key.platform.arn
  recovery_window_in_days = 30
  tags                    = merge(local.tags, { Component = "monitoring-integrations" })
}

resource "aws_iam_role" "monitoring_external_secrets" {
  count = var.enable_monitoring_database ? 1 : 0
  name  = "${var.name}-monitoring-external-secrets"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = {
        "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:monitoring:external-secrets-monitoring",
        "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
      } }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "monitoring_external_secrets" {
  count = var.enable_monitoring_database ? 1 : 0
  role  = aws_iam_role.monitoring_external_secrets[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], Resource = [aws_secretsmanager_secret.monitoring_queue[0].arn, aws_secretsmanager_secret.monitoring_integrations[0].arn] },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.platform.arn
        Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com" }, StringLike = {
          "kms:EncryptionContext:SecretARN" = [aws_secretsmanager_secret.monitoring_queue[0].arn, aws_secretsmanager_secret.monitoring_integrations[0].arn]
        } }
      }
    ]
  })
}

# An administrator assumes this short-lived bootstrap role from the private
# operator network. The bridge/ESO never receive RDS master credentials.
resource "aws_iam_role" "monitoring_database_bootstrap" {
  count = var.enable_monitoring_database ? 1 : 0
  name  = "${var.name}-incident-db-bootstrap"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { AWS = var.admin_role_arn }, Action = "sts:AssumeRole"
  }] })
  tags = local.tags
}

resource "aws_iam_role_policy" "monitoring_database_bootstrap" {
  count = var.enable_monitoring_database ? 1 : 0
  role  = aws_iam_role.monitoring_database_bootstrap[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], Resource = [aws_db_instance.monitoring[0].master_user_secret[0].secret_arn, aws_secretsmanager_secret.monitoring_queue[0].arn] },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.platform.arn
        Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com" }, StringLike = {
          "kms:EncryptionContext:SecretARN" = [aws_db_instance.monitoring[0].master_user_secret[0].secret_arn, aws_secretsmanager_secret.monitoring_queue[0].arn]
        } }
      }
    ]
  })
}
