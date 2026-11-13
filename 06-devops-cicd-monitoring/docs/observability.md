# Observability basics

**Observability** = being able to answer "what is the system doing and why?" from the data it emits,
without shipping new code. Three signals plus two derived views:

| Signal | What | Here |
|---|---|---|
| **Logs** | discrete events with context | app: one JSON line per request (`request_id`, `path`, `status`, `duration_ms`); nginx access/error; gunicorn errors; `deploy.log` |
| **Metrics** | numbers aggregated over time, cheap to store and alarm on | EC2 CPU/status checks, CloudWatch agent memory/disk, `Http5xx` metric filter, `Availability`/`LatencyMs` from `healthcheck.sh cloudwatch` |
| **Traces** | the path of one request through several components | single service here, so we propagate `X-Request-ID` (generated or passed in) and log it; nginx → app share it, which is the first step toward distributed tracing (OpenTelemetry/X-Ray would be next) |
| **Health checks** | binary "is it working" probes | `/health` liveness (process up) vs `/health/ready` readiness (DB reachable). Docker `HEALTHCHECK` uses liveness; load balancers and the deploy verification use readiness |
| **Availability** | % of time the service answered correctly | `healthcheck.sh watch` keeps a rolling %, the CloudWatch metric lets you compute it per period; 99.9 % = 43 min downtime/month |

## Where logs go

```
container stdout ──(awslogs driver)──▶ CloudWatch log group /cloudops/docker, stream = container name
systemd service  ──(StandardOutput=append:)──▶ /var/log/cloudops/app.log ──(CW agent)──▶ /cloudops/app
```

Local commands:

```bash
docker logs -f --since 10m cloudops-web            # follow one container
docker compose logs -f --tail 100                   # all services, interleaved
docker logs cloudops-web 2>&1 | jq -c 'select(.status >= 500)'   # JSON lines are easy to filter
docker stats                                        # live CPU / memory / net / block io
docker inspect cloudops-web --format '{{json .State.Health}}' | jq   # health history
06-devops-cicd-monitoring/monitoring/docker_stats_snapshot.sh        # all of the above, one screen
```

Cloud commands:

```bash
aws logs tail /cloudops/docker --follow --since 15m --format short
aws cloudwatch get-metric-statistics --namespace CloudOps --metric-name Availability \
  --dimensions Name=Target,Value=http://<ip> --start-time $(date -u -d '-1 day' +%FT%TZ) \
  --end-time $(date -u +%FT%TZ) --period 3600 --statistics Average
aws cloudwatch describe-alarms --state-value ALARM
```

## Alarm design used here

- **Symptom first**: `Http5xx ≥ 5 / 5 min` and `Availability < 1` tell you users are affected.
- **Cause second**: CPU > 70 % and `StatusCheckFailed` explain *why*.
- Every alarm has `treat-missing-data notBreaching` where silence is normal (no 5xx = no data),
  and the status check does not, because silence there means the instance is gone.
- Alarms → SNS e-mail (module 03 `cloudwatch_setup.sh --email`). Keep the number small; alarms you
  ignore are worse than none.
