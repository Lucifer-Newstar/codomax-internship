#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks inside JMESPath queries are literal
# cost_check.sh — resource quotas, running resources and cost visibility.
#   quotas  : the limits that matter for this module (vCPUs, VPCs, EIPs, S3 buckets, RDS instances)
#   running : everything tagged Project=cloudops that costs money right now
#   budget  : create a monthly budget with an e-mail alert at 80% (free: 2 budgets per account)
#   spend   : month-to-date cost by service (Cost Explorer API: ~$0.01 per request!)
#
# Usage: ./cost_check.sh <quotas|running|budget --email you@x.com --amount 5|spend> [--dry-run]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
parse_common_flags "$@"; set -- "${REMAINING[@]}"
ACTION="${1:-running}"; shift || true
EMAIL=""; AMOUNT="5"
while [[ $# -gt 0 ]]; do
  case "$1" in --email) EMAIL="${2:?}"; shift ;; --amount) AMOUNT="${2:?}"; shift ;; *) die "unknown option $1" ;; esac; shift
done
aws_preflight

case "$ACTION" in
  quotas)
    step "Service quotas in $AWS_REGION (defaults for a new account)"
    # code -> (service, quota code)
    for q in "ec2 L-1216C47A Running On-Demand Standard instances (vCPUs)" \
             "vpc L-F678F1CE VPCs per region" "ec2 L-0263D0A3 Elastic IPs" \
             "s3 L-DC2B2D3D Buckets per account" "rds L-7B6409FD DB instances"; do
      # shellcheck disable=SC2086  # intentional word split of the quota tuple
      set -- $q; svc="$1"; code="$2"; shift 2
      val="$(aws service-quotas get-service-quota --service-code "$svc" --quota-code "$code" \
             --query Quota.Value --output text 2>/dev/null || echo '?')"
      printf '  %-45s %s\n' "$*" "$val"
    done
    log "Ask for more: Service Quotas console -> request increase (free, usually minutes–hours)."
    ;;
  running)
    step "EC2 instances (Project=$PROJECT)"
    run aws ec2 describe-instances --filters Name=tag:Project,Values="$PROJECT" \
      --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name,IP:PublicIpAddress,Env:Tags[?Key==`Env`]|[0].Value}' --output table
    step "RDS instances"
    run aws rds describe-db-instances \
      --query 'DBInstances[].{Id:DBInstanceIdentifier,Class:DBInstanceClass,Status:DBInstanceStatus,Storage:AllocatedStorage}' --output table
    step "Unattached Elastic IPs (charged when NOT attached!)"
    run aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp' --output text
    step "EBS volumes not attached"
    run aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].{Id:VolumeId,GiB:Size}' --output table
    step "S3 buckets"
    run aws s3 ls
    ;;
  budget)
    [[ -n "$EMAIL" ]] || die "--email required"
    step "Monthly budget of \$$AMOUNT with alert at 80% -> $EMAIL"
    BUDGET="{\"BudgetName\":\"cloudops-monthly\",\"BudgetLimit\":{\"Amount\":\"$AMOUNT\",\"Unit\":\"USD\"},\"TimeUnit\":\"MONTHLY\",\"BudgetType\":\"COST\"}"
    NOTIF="[{\"Notification\":{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":80,\"ThresholdType\":\"PERCENTAGE\"},\"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$EMAIL\"}]}]"
    run aws budgets create-budget --account-id "$AWS_ACCOUNT_ID" --budget "$BUDGET" --notifications-with-subscribers "$NOTIF"
    log "Also turn on 'Free Tier usage alerts' under Billing -> Billing preferences."
    ;;
  spend)
    step "Month-to-date cost by service (Cost Explorer API call costs about \$0.01)"
    start="$(date -u +%Y-%m-01)"; end="$(date -u -d tomorrow +%Y-%m-%d 2>/dev/null || date -u -v+1d +%Y-%m-%d)"
    run aws ce get-cost-and-usage --time-period Start="$start",End="$end" --granularity MONTHLY \
      --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE \
      --query 'ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount>`0.001`].[Keys[0],Metrics.UnblendedCost.Amount]' --output table
    ;;
  *) die "unknown action '$ACTION' (quotas|running|budget|spend)" ;;
esac
