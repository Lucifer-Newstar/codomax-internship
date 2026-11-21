# Screenshots — Capstone

| File | What to capture | Status |
|---|---|---|
| `01-application-running.png` | the board live on AWS (EC2 public endpoint) with API/DB cards and tasks | ✅ captured (live AWS, 21 Nov 2026) |
| `02-cloud-instance.png` | CloudFormation stack `cloudops-capstone-prod` CREATE_COMPLETE with outputs; EC2 instance | ✅ captured |
| `03-database-connected.png` | `curl /health/ready` + `curl /api/tasks` against the live host | ✅ captured (live AWS) |
| `04-docker-containers.png` | on the host: `docker compose -f /opt/cloudops/docker-compose.yml ps` (3 healthy) | ✅ captured |
| `05-cicd-success.png` | Actions → Deploy run: CI → build & push → deploy, summary with instance output | ✅ captured |
| `06-deployment-verified.png` | verify step output (`running git_sha=… expected=…`) and GHCR packages page | pending real deploy run (repo variables set 21 Nov 2026; runs on next push to `main`) |
| `07-cloudwatch-logs.png` | log group `/cloudops/capstone`, streams `cloudops-capstone-{db,backend,frontend}`, JSON lines | ✅ captured |
| `08-cloudwatch-alarms.png` | the three alarms + `CloudOps/Availability` metric | ✅ captured |
| `09-metrics-endpoint.png` | `curl http://<host>/metrics` against the live host | ✅ captured (live AWS) |
| `12-monitoring-fixed.png` | after fixing the cron PATH + probe list: all 5 probes ok, `Availability=1` published, per-service log streams live | ✅ captured |
| `10-local-tests.png` | `pytest` (backend, 8 passed against a fresh real PostgreSQL DB) and `cfn-lint` | ✅ captured |
| `11-rollback.png` | optional: a failed deploy with the `--- rolling back` lines in `deploy.log` | optional |

Local run re-recorded on 21 Nov 2026 (Python 3.12, real local PostgreSQL 16.2, no AWS account used).
The compose stack could not run in this recording environment (no Docker daemon available), so the
backend ran directly under gunicorn behind a local proxy replicating the nginx edge rules; the
compose evidence (`04-docker-containers`) is captured from the AWS host instead.

Original build-time recording (Docker 29.10, Compose v5.7, on the author's machine):

```
$ cd backend && pytest -q
......s.                                                                 [100%]
$ TEST_DATABASE_URL=postgresql://cloudops:localdevpass@127.0.0.1:5432/cloudops pytest -q
........                                                                 [100%]
$ cd ../docker && docker compose up -d --build && docker compose ps
cloudops-capstone-backend-1    Up 25 seconds (healthy)   8000/tcp
cloudops-capstone-db-1         Up 36 seconds (healthy)   5432/tcp
cloudops-capstone-frontend-1   Up 20 seconds (healthy)   0.0.0.0:8090->8080/tcp
$ curl -s localhost:8090/health/ready
{"database":{"backend":"postgres","ok":true,"server_version":"PostgreSQL 16.16"},"status":"ok"}
$ cfn-lint infrastructure/cloudformation/cloudops-stack.yml && echo ok
ok
```
