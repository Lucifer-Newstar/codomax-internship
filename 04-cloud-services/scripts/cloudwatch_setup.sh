#!/usr/bin/env bash
# cloudwatch_setup.sh — monitoring: log groups with retention, alarms, optional e-mail via SNS.
#   log groups : /cloudops/app, /cloudops/nginx-access, /cloudops/nginx-error (7-day retention)
#   alarms     : CPU > 70% for 10 min, StatusCheckFailed >= 1, app 5xx (metric filter on app log)
#   dashboard  : one small dashboard with CPU, memory (agent) and 5xx count
#
# Usage: ./cloudwatch_setup.sh [--email you@example.com] [--env dev] [--dry-run]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
parse_common_flags "$@"; set -- "${REMAINING[@]}"
EMAIL=""
while [[ $# -gt 0 ]]; do
  case "$1" in --email) EMAIL="${2:?}"; shift ;; *) die "unknown option $1" ;; esac; shift
done
aws_preflight
INSTANCE_ID="$(state_get INSTANCE_ID)"; INSTANCE_ID="${INSTANCE_ID:-i-dryrun}"
[[ "$INSTANCE_ID" != "i-dryrun" || "$DRY_RUN" == true ]] || die "no instance in state — run ec2_launch.sh first"

step "1. Log groups (7-day retention keeps storage cost ~0)"
for lg in /cloudops/app /cloudops/nginx-access /cloudops/nginx-error; do
  if [[ "$DRY_RUN" == false ]] && aws logs describe-log-groups --log-group-name-prefix "$lg" \
       --query "logGroups[?logGroupName=='$lg'] | length(@)" --output text | grep -q '^1$'; then
    log "$lg exists"
  else
    run aws logs create-log-group --log-group-name "$lg" --tags Project="$PROJECT",Env="$ENV_NAME"
  fi
  run aws logs put-retention-policy --log-group-name "$lg" --retention-in-days 7
done

step "2. Optional SNS topic for alarm e-mails"
ALARM_ACTIONS=()
if [[ -n "$EMAIL" ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    TOPIC_ARN="arn:aws:sns:$AWS_REGION:$AWS_ACCOUNT_ID:cloudops-alarms-$ENV_NAME"
    log "+ aws sns create-topic --name cloudops-alarms-$ENV_NAME"
  else
    TOPIC_ARN="$(aws sns create-topic --name "cloudops-alarms-$ENV_NAME" --query TopicArn --output text)"
    aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$EMAIL" >/dev/null
    log "subscription sent to $EMAIL — confirm it from your inbox"
  fi
  ALARM_ACTIONS=(--alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN")
  state_set SNS_TOPIC "$TOPIC_ARN"
else
  log "no --email given: alarms will show in the console only"
fi

step "3. Metric filter: count HTTP 5xx in the app log (JSON field 'status')"
run aws logs put-metric-filter --log-group-name /cloudops/app --filter-name http-5xx \
  --filter-pattern '{ $.status >= 500 }' \
  --metric-transformations metricName=Http5xx,metricNamespace=CloudOps,metricValue=1,defaultValue=0

step "4. Alarms"
run aws cloudwatch put-metric-alarm --alarm-name "cloudops-$ENV_NAME-cpu-high" \
  --namespace AWS/EC2 --metric-name CPUUtilization --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
  --statistic Average --period 300 --evaluation-periods 2 --threshold 70 \
  --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching "${ALARM_ACTIONS[@]}"
run aws cloudwatch put-metric-alarm --alarm-name "cloudops-$ENV_NAME-status-check" \
  --namespace AWS/EC2 --metric-name StatusCheckFailed --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
  --statistic Maximum --period 60 --evaluation-periods 2 --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold "${ALARM_ACTIONS[@]}"
run aws cloudwatch put-metric-alarm --alarm-name "cloudops-$ENV_NAME-http-5xx" \
  --namespace CloudOps --metric-name Http5xx --statistic Sum --period 300 --evaluation-periods 1 \
  --threshold 5 --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching \
  "${ALARM_ACTIONS[@]}"

step "5. Dashboard"
DASH="$(cat <<JSON
{"widgets":[
 {"type":"metric","x":0,"y":0,"width":12,"height":6,"properties":{"title":"CPU %","region":"$AWS_REGION",
  "metrics":[["AWS/EC2","CPUUtilization","InstanceId","$INSTANCE_ID"]],"stat":"Average","period":300}},
 {"type":"metric","x":12,"y":0,"width":12,"height":6,"properties":{"title":"Memory % (agent)","region":"$AWS_REGION",
  "metrics":[["CloudOps","mem_used_percent","InstanceId","$INSTANCE_ID"]],"stat":"Average","period":300}},
 {"type":"metric","x":0,"y":6,"width":12,"height":6,"properties":{"title":"HTTP 5xx","region":"$AWS_REGION",
  "metrics":[["CloudOps","Http5xx"]],"stat":"Sum","period":300}},
 {"type":"log","x":12,"y":6,"width":12,"height":6,"properties":{"title":"Slowest requests","region":"$AWS_REGION",
  "query":"SOURCE '/cloudops/app' | fields @timestamp, method, path, status, duration_ms | sort duration_ms desc | limit 20"}}
]}
JSON
)"
run aws cloudwatch put-dashboard --dashboard-name "cloudops-$ENV_NAME" --dashboard-body "$DASH"
log "done. Console: CloudWatch -> Dashboards -> cloudops-$ENV_NAME"
