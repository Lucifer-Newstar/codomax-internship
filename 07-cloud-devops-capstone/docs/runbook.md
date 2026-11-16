# Runbook

## Where things are on the host

| Path | Purpose |
|---|---|
| `/opt/cloudops/docker-compose.yml` | production stack (copy of `docker/docker-compose.prod.yml`) |
| `/opt/cloudops/.env` | secrets + current image tags (root, 0600) |
| `/opt/cloudops/deploy.sh` | what GitHub Actions runs through SSM |
| `/opt/cloudops/healthcheck.sh` | cron every 5 min → CloudWatch `CloudOps/Availability` |
| `/var/log/cloudops/deploy.log`, `healthcheck.log` | deploy history, synthetic checks |
| `/var/log/user-data.log` | first-boot output (bootstrap) |

Get a shell without SSH: `aws ssm start-session --target <instance-id>` then `sudo -i`.

## Daily checks

```bash
# from anywhere
curl -s http://<ip>/health/ready            # {"status":"ok","database":{"ok":true,...}}
curl -s http://<ip>/api/info | jq .git_sha  # what is running
aws cloudwatch describe-alarms --alarm-name-prefix cloudops-capstone --query 'MetricAlarms[].[AlarmName,StateValue]' --output table
aws logs tail /cloudops/capstone --since 30m --format short | grep -v '"status": 200' | tail
# on the host
docker compose -f /opt/cloudops/docker-compose.yml ps
docker stats --no-stream
```

## Incidents

### App returns 502 / UI loads but "API unreachable"
1. `docker compose -f /opt/cloudops/docker-compose.yml ps` — is `backend` healthy?
2. `docker compose … logs backend --tail 100` — look for `ConfigError` or `database connection failed`.
3. Restart just the API: `docker compose … up -d backend`.

### `/health/ready` is 503 (database)
1. `docker compose … logs db --tail 50`; `docker compose … exec db pg_isready -U cloudops`.
2. Disk full? `df -h /`; `docker system prune -f` (images only; never `-a --volumes` in prod).
3. Password mismatch after someone edited `.env`: the volume keeps the original password — restore
   `.env` from the deploy log context or reset the role inside the container.

### Deploy failed in GitHub Actions
- The step summary shows the instance output. `deploy.sh` already rolled back to the previous images.
- Investigate on the host: `tail -100 /var/log/cloudops/deploy.log`.
- Redeploy a known-good build: *Actions → Deploy → Run workflow → image_tag=<previous sha12>*.

### High 5xx alarm
1. `aws logs start-query` with the error-rate query in
   [`06-devops-cicd-monitoring/monitoring/cloudwatch-insights-queries.md`](../../06-devops-cicd-monitoring/monitoring/cloudwatch-insights-queries.md).
2. Correlate with the last deployment (`/api/stats` → `last_deployment`); roll back if it matches.

### Instance unreachable / status check alarm
1. EC2 console → instance → *Monitoring*; try `aws ec2 reboot-instances --instance-ids <id>`.
2. If it stays dead: `infrastructure/scripts/deploy_stack.sh up` recreates it (data on the local
   volume is lost — one more reason to use RDS for real data).

## Routine operations

| Task | How |
|---|---|
| rotate `SECRET_KEY` | edit `/opt/cloudops/.env`, `docker compose … up -d backend` (sessions are not used, so no user impact) |
| rotate DB password | `docker compose … exec db psql -U cloudops -c "ALTER USER cloudops PASSWORD '…'"`, update `.env`, restart backend |
| backup the database | `docker compose … exec db pg_dump -U cloudops cloudops | gzip > /opt/cloudops/backup-$(date +%F).sql.gz` then `aws s3 cp` to the module 03 bucket |
| restore | `gunzip -c backup.sql.gz | docker compose … exec -T db psql -U cloudops cloudops` |
| update the AMI / OS | `sudo dnf -y update && sudo reboot` (containers restart via `unless-stopped`) |
| tear everything down | `infrastructure/scripts/deploy_stack.sh down` (**destructive**) |
