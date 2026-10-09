# Managed incident queue and integration secrets

The AWS reference gives the incident adapter a dedicated PostgreSQL 16 RDS
instance. It does not share orders data or credentials. Production enables it
by default; `enable_monitoring_database = false` is the nonprod default so a
training deployment can avoid the additional RDS cost. Enabling nonprod creates
one smaller single-AZ instance. This configuration has been validated without
provisioning AWS resources; no account-level plan, connectivity or RDS restore
has been executed.

Production uses Multi-AZ, private database subnets, KMS-encrypted storage,
AWS-managed administrator credentials, 35 days of automated backups/PITR,
deletion protection and a required final snapshot. Storage starts at 20 GiB and
can grow to 100 GiB. PostgreSQL/upgrade logs retain 90 days (nonprod 30), with
Performance Insights enabled in production. The parameter group forces TLS.
Security groups allow PostgreSQL only from the cluster and private SSM operator
host. The monitoring Kubernetes egress policy must also allow the private RDS
endpoint on port 5432. The AWS monitoring ESO directory includes this binding
for the three current production database subnet CIDRs; compare it with output
`platform.monitoring.database_subnet_cidrs` before applying. Multi-AZ improves
availability; it does not replace
backups or a tested recovery procedure. This extra database is billable.

## Prepare and initialize

1. Run `scripts/fetch-monitoring-rds-ca.sh`. It fetches the official RDS bundle
   over verified HTTPS, parses the PEM and prints its SHA256 for review. Set
   `monitoring_postgresql_ca_file` in the ignored runtime tfvars to its absolute
   path. Review bundle changes in your release process; the file is public CA
   material, not a credential. A missing/invalid file blocks managed-queue plans.
2. Review the Terraform plan, costs and platform permissions before applying
   through the infrastructure pipeline. No apply is implied by these examples.
3. Inspect the nonsecret output `platform.monitoring`: endpoint, database/user,
   admin secret ARN, queue/integration secret names, External Secrets role ARN
   and the dedicated database bootstrap role ARN.
4. From the private operator network, use reviewed administrator credentials
   allowed to assume that bootstrap role. Install `boto3` and `psycopg[binary]`
   in the operator's managed tooling environment, and run:

   ```bash
   python scripts/init-monitoring-database.py \
     --region ap-south-1 \
     --bootstrap-role ROLE_ARN_FROM_OUTPUT \
     --admin-secret ADMIN_SECRET_ARN_FROM_OUTPUT \
     --queue-secret QUEUE_SECRET_NAME_FROM_OUTPUT \
     --host DATABASE_ENDPOINT_FROM_OUTPUT \
     --ca-file /absolute/path/certs/rds-global-bundle.pem
   ```

   The script assumes a 15-minute session and retrieves only the two specified
   secrets into memory. It compares the reviewed CA with the delivered CA,
   verifies TLS hostname/chain, rejects unexpected role memberships, and creates
   `boutique_incident` with no superuser, database-creation, role-creation,
   replication or row-security-bypass permissions. It owns only the
   `incident_queue` schema in `boutique_incidents` and can connect to that
   database. Public database/schema privileges are revoked. The adapter creates
   its queue table/index on startup, so its dedicated schema-owner login retains
   DDL there. Runtime verification checks identity, schema and privilege flags;
   credentials and SQL containing passwords are never printed by the script.

The instance profile for the SSM host still grants only SSM access. It does not
receive the bootstrap secret policy or cluster-admin rights. Administrators
must assume the separately scoped bootstrap role deliberately. The role reads
the queue and RDS admin secret only, and its KMS permission is limited to those
Secrets Manager encryption contexts. The monitoring ESO role cannot read the
RDS administrator secret or application secrets.

## Deliver credentials to Kubernetes

Review `boutique-gitops/platform/external-secrets/monitoring/production.yaml`,
replace account, region and role ARN from Terraform outputs, then include those
bindings in the AWS bootstrap. The namespace and ESO v1 CRDs must already exist.
The namespace-scoped SecretStore authenticates as
`monitoring:external-secrets-monitoring`; its role can read only the two
monitoring secrets and decrypt only their Secrets Manager KMS contexts.

The queue secret becomes `monitoring-incident-queue` in Kubernetes with:

| Key | Consumer |
| --- | --- |
| `QUEUE_DATABASE_URL` | Adapter environment; dedicated runtime login, `sslmode=verify-full` |
| `postgresql_ca` | Adapter CA volume at `/run/queue-ca/ca.crt` |

The integration secret is **metadata only** in Terraform. Populate its four
keys directly through approved Secrets Manager tooling: `slack_webhook`,
`webhook_token`, `servicenow_password`, and `grafana_password`. Credentials stay
outside tfvars, plans and Git. Before filling it, the integration ExternalSecret
will report missing data and dependent pods will remain unready; this is
deliberate. Configure the real ServiceNow HTTPS base URL/username in the adapter
profile and review its dedicated user's incident ACLs. The supplied mock tests
do not send Slack messages or create ServiceNow incidents.

Terraform-generated queue passwords and their secret versions are stored in
sensitive state. Use the encrypted, versioned, access-controlled backend and
restrict plan/state access. `platform.monitoring` outputs expose metadata only.
Do not put Kubernetes Secret objects with actual values into Git.

## Bootstrap regression checks

`python -m unittest discover -s tests -v` runs connection-secret validation and
skips the integration check unless an explicit fixture is configured. The
PostgreSQL regression requires `TEST_MONITORING_ADMIN_URL` for an isolated TLS
database named `boutique_incidents`, with a nonsuperuser CREATEROLE administrator
that owns the database, plus `TEST_MONITORING_ALLOW_DESTRUCTIVE=true`. Pass the
URL through the test runner's secret environment; never place it in shell
history or logs. The test initializes twice, checks schema writes and rejects
public-schema writes and database-wide schema creation. Do not use a real
instance: the test intentionally changes roles and public database privileges.
These checks passed against disposable PostgreSQL 16 with verified TLS. They
exercise PostgreSQL behavior without claiming an AWS RDS deployment test.

## Rotation and recovery

The application queue password is separate from RDS-managed master password
rotation. Rotate the queue password through a reviewed maintenance change:
pause adapter writes/workers, rotate the Terraform random password and secret,
rerun the database initializer using the administrator role, wait for ESO's
sync, and roll out the adapter. Existing pods keep secret environment values
until restarted. Alertmanager retains/retries notifications while the adapter
is unavailable; preserve its persistent data and monitor delivery failures.
Rotating Slack/ServiceNow secrets uses secret-manager writes and controlled
component reload/rollout, never tracked secret variables. Review CA bundle
renewal, refresh the secret and restart clients before removing old trust roots.

For a recovery exercise, isolate a new RDS instance restored from a snapshot or
PITR, verify its TLS endpoint, initialize/reconcile the dedicated role using the
restored administrator credentials, and supply a reviewed queue URL for that
endpoint. Stop the old adapter before switching to the restored queue. Restored
old pending records can be redelivered, so the ServiceNow scripted unique-key
upsert remains necessary; queue recovery does not guarantee exactly-once remote
delivery. Verify pending/blocked counts, duplicate handling and firing/resolved
lifecycle against mocks before enabling live integrations. Record actual RPO
and RTO; 35-day retention alone does not establish either target.

Destroying the database requires a reviewed deletion-protection change and
retention of the final snapshot. A stable random suffix avoids common name
collisions for the first teardown; if rebuilding the same stack after a final
snapshot exists, review and rotate the snapshot suffix before the next teardown.
Never delete pending queue data to silence an incident-backlog alert.
