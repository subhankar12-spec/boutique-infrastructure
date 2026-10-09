mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}
override_resource {
  override_during = plan
  target          = aws_s3_bucket.audit
  values = {
    id  = "boutique-account-audit-123456789012-ap-south-1"
    arn = "arn:aws:s3:::boutique-account-audit-123456789012-ap-south-1"
  }
}
variables { owner = "offline-policy-test" }
run "secure_management_event_trail" {
  command = plan
  assert {
    condition     = aws_cloudtrail.audit.enable_logging && aws_cloudtrail.audit.is_multi_region_trail && aws_cloudtrail.audit.include_global_service_events && aws_cloudtrail.audit.enable_log_file_validation
    error_message = "Audit must record all regions, global services and validated logging."
  }
  assert {
    condition     = one(aws_cloudtrail.audit.event_selector).include_management_events && one(aws_cloudtrail.audit.event_selector).read_write_type == "All" && length(one(aws_cloudtrail.audit.event_selector).data_resource) == 0
    error_message = "Default trail must include read/write management events without paid data events."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.audit.block_public_acls && aws_s3_bucket_public_access_block.audit.block_public_policy && aws_s3_bucket_public_access_block.audit.ignore_public_acls && aws_s3_bucket_public_access_block.audit.restrict_public_buckets && one(aws_s3_bucket_versioning.audit.versioning_configuration).status == "Enabled"
    error_message = "Audit storage must be private and versioned."
  }
  assert {
    condition     = aws_kms_key.audit.enable_key_rotation && aws_kms_key.audit.deletion_window_in_days == 30 && aws_cloudwatch_log_group.audit.retention_in_days == 90
    error_message = "Audit key rotation, deletion delay and log retention must remain configured."
  }
  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.security) == 5 && length(aws_cloudwatch_metric_alarm.security) == 5 && alltrue([for alarm in aws_cloudwatch_metric_alarm.security : alarm.threshold == 1 && alarm.namespace == "Boutique/AccountAudit"])
    error_message = "Named audit security detections must remain enabled."
  }
  assert {
    condition     = jsondecode(aws_s3_bucket_policy.audit.policy).Statement[1].Condition.StringEquals["aws:SourceArn"] == "arn:aws:cloudtrail:ap-south-1:123456789012:trail/boutique-account-audit" && jsondecode(aws_s3_bucket_policy.audit.policy).Statement[2].Condition.Bool["aws:SecureTransport"] == "false"
    error_message = "Trail delivery must be scoped to this trail and non-TLS access denied."
  }
}
run "explicit_data_events" {
  command = plan
  variables { audited_s3_prefix_arns = ["arn:aws:s3:::example-state-bucket/boutique/"] }
  assert {
    condition     = one(one(aws_cloudtrail.audit.event_selector).data_resource).values == tolist(["arn:aws:s3:::example-state-bucket/boutique/"])
    error_message = "Only explicitly selected object prefixes may produce data events."
  }
}
run "reject_recursive_audit_bucket_events" {
  command = plan
  variables { audited_s3_prefix_arns = ["arn:aws:s3:::boutique-account-audit-123456789012-ap-south-1/"] }
  expect_failures = [aws_cloudtrail.audit]
}
run "reject_short_retention" {
  command = plan
  variables { s3_retention_days = 30 }
  expect_failures = [var.s3_retention_days]
}
