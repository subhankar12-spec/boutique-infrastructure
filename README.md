# AWS reference architecture

This is an intentionally realistic reference, not the cheapest homelab option. It has not been applied. Use local Kubernetes first.

- Separate nonprod/production roots and remote-state keys.
- Three-AZ VPCs, private workers and data subnets, private EKS API, IMDSv2, VPC flow logs and EKS audit logs.
- Nonprod uses one NAT; production uses per-AZ NAT gateways.
- Per-environment RDS PostgreSQL and TLS-enabled authenticated Redis. Production uses Multi-AZ RDS and Redis failover.
- AWS-managed RDS admin password; separate application DB role initialized using `scripts/init-database.py`.
- KMS encryption, per-environment External Secrets IAM roles, data backups, deletion protection and budget alerts.
- Optional dedicated incident-queue RDS, scoped monitoring secret roles and TLS CA delivery; enabled by default in the production root.
- An SSM-only private operator host for an administrative network path, with no inbound SSH.

## Validation without AWS

```bash
terraform fmt -check -recursive
terraform -chdir=environments/nonprod init -backend=false
terraform -chdir=environments/nonprod validate
terraform -chdir=environments/production init -backend=false
terraform -chdir=environments/production validate
```

Provider locks are committed after validation. This verifies configuration structure, not service quotas, permissions, region capacity, EKS version availability or runtime connectivity.

## Jenkins runtime configuration

Run this repository's Jenkinsfile only from protected/reviewed `main` on a
trusted Terraform agent. Pull requests must never receive these file bindings
or AWS deployment identity. Configure Jenkins file credentials:

| Credential ID | Content |
| --- | --- |
| `terraform-nonprod-backend` / `terraform-production-backend` | Reviewed S3 backend HCL for the selected state key |
| `terraform-nonprod-variables` / `terraform-production-variables` | Reviewed environment tfvars (account/region, admin role and budget inputs) |
| `rds-global-ca-bundle` | Reviewed official RDS CA PEM bundle; public certificate material |

AWS authentication uses the trusted agent's short-lived workload identity.
Keep AWS access keys out of backend HCL/tfvars; keep external integration
credentials in Secrets Manager. Credential file bindings are outside the source
checkout and expire at the end of the planning block, so `deleteDir()` does not
remove configuration before it is consumed. The pipeline copies the reviewed
CA to the private plan directory and sets `TF_VAR_monitoring_postgresql_ca_file`
plus the explicit plan variable to that stable path. A different tfvars path
cannot silently override the trust bundle.

The binary saved plan is private (directory 0700, file 0600), applied unchanged
after approval and never archived. Terraform JSON is read through a pipe;
`scripts/summarize-plan.py` emits only resource addresses/types/actions and
counts. This sparse summary is displayed for approval and archived, without
variables, output values or before/after attributes. The plan directory and
checkout, including initialized backend metadata, are deleted after the job.

## Before provisioning

1. Choose your AWS account, region, administrator/deployment roles and monthly budget. Confirm EKS version and database/cache instance availability in that region; update reviewed pins when needed.
2. Bootstrap the encrypted/versioned state bucket using `bootstrap/`. Protect the initial local bootstrap state and migrate it to its own remote state after creation. State-bucket destruction is prevented.
3. Copy `backend.example.hcl` and `terraform.example.tfvars` to the ignored runtime files for each environment; replace every example account, email and bucket value.
4. Configure short-lived deployment credentials and least-privilege IAM. Never commit credentials. Run `scripts/preflight.sh`; plan and review costs before applying. The sample budget is an input example, not a cost estimate or spending cap. Budgets notify; they do not stop resources.
5. Run the reviewed Jenkins Terraform plan/apply job. Production approval must review the saved plan. Terraform creates AWS resources, not Jenkins agents or Kubernetes platform controllers.

## Data initialization and cluster bootstrap

Fetch the official RDS CA bundle with the orders helper. It must be included in the reviewed orders release image; production uses hostname and chain verification (`verify-full`). After apply, run `scripts/init-database.py` from a trusted VPC network path with access to only the specified admin/application secrets. It creates an application-owned schema and a non-admin login. The app runs Flyway migrations as that schema owner; a separate migration role is a later hardening step.

Use SSM to access the operator host and a reviewed administrator role to run AWS CLI/kubectl from a VPC-connected workstation or trusted agent. The operator instance role itself grants SSM access only; it is deliberately not cluster-admin. Configure your private access route before attempting `aws eks update-kubeconfig` and Kubernetes API operations.

Install Argo CD, External Secrets, ingress/TLS controllers and monitoring through reviewed bootstrap configuration. Set secret-role/account/region values, storefront DNS and real image digests. AWS-managed PostgreSQL and Redis are supplied through External Secrets; do not apply homelab StatefulSets on AWS.

## State and cost precautions

See [monitoring-data.md](docs/monitoring-data.md) for the managed incident queue's
least-privilege database initialization, integration-secret setup, rotation and
restore procedure. The queue and its HA adapter do not use the orders database.

Terraform-generated application passwords and secret versions are sensitive values stored in state. State encryption does not remove the need to restrict reads and backups. The state backend currently uses S3-managed encryption and TLS enforcement. Enable the Project cost-allocation tag before relying on the tagged budget filter. Budget alerts exclude untagged/mistagged resources.

EKS control planes, NAT gateways, workers, managed databases/caches, load balancers and logs all incur costs. This topology can cost hundreds of USD/month or more depending on region and usage. Use the homelab track unless you explicitly want to provision it. Teardown must disable data deletion protection through a reviewed change and preserve required snapshots; final-snapshot names must be made unique across recreation cycles.
