region                     = "ap-south-1"
kubernetes_version         = "1.34"
admin_role_arn             = "arn:aws:iam::123456789012:role/boutique-platform-admin"
budget_email               = "replace-with-your-email@example.com"
monthly_budget_usd         = 500
owner                      = "subhankar12-spec"
enable_monitoring_database = false
# Enable for managed-queue staging tests; adds a separate RDS instance.
# monitoring_postgresql_ca_file = "/absolute/path/boutique-infrastructure/certs/rds-global-bundle.pem"

# CloudWatch infrastructure alarms: confirm each SNS email subscription.
alarm_email_addresses = []
# Paid node/pod telemetry, disabled until a compatible addon version is reviewed.
enable_cloudwatch_observability        = false
cloudwatch_observability_addon_version = ""
