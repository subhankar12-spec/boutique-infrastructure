terraform {
  required_version = ">= 1.11.0, < 2.0"
  required_providers { aws = { source = "hashicorp/aws", version = "~> 5.100" } }
  backend "s3" { use_lockfile = true }
}
provider "aws" { region = var.region }
data "aws_caller_identity" "current" {}
locals {
  account_id = data.aws_caller_identity.current.account_id
  trail_arn  = "arn:aws:cloudtrail:${var.region}:${local.account_id}:trail/${var.name}"
  tags       = { Project = "boutique", Component = "account-audit", ManagedBy = "terraform", Owner = var.owner }
  security_filters = {
    RootAccountUse           = "{ ($.userIdentity.type = \"Root\") && ($.userIdentity.invokedBy NOT EXISTS) && ($.eventType != \"AwsServiceEvent\") }"
    UnauthorizedAPI          = "{ ($.errorCode = \"*UnauthorizedOperation\") || ($.errorCode = \"AccessDenied*\") }"
    ConsoleLoginFailure      = "{ ($.eventName = \"ConsoleLogin\") && ($.errorMessage = \"Failed authentication\") }"
    TrailConfigurationChange = "{ ($.eventSource = \"cloudtrail.amazonaws.com\") && (($.eventName = \"StopLogging\") || ($.eventName = \"DeleteTrail\") || ($.eventName = \"UpdateTrail\") || ($.eventName = \"PutEventSelectors\")) }"
    IAMPolicyChange          = "{ ($.eventSource = \"iam.amazonaws.com\") && (($.eventName = \"CreatePolicy\") || ($.eventName = \"CreatePolicyVersion\") || ($.eventName = \"SetDefaultPolicyVersion\") || ($.eventName = \"AttachRolePolicy\") || ($.eventName = \"PutRolePolicy\") || ($.eventName = \"DeleteRolePolicy\")) }"
  }
}
resource "aws_kms_key" "audit" {
  description             = "Boutique CloudTrail and audit log encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "AccountAdministration", Effect = "Allow", Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }, Action = "kms:*", Resource = "*" },
    { Sid = "CloudTrailEncryption", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = ["kms:GenerateDataKey*"], Resource = "*", Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn }, StringLike = { "kms:EncryptionContext:aws:cloudtrail:arn" = local.trail_arn } } },
    { Sid = "CloudTrailDescribeKey", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "kms:DescribeKey", Resource = "*" },
    { Sid = "CloudWatchLogs", Effect = "Allow", Principal = { Service = "logs.${var.region}.amazonaws.com" }, Action = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"], Resource = "*", Condition = { ArnEquals = { "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/cloudtrail/${var.name}" } } },
    { Sid = "CloudWatchNotifications", Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" }, Action = ["kms:GenerateDataKey*", "kms:Decrypt"], Resource = "*" }
  ] })
  lifecycle { prevent_destroy = true }
  tags = local.tags
}
resource "aws_kms_alias" "audit" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.audit.key_id
}
resource "aws_s3_bucket" "audit" {
  bucket        = "${var.name}-${local.account_id}-${var.region}"
  force_destroy = false
  lifecycle { prevent_destroy = true }
  tags = local.tags
}
resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_ownership_controls" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.audit.arn
    }
    bucket_key_enabled = true
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    id     = "audit-retention"
    status = "Enabled"
    filter { prefix = "AWSLogs/" }
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    expiration { days = var.s3_retention_days }
    noncurrent_version_expiration { noncurrent_days = var.s3_retention_days }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
  depends_on = [aws_s3_bucket_versioning.audit]
}
resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "CloudTrailACLCheck", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "s3:GetBucketAcl", Resource = aws_s3_bucket.audit.arn, Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } } },
    { Sid = "CloudTrailWrite", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "s3:PutObject", Resource = "${aws_s3_bucket.audit.arn}/AWSLogs/${local.account_id}/*", Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn, "s3:x-amz-acl" = "bucket-owner-full-control" } } },
    { Sid = "RequireTLS", Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } }
  ] })
  depends_on = [aws_s3_bucket_public_access_block.audit, aws_s3_bucket_ownership_controls.audit]
}
resource "aws_cloudwatch_log_group" "audit" {
  name              = "/aws/cloudtrail/${var.name}"
  retention_in_days = var.cloudwatch_retention_days
  kms_key_id        = aws_kms_key.audit.arn
  lifecycle { prevent_destroy = true }
  tags = local.tags
}
resource "aws_iam_role" "cloudtrail_logs" {
  name               = "${var.name}-cloudwatch-delivery"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "sts:AssumeRole", Condition = { StringEquals = { "aws:SourceAccount" = local.account_id }, ArnEquals = { "aws:SourceArn" = local.trail_arn } } }] })
  tags               = local.tags
}
resource "aws_iam_role_policy" "cloudtrail_logs" {
  role   = aws_iam_role.cloudtrail_logs.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.audit.arn}:log-stream:${local.account_id}_CloudTrail_*" }] })
}
resource "aws_cloudtrail" "audit" {
  name                          = var.name
  s3_bucket_name                = aws_s3_bucket.audit.id
  kms_key_id                    = aws_kms_key.audit.arn
  enable_logging                = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.audit.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_logs.arn
  event_selector {
    read_write_type           = "All"
    include_management_events = true
    dynamic "data_resource" {
      for_each = length(var.audited_s3_prefix_arns) > 0 ? [var.audited_s3_prefix_arns] : []
      content {
        type   = "AWS::S3::Object"
        values = data_resource.value
      }
    }
  }
  depends_on = [aws_s3_bucket_policy.audit, aws_s3_bucket_server_side_encryption_configuration.audit, aws_iam_role_policy.cloudtrail_logs]
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = alltrue([for prefix in var.audited_s3_prefix_arns : !startswith(prefix, "arn:aws:s3:::${var.name}-${local.account_id}-${var.region}/")])
      error_message = "Do not audit object events in the trail's own delivery bucket."
    }
  }
  tags = local.tags
}
resource "aws_sns_topic" "security_alerts" {
  name              = "${var.name}-security-alerts"
  kms_master_key_id = aws_kms_key.audit.arn
  tags              = local.tags
}
resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }, Action = "SNS:*", Resource = aws_sns_topic.security_alerts.arn },
    { Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" }, Action = "SNS:Publish", Resource = aws_sns_topic.security_alerts.arn, Condition = { StringEquals = { "aws:SourceAccount" = local.account_id }, ArnLike = { "aws:SourceArn" = "arn:aws:cloudwatch:${var.region}:${local.account_id}:alarm:${var.name}-*" } } }
  ] })
}
resource "aws_sns_topic_subscription" "security_email" {
  for_each  = var.alarm_email_addresses
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}
resource "aws_cloudwatch_log_metric_filter" "security" {
  for_each       = local.security_filters
  name           = "${var.name}-${each.key}"
  log_group_name = aws_cloudwatch_log_group.audit.name
  pattern        = each.value
  metric_transformation {
    name          = each.key
    namespace     = "Boutique/AccountAudit"
    value         = "1"
    default_value = "0"
  }
}
resource "aws_cloudwatch_metric_alarm" "security" {
  for_each            = local.security_filters
  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = "CloudTrail security event: ${each.key}. Follow docs/aws-observability.md and preserve audit evidence."
  namespace           = "Boutique/AccountAudit"
  metric_name         = each.key
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.security_alerts.arn]
  tags                = local.tags
}
output "audit" {
  value = { trail_arn = aws_cloudtrail.audit.arn, s3_bucket = aws_s3_bucket.audit.id, cloudwatch_log_group = aws_cloudwatch_log_group.audit.name, security_topic_arn = aws_sns_topic.security_alerts.arn, kms_key_arn = aws_kms_key.audit.arn }
}
