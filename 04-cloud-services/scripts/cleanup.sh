#!/usr/bin/env bash
# cleanup.sh — DESTRUCTIVE: delete everything this module created, to stop all charges.
#   EC2 instance, RDS instance (no final snapshot!), S3 bucket (all versions), security groups,
#   key pair, IAM role/profile, SSM parameters, CloudWatch alarms/dashboard/log groups, SNS topic.
# Reads IDs from .deploy-state/<env>.env. Asks for confirmation unless --yes is given.
#
# Usage: ./cleanup.sh [--env dev] [--yes] [--keep-data] [--dry-run]
#   --keep-data   keep the S3 bucket and take a final RDS snapshot instead of deleting outright
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
parse_common_flags "$@"; set -- "${REMAINING[@]}"
YES=false; KEEP_DATA=false
while [[ $# -gt 0 ]]; do
  case "$1" in --yes) YES=true ;; --keep-data) KEEP_DATA=true ;; *) die "unknown option $1" ;; esac; shift
done
aws_preflight

INSTANCE_ID="$(state_get INSTANCE_ID)"; DB_ID="$(state_get DB_ID)"; BUCKET="$(state_get ASSET_BUCKET)"
SG_ID="$(state_get SG_ID)"; DB_SG_ID="$(state_get DB_SG_ID)"; KEY_NAME="$(state_get KEY_NAME)"
ROLE="$(state_get IAM_ROLE)"; PROFILE="$(state_get INSTANCE_PROFILE)"; TOPIC="$(state_get SNS_TOPIC)"

cat <<MSG
About to DELETE in account $AWS_ACCOUNT_ID / $AWS_REGION / env $ENV_NAME:
  EC2 instance    : ${INSTANCE_ID:-none}
  RDS instance    : ${DB_ID:-none}   $([[ "$KEEP_DATA" == true ]] && echo '(final snapshot kept)' || echo '(NO snapshot)')
  S3 bucket       : ${BUCKET:-none}   $([[ "$KEEP_DATA" == true ]] && echo '(kept)')
  security groups : ${SG_ID:-none} ${DB_SG_ID:-none}
  key pair        : ${KEY_NAME:-none}
  IAM             : ${ROLE:-none} / ${PROFILE:-none}
  SSM parameters  : /cloudops/$ENV_NAME/*
  CloudWatch      : alarms cloudops-$ENV_NAME-*, dashboard, log groups /cloudops/*
MSG
if [[ "$YES" == false && "$DRY_RUN" == false ]]; then
  confirm "Type y to continue" || die "aborted"
fi

step "1. EC2 instance"
if [[ -n "$INSTANCE_ID" ]]; then
  run aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --output text --query 'TerminatingInstances[].CurrentState.Name'
  [[ "$DRY_RUN" == false ]] && aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
  state_del INSTANCE_ID; state_del PUBLIC_IP
fi

step "2. RDS instance"
if [[ -n "$DB_ID" ]]; then
  run aws rds modify-db-instance --db-instance-identifier "$DB_ID" --no-deletion-protection --apply-immediately --output text --query 'DBInstance.DBInstanceStatus'
  if [[ "$KEEP_DATA" == true ]]; then
    run aws rds delete-db-instance --db-instance-identifier "$DB_ID" \
      --final-db-snapshot-identifier "$DB_ID-final-$(date +%Y%m%d%H%M)" --output text --query 'DBInstance.DBInstanceStatus'
  else
    run aws rds delete-db-instance --db-instance-identifier "$DB_ID" --skip-final-snapshot \
      --delete-automated-backups --output text --query 'DBInstance.DBInstanceStatus'
  fi
  [[ "$DRY_RUN" == false ]] && { log "waiting for RDS deletion (several minutes)..."; aws rds wait db-instance-deleted --db-instance-identifier "$DB_ID"; }
  state_del DB_ID; state_del DB_ENDPOINT
fi

step "3. Security groups (db first: it references the web sg)"
for sg in "$DB_SG_ID" "$SG_ID"; do
  [[ -n "$sg" ]] && run aws ec2 delete-security-group --group-id "$sg"
done
state_del DB_SG_ID; state_del SG_ID

step "4. Key pair"
if [[ -n "$KEY_NAME" ]]; then
  run aws ec2 delete-key-pair --key-name "$KEY_NAME"
  log "local private key left in place: ~/.ssh/$KEY_NAME.pem (delete it yourself)"
  state_del KEY_NAME
fi

step "5. S3 bucket"
if [[ -n "$BUCKET" && "$KEEP_DATA" == false ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    log "+ delete all object versions in s3://$BUCKET, then aws s3api delete-bucket"
  else
    # Versioned bucket: must delete every version and delete-marker before the bucket can go.
    aws s3api list-object-versions --bucket "$BUCKET" --output json \
      --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][]}' \
      > /tmp/cloudops-versions.json
    if grep -q '"Key"' /tmp/cloudops-versions.json; then
      aws s3api delete-objects --bucket "$BUCKET" --delete file:///tmp/cloudops-versions.json --output text --query 'length(Deleted)'
    fi
    rm -f /tmp/cloudops-versions.json
    aws s3api delete-bucket --bucket "$BUCKET"
  fi
  state_del ASSET_BUCKET
fi

step "6. IAM role + instance profile"
if [[ -n "$PROFILE" ]]; then
  run aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE" || true
  run aws iam delete-instance-profile --instance-profile-name "$PROFILE"
fi
if [[ -n "$ROLE" ]]; then
  run aws iam detach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore || true
  run aws iam delete-role-policy --role-name "$ROLE" --policy-name cloudops-app-access || true
  run aws iam delete-role --role-name "$ROLE"
fi
state_del IAM_ROLE; state_del INSTANCE_PROFILE

step "7. SSM parameters"
if [[ "$DRY_RUN" == true ]]; then
  log "+ aws ssm delete-parameters --names <all under /cloudops/$ENV_NAME>"
else
  names="$(aws ssm get-parameters-by-path --path "/cloudops/$ENV_NAME" --query 'Parameters[].Name' --output text)"
  # shellcheck disable=SC2086
  [[ -n "$names" ]] && aws ssm delete-parameters --names $names --output text --query 'length(DeletedParameters)'
fi

step "8. CloudWatch + SNS"
run aws cloudwatch delete-alarms --alarm-names "cloudops-$ENV_NAME-cpu-high" "cloudops-$ENV_NAME-status-check" "cloudops-$ENV_NAME-http-5xx"
run aws cloudwatch delete-dashboards --dashboard-names "cloudops-$ENV_NAME"
for lg in /cloudops/app /cloudops/nginx-access /cloudops/nginx-error; do
  run aws logs delete-log-group --log-group-name "$lg" || true
done
[[ -n "$TOPIC" ]] && run aws sns delete-topic --topic-arn "$TOPIC"; state_del SNS_TOPIC

log "cleanup finished. Double-check in the console: EC2, RDS, S3, EBS snapshots, and Billing -> Bills."
