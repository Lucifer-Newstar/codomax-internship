#!/usr/bin/env bash
# aws_preflight.sh — check the AWS CLI setup before provisioning anything.
#   - CLI installed and configured, region set
#   - NOT using root-account credentials
#   - shows the identity, account, region and a quick permission probe
#
# Usage: ./aws_preflight.sh [--region ap-south-1] [--dry-run]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
parse_common_flags "$@"

step "1. AWS CLI"
need_cmd aws curl
aws --version

step "2. Identity (must not be root)"
aws_preflight

step "3. Permission probe (read-only)"
if [[ "$DRY_RUN" == false ]]; then
  for probe in "ec2 describe-vpcs --max-items 1" "s3api list-buckets --max-items 1" \
               "iam get-user" "ssm describe-parameters --max-items 1"; do
    # shellcheck disable=SC2086
    if aws $probe --output text >/dev/null 2>&1; then
      log "ok      aws $probe"
    else
      log "denied  aws $probe   (fine if your policy does not include it)"
    fi
  done
fi

step "4. Free-tier reminder"
cat <<MSG
Resources used by this module and their typical cost (check your own account, pricing changes):
  EC2 t3.micro / t2.micro   free-tier eligible for new accounts (750 h/month), else ~\$0.01/h
  RDS db.t3.micro Postgres  free-tier eligible for 12 months (750 h/month), else ~\$0.02/h
  S3 (few MB)               ~\$0
  CloudWatch (5 GB logs, 10 alarms) free tier; log retention set to 7 days
  Data transfer, snapshots, Elastic IP left unattached -> small but real charges
Run ./cleanup.sh when you are done.
MSG
