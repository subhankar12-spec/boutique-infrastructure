data "aws_caller_identity" "observability" {}
locals {
  log_retention_days  = var.production ? 90 : 30
  database_log_groups = { for row in flatten([for env in var.environments : [for kind in ["postgresql", "upgrade"] : { key = "${env}/${kind}", environment = env, kind = kind }]]) : row.key => row }
  redis_log_groups    = { for row in flatten([for env in var.environments : [for kind in ["slow-log", "engine-log"] : { key = "${env}/${kind}", environment = env, kind = kind }]]) : row.key => row }
  redis_members       = { for row in flatten([for env in var.environments : [for index in range(var.production ? 2 : 1) : { key = "${env}/${index}", environment = env, index = index }]]) : row.key => row }
  databases           = merge({ for env, database in aws_db_instance.orders : env => database.identifier }, var.enable_monitoring_database ? { monitoring = aws_db_instance.monitoring[0].identifier } : {})
}

# CloudWatch log encryption is scoped to this account's regional log groups.
resource "aws_kms_key" "logs" {
  description             = "${var.name} CloudWatch log encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "AccountAdministration", Effect = "Allow", Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.observability.account_id}:root" }, Action = "kms:*", Resource = "*" },
    { Sid = "CloudWatchLogs", Effect = "Allow", Principal = { Service = "logs.${var.region}.amazonaws.com" }, Action = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"], Resource = "*", Condition = { ArnLike = { "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.region}:${data.aws_caller_identity.observability.account_id}:log-group:*" } } }
  ] })
  tags = local.tags
}
resource "aws_kms_alias" "logs" {
  name          = "alias/${var.name}-logs"
  target_key_id = aws_kms_key.logs.key_id
}
resource "aws_cloudwatch_log_group" "orders" {
  for_each          = local.database_log_groups
  name              = "/aws/rds/instance/${var.name}-${each.value.environment}-orders/${each.value.kind}"
  retention_in_days = local.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
  tags              = local.tags
}
resource "aws_cloudwatch_log_group" "redis" {
  for_each          = local.redis_log_groups
  name              = "/aws/elasticache/${var.name}/${each.value.environment}/${each.value.kind}"
  retention_in_days = local.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
  tags              = local.tags
}
resource "aws_kms_key" "alarm_notifications" {
  description             = "${var.name} CloudWatch SNS encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.observability.account_id}:root" }, Action = "kms:*", Resource = "*" },
    { Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" }, Action = ["kms:Decrypt", "kms:GenerateDataKey*"], Resource = "*" }
  ] })
  tags = local.tags
}
resource "aws_sns_topic" "infrastructure_alerts" {
  name              = "${var.name}-infrastructure-alerts"
  kms_master_key_id = aws_kms_key.alarm_notifications.arn
  tags              = local.tags
}
resource "aws_sns_topic_policy" "infrastructure_alerts" {
  arn = aws_sns_topic.infrastructure_alerts.arn
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.observability.account_id}:root" }, Action = "SNS:*", Resource = aws_sns_topic.infrastructure_alerts.arn },
    { Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" }, Action = "SNS:Publish", Resource = aws_sns_topic.infrastructure_alerts.arn, Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.observability.account_id }, ArnLike = { "aws:SourceArn" = "arn:aws:cloudwatch:${var.region}:${data.aws_caller_identity.observability.account_id}:alarm:${var.name}-*" } } }
  ] })
}
resource "aws_sns_topic_subscription" "infrastructure_email" {
  for_each  = var.alarm_email_addresses
  topic_arn = aws_sns_topic.infrastructure_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}
resource "aws_cloudwatch_metric_alarm" "database_cpu" {
  for_each            = local.databases
  alarm_name          = "${var.name}-${each.key}-database-cpu"
  alarm_description   = "Database CPU above 80% for 15 minutes; inspect load/connections before scaling."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  dimensions          = { DBInstanceIdentifier = each.value }
  alarm_actions       = [aws_sns_topic.infrastructure_alerts.arn]
  ok_actions          = [aws_sns_topic.infrastructure_alerts.arn]
  tags                = local.tags
}
resource "aws_cloudwatch_metric_alarm" "database_storage" {
  for_each            = local.databases
  alarm_name          = "${var.name}-${each.key}-database-storage"
  alarm_description   = "Database has less than 5 GiB free storage; check growth and autoscaling limits."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 5 * 1024 * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"
  dimensions          = { DBInstanceIdentifier = each.value }
  alarm_actions       = [aws_sns_topic.infrastructure_alerts.arn]
  ok_actions          = [aws_sns_topic.infrastructure_alerts.arn]
  tags                = local.tags
}
resource "aws_cloudwatch_metric_alarm" "redis_cpu" {
  for_each            = local.redis_members
  alarm_name          = "${var.name}-${each.value.environment}-redis-${each.value.index}-cpu"
  alarm_description   = "Redis engine CPU above 75% for 15 minutes; inspect command latency and workload."
  namespace           = "AWS/ElastiCache"
  metric_name         = "EngineCPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 75
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  dimensions          = { CacheClusterId = sort(tolist(aws_elasticache_replication_group.redis[each.value.environment].member_clusters))[each.value.index], CacheNodeId = "0001" }
  alarm_actions       = [aws_sns_topic.infrastructure_alerts.arn]
  ok_actions          = [aws_sns_topic.infrastructure_alerts.arn]
  tags                = local.tags
}
resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  for_each            = local.redis_members
  alarm_name          = "${var.name}-${each.value.environment}-redis-${each.value.index}-memory"
  alarm_description   = "Redis memory use above 85% for 15 minutes; investigate evictions and cart retention."
  namespace           = "AWS/ElastiCache"
  metric_name         = "DatabaseMemoryUsagePercentage"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  dimensions          = { CacheClusterId = sort(tolist(aws_elasticache_replication_group.redis[each.value.environment].member_clusters))[each.value.index], CacheNodeId = "0001" }
  alarm_actions       = [aws_sns_topic.infrastructure_alerts.arn]
  ok_actions          = [aws_sns_topic.infrastructure_alerts.arn]
  tags                = local.tags
}
resource "aws_cloudwatch_dashboard" "infrastructure" {
  dashboard_name = "${var.name}-infrastructure"
  dashboard_body = jsonencode({ widgets = [
    { type = "metric", x = 0, y = 0, width = 12, height = 6, properties = { title = "PostgreSQL CPU", region = var.region, stat = "Average", period = 300, metrics = [for name in values(local.databases) : ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", name]] } },
    { type = "metric", x = 12, y = 0, width = 12, height = 6, properties = { title = "PostgreSQL free storage", region = var.region, stat = "Minimum", period = 300, metrics = [for name in values(local.databases) : ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", name]] } },
    { type = "metric", x = 0, y = 6, width = 24, height = 6, properties = { title = "Redis engine CPU", region = var.region, stat = "Average", period = 300, metrics = [for row in values(local.redis_members) : ["AWS/ElastiCache", "EngineCPUUtilization", "CacheClusterId", sort(tolist(aws_elasticache_replication_group.redis[row.environment].member_clusters))[row.index], "CacheNodeId", "0001"]] } }
  ] })
}

# Optional paid pod/node telemetry. Require an explicitly reviewed, compatible
# AWS addon version; never silently deploy a moving latest release.
resource "aws_cloudwatch_log_group" "container_insights" {
  for_each          = var.enable_cloudwatch_observability ? toset(["application", "dataplane", "host", "performance"]) : toset([])
  name              = "/aws/containerinsights/${var.name}/${each.key}"
  retention_in_days = local.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
  tags              = local.tags
}
resource "aws_iam_role" "cloudwatch_agent" {
  count = var.enable_cloudwatch_observability ? 1 : 0
  name  = "${var.name}-cloudwatch-agent"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }, Action = "sts:AssumeRoleWithWebIdentity", Condition = { StringEquals = {
    "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:amazon-cloudwatch:cloudwatch-agent",
    "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
  } } }] })
  tags = local.tags
}
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  count      = var.enable_cloudwatch_observability ? 1 : 0
  role       = aws_iam_role.cloudwatch_agent[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}
resource "aws_eks_addon" "cloudwatch_observability" {
  count                       = var.enable_cloudwatch_observability ? 1 : 0
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "amazon-cloudwatch-observability"
  addon_version               = var.cloudwatch_observability_addon_version
  service_account_role_arn    = aws_iam_role.cloudwatch_agent[0].arn
  resolve_conflicts_on_update = "PRESERVE"
  # Disable application auto-instrumentation: this project focuses on DevOps.
  configuration_values = jsonencode({ containerLogs = { enabled = true }, manager = { applicationSignals = { autoMonitor = { languages = [] } } } })
  depends_on           = [aws_iam_role_policy_attachment.cloudwatch_agent, aws_cloudwatch_log_group.container_insights, aws_eks_node_group.this]
  lifecycle {
    precondition {
      condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", var.cloudwatch_observability_addon_version))
      error_message = "Select a reviewed amazon-cloudwatch-observability version compatible with this EKS version before enabling it."
    }
  }
}
