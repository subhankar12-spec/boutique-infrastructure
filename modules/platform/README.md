# Platform module

The nonprod and production environment roots each call this module with their
own inputs and Terraform state. All `.tf` files in this directory form one
module; Terraform resolves their references and dependencies together.

| File | Responsibility |
| --- | --- |
| [main.tf](main.tf) | Shared availability-zone selection and resource tags |
| [networking.tf](networking.tf) | Version-pinned VPC module, subnet/NAT settings and shared database security rules |
| [eks.tf](eks.tf) | Private EKS control plane, access entries, encrypted audit log group, worker nodes and core addons |
| [iam.tf](iam.tf) | Cluster/node roles, OIDC provider and per-environment External Secrets roles |
| [encryption.tf](encryption.tf) | Platform data encryption key and alias |
| [databases.tf](databases.tf) | Per-environment PostgreSQL and Redis, including backups and production availability settings |
| [secrets.tf](secrets.tf) | Generated application credentials and Secrets Manager values |
| [budgets.tf](budgets.tf) | Monthly tagged budget and email notification |
| [monitoring.tf](monitoring.tf) | Optional dedicated incident-queue database and monitoring integration secrets/roles |
| [observability.tf](observability.tf) | Encrypted service logs, CloudWatch alarms/dashboard, SNS and optional Container Insights |
| [operator.tf](operator.tf) | SSM-only private operator host and scoped administrative network access |
| [variables.tf](variables.tf) | Module input contract |
| [outputs.tf](outputs.tf) | Module output contract |
| [versions.tf](versions.tf) | Terraform and provider requirements |

The VPC is a child module sourced from `terraform-aws-modules/vpc/aws` at an
explicit version. Its underlying resources are downloaded during initialization.
The local component files organize this platform module without adding wrapper
modules or separate component state.

AWS plan/apply and runtime acceptance remain operator steps documented in the
[repository guide](../../README.md).
