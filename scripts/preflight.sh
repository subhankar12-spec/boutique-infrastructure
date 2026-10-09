#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ENVIRONMENT=${1:?Usage: preflight.sh nonprod|production|audit}
case "$ENVIRONMENT" in nonprod|production|audit) ;; *) exit 1;; esac
[[ "$ENVIRONMENT" == audit || -s ../boutique-orders/certs/global-bundle.pem ]] || { echo 'Fetch and commit the RDS CA bundle before AWS release.'; exit 1; }
[[ -f "environments/$ENVIRONMENT/backend.hcl" ]] || { echo 'Configure the state backend first.'; exit 1; }
[[ -f "environments/$ENVIRONMENT/terraform.tfvars" ]] || { echo 'Configure reviewed account/region/budget inputs first.'; exit 1; }
aws sts get-caller-identity --query Account --output text
terraform -chdir="environments/$ENVIRONMENT" init -input=false -backend-config=backend.hcl
terraform -chdir="environments/$ENVIRONMENT" validate
