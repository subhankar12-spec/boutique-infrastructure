region                     = "ap-south-1"
kubernetes_version         = "1.34"
admin_role_arn             = "arn:aws:iam::123456789012:role/boutique-platform-admin"
budget_email               = "replace-with-your-email@example.com"
monthly_budget_usd         = 500
owner                      = "subhankar12-spec"
enable_monitoring_database = true
# Set an absolute path after fetching/reviewing the official CA bundle.
# monitoring_postgresql_ca_file = "/absolute/path/boutique-infrastructure/certs/rds-global-bundle.pem"
