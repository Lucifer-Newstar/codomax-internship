#!/usr/bin/env bash
# healthcheck.sh — synthetic monitor: probe the app like a user would and report availability.
#   once   : probe liveness, readiness, api; print latency; exit 1 if anything fails (use in cron/CI)
#   watch  : loop every N seconds, keep a rolling availability % and log state changes
#   cloudwatch : like once, but also publish Availability (0/1) and LatencyMs to CloudWatch
#                namespace CloudOps (needs cloudwatch:PutMetricData — the EC2 role has it)
# Usage: ./healthcheck.sh [once|watch|cloudwatch] [base-url] [--interval 30]
# Probes default to the CloudOps Notes routes; override with PROBES for other apps, e.g. the
# capstone: PROBES="/health 200 /health/ready 200 /api/tasks 200 /api/info 200 /metrics 200"
set -euo pipefail
# cron gives a minimal PATH; aws/curl live in /usr/local/bin on the EC2 host
PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
MODE="${1:-once}"; BASE="${2:-http://localhost:8080}"; INTERVAL=30
[[ "${3:-}" == "--interval" ]] && INTERVAL="${4:-30}"
PROBES="${PROBES:-/health 200 /health/ready 200 /api/notes 200 /api/info 200 /nope 404}"
need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need curl

probe() { # path expected-code -> prints "code latency_ms"
  local out
  out="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 5 "$BASE$1" || echo "000 5")"
  awk -v want="$2" '{printf "%s %d %s\n", $1, $2*1000, ($1==want?"ok":"FAIL")}' <<<"$out"
}

run_once() {
  local fails=0 total_ms=0 line code ms status
  # shellcheck disable=SC2086  # intentional word-split of PROBES into "path code" pairs
  set -- $PROBES
  while [[ $# -ge 2 ]]; do
    local path="$1" want="$2"; shift 2
    line="$(probe "$path" "$want")"; read -r code ms status <<<"$line"
    printf '%-14s %s  %4d ms  %s\n' "$path" "$code" "$ms" "$status"
    [[ "$status" == ok ]] || fails=$((fails+1))
    total_ms=$((total_ms+ms))
  done
  AVAIL=$(( fails == 0 ? 1 : 0 )); LAT=$total_ms
  return $fails
}

case "$MODE" in
  once)
    echo "$(date -Is) target=$BASE"; run_once ;;
  watch)
    ok=0; n=0; last=""
    while true; do
      n=$((n+1))
      if run_once >/tmp/hc.$$ 2>&1; then state=UP; ok=$((ok+1)); else state=DOWN; fi
      if [[ "$state" != "$last" ]]; then echo "$(date -Is) state changed -> $state"; cat /tmp/hc.$$; last="$state"; fi
      printf '\r%s %s availability=%d/%d (%.1f%%)   ' "$(date +%T)" "$state" "$ok" "$n" "$(awk -v o=$ok -v n=$n 'BEGIN{print 100*o/n}')"
      sleep "$INTERVAL"
    done ;;
  cloudwatch)
    need aws
    run_once || true
    aws cloudwatch put-metric-data --namespace CloudOps --metric-data \
      "MetricName=Availability,Value=$AVAIL,Unit=None,Dimensions=[{Name=Target,Value=$BASE}]" \
      "MetricName=LatencyMs,Value=$LAT,Unit=Milliseconds,Dimensions=[{Name=Target,Value=$BASE}]"
    echo "published Availability=$AVAIL LatencyMs=$LAT to CloudWatch (namespace CloudOps)"
    [[ $AVAIL -eq 1 ]] ;;
  *) echo "usage: $0 [once|watch|cloudwatch] [base-url] [--interval N]" >&2; exit 2 ;;
esac
