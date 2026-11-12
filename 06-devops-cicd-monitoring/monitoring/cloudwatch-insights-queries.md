# CloudWatch Logs Insights queries for the JSON app log

Log groups: `/cloudops/app` (EC2 + systemd, module 03) or `/cloudops/docker` (containers, module 05 —
stream names are the container names). The app writes one JSON object per request, so fields can be
queried directly.

```sql
-- error rate per 5 minutes
fields @timestamp, status
| filter ispresent(status)
| stats count(*) as requests, sum(status >= 500) as errors, 100 * sum(status >= 500) / count(*) as error_pct by bin(5m)

-- slowest endpoints (p95 latency)
filter ispresent(duration_ms)
| stats pct(duration_ms, 95) as p95_ms, avg(duration_ms) as avg_ms, count(*) as n by path
| sort p95_ms desc

-- requests per client IP in the last hour (abuse check)
filter ispresent(remote_addr) | stats count(*) as n by remote_addr | sort n desc | limit 20

-- follow one request across lines
filter request_id = "caa39e40a19d"

-- database problems
filter message like /database/ and level = "ERROR" | sort @timestamp desc | limit 50

-- deploys (app restarts) over time
filter message like /app started/ | fields @timestamp, @logStream, message
```

Run from the CLI:

```bash
QID=$(aws logs start-query --log-group-name /cloudops/docker \
  --start-time $(date -d '-1 hour' +%s) --end-time $(date +%s) \
  --query-string 'filter ispresent(status) | stats count(*) as n, sum(status>=500) as errors by bin(5m)' \
  --query queryId --output text)
sleep 3; aws logs get-query-results --query-id "$QID" --output table
```
