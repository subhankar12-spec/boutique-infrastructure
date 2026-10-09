# AWS CloudWatch and CloudTrail

This Terraform has been validated locally but has not been deployed to AWS. Native Terraform mock tests check the audit plan without AWS credentials. They cannot establish real delivery permissions, regional availability or working notifications.

## CloudWatch: infrastructure operations

The shared platform module creates a rotating KMS key for regional logs. Nonprod retains logs for 30 days and production for 90 days:

| Source | Collection | Purpose |
| --- | --- | --- |
| EKS | All five control-plane log types | API, authentication, audit, controller and scheduler investigation |
| VPC | Flow logs to CloudWatch Logs | Diagnose accepted/rejected network traffic |
| Orders RDS | PostgreSQL and upgrade log exports | Database errors and upgrade investigation |
| Incident queue RDS, when enabled | PostgreSQL and upgrade log exports | Durable alert delivery investigation |
| Redis | JSON slow and engine logs | Slow commands and cache engine errors |

Managed RDS/Redis metrics drive the `<platform-name>-infrastructure` dashboard and alarms: PostgreSQL CPU above 80% for 15 minutes, free storage below 5 GiB for 10 minutes, Redis engine CPU above 75% and memory above 85% for 15 minutes. Redis dimensions identify each actual cluster/node, including both production members. Alarm and recovery notifications go to a KMS-encrypted SNS topic. The topic policy scopes CloudWatch publishers to this account and these alarm ARNs; its key policy grants the CloudWatch service the required encryption actions on this key. Set `alarm_email_addresses` and confirm each AWS email subscription; an empty list has no email recipient.

Optional `enable_cloudwatch_observability = true` installs the managed `amazon-cloudwatch-observability` EKS addon, collecting pod/node Container Insights and application/dataplane/host logs. Its service account uses IRSA rather than the node role. Application auto-instrumentation is disabled. Supply an explicitly reviewed `cloudwatch_observability_addon_version`; there is no moving latest default. Check version availability and configuration schema for your EKS version before planning:

```bash
aws eks describe-addon-versions --addon-name amazon-cloudwatch-observability --kubernetes-version YOUR_EKS_VERSION --region YOUR_REGION
aws eks describe-addon-configuration --addon-name amazon-cloudwatch-observability --addon-version YOUR_REVIEWED_VERSION --region YOUR_REGION
```

The addon is off by default to avoid duplicating paid telemetry alongside Prometheus and Loki. Existing Grafana dashboards and Alertmanager Slack/ServiceNow integration continue to serve application monitoring. AWS SNS topics are separate and do not automatically feed that adapter or Slack. Connecting AWS notifications to a real paging destination is an activation step; the initial SNS email route is available now.

## CloudTrail: account activity and security

`environments/audit` is a separate root applied once per AWS account, with its own remote-state key. It records read/write management events across regions and includes global-service events. CloudTrail delivers to both an encrypted CloudWatch log group and a private, versioned, KMS-encrypted S3 bucket. It enables digest-file validation, enforces TLS for bucket access, scopes delivery policies to the trail/account and prevents accidental Terraform destruction of the trail, bucket, key and log group.

CloudWatch retains audit events for 90 days by default. S3 retains logs for 365 days, transitions to Glacier Instant Retrieval after 90 days and also expires noncurrent versions. Retention is configurable, with at least 180 days for S3. Versioning and validation support investigation; this bucket is not an immutable Object Lock archive. Authorized lifecycle expiration still applies.

Security metric filters and SNS alarms detect root use, unauthorized API calls, failed console authentication, trail configuration changes and selected IAM policy changes. Review events before remediation. These rules cover the named events; they are not a complete security detection service or a guarantee against logging being disabled. Add independent trail-status checks to your operations routine.

S3 object data events cost extra and are disabled by default. `audited_s3_prefix_arns` opts in specific prefixes, for example the Terraform state prefix. The trail's own delivery bucket is rejected to avoid recursive data-event logging. This is an account trail, not an AWS Organizations trail; a multi-account production deployment needs organization-level audit governance.

## Configure and activate

1. Bootstrap the existing encrypted/versioned Terraform state backend. Use separate keys, for example `boutique/nonprod.tfstate`, `boutique/production.tfstate` and `boutique/audit.tfstate`.
2. Review `environments/audit/terraform.example.tfvars`, choose region/owner/retention and recipient addresses, and store actual runtime tfvars/backend files in ignored paths or Jenkins file credentials.
3. Add `terraform-audit-backend` and `terraform-audit-variables` Jenkins credentials. Select `ENVIRONMENT=audit` in the trusted infrastructure job, review its saved plan and approve that exact plan. Audit does not need an RDS CA file.
4. Plan nonprod/production with the new log groups and SNS resources. For an existing deployment, import any already-created RDS log groups before applying to avoid name conflicts. Review EKS/VPC log encryption changes and key permissions. Confirm email subscriptions.
5. Confirm collection after deployment; trigger an alarm only in a reviewed exercise. Do not delete or stop the trail as a test.

```bash
terraform -chdir=environments/audit output -json audit
aws cloudtrail get-trail-status --name boutique-account-audit --region YOUR_REGION
aws cloudtrail validate-logs --trail-arn YOUR_TRAIL_ARN --start-time YOUR_UTC_START --end-time YOUR_UTC_END --region YOUR_REGION
aws logs describe-log-streams --log-group-name /aws/cloudtrail/boutique-account-audit --region YOUR_REGION
aws cloudwatch describe-alarms --alarm-name-prefix boutique- --region YOUR_REGION
aws sns list-subscriptions-by-topic --topic-arn YOUR_TOPIC_ARN --region YOUR_REGION
```

Check `IsLogging`, recent `LatestDeliveryTime`, CloudWatch delivery time and any delivery errors. Keep a periodic check independent of the trail's own alarms. For a security alarm, identify the principal/action/source IP in CloudTrail, preserve relevant objects/digests, investigate authorization and follow the incident runbook. CloudWatch Logs Insights on the audit group can start with:

```text
fields @timestamp, eventName, eventSource, userIdentity.arn, sourceIPAddress, errorCode
| filter errorCode like /AccessDenied|Unauthorized/
| sort @timestamp desc
| limit 100
```

Management-event trail delivery may qualify for the first-copy allowance; S3, KMS, CloudWatch ingestion/storage, alarms, dashboards, data events and Container Insights have separate charges. Budgets notify rather than cap spending. Review the regional AWS pricing calculator before apply. No AWS resources or live Slack/ServiceNow messages were created during this implementation.
