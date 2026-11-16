# Screenshots — Capstone

| File | What to capture |
|---|---|
| `01-application-running.png` | the board at `http://<public-dns>/` with green API/DB cards and a few tasks |
| `02-cloud-instance.png` | CloudFormation stack `cloudops-capstone-prod` CREATE_COMPLETE with outputs; EC2 instance |
| `03-database-connected.png` | `curl /health/ready` + `curl /api/stats` from a terminal |
| `04-docker-containers.png` | on the host: `docker compose -f /opt/cloudops/docker-compose.yml ps` (3 healthy) |
| `05-cicd-success.png` | Actions → Deploy run: CI → build & push → deploy, summary with instance output |
| `06-deployment-verified.png` | verify step output (`running git_sha=… expected=…`) and GHCR packages page |
| `07-cloudwatch-logs.png` | log group `/cloudops/capstone`, stream `cloudops-capstone-backend-1`, JSON lines |
| `08-cloudwatch-alarms.png` | the three alarms + `CloudOps/Availability` metric graph |
| `09-metrics-endpoint.png` | `curl http://<ip>/metrics` |
| `10-local-tests.png` | `pytest` (backend) and `docker compose up` locally |
| `11-rollback.png` | optional: a failed deploy with the `--- rolling back` lines in `deploy.log` |

Local run recorded while building this module (Docker 29.10, Compose v5.7, no AWS account used):

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
