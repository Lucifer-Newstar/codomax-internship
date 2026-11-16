# Module 06 — Capstone: CloudOps — Automated Application Deployment and Monitoring Platform

A small, complete, production-shaped application that ties modules 03–05 together:

```
Developer → GitHub → GitHub Actions (test → docker build) → GHCR → OIDC/SSM deploy → EC2 (Docker Compose)
                                                                        ├── frontend  (nginx, static UI)
                                                                        ├── backend   (Flask REST API)
                                                                        └── PostgreSQL
                                                                                ↓
                                                              CloudWatch logs · metrics · alarms · /metrics
```

The **board UI** lets a user create tasks, move them *to do → doing → done* and see live status
cards (API health, database, running build, request/5xx counters, last deployment). The **API** is
the module 03 app grown up: same configuration and logging code, a tasks resource with `PATCH`,
`/api/stats`, a Prometheus-format `/metrics`, and it records every deployment in the database.

**Live URL:** none is published in this repository — the stack was built and verified locally and
the AWS deployment is fully scripted (`infrastructure/`), but no AWS account was attached while
writing it. Once you run `deploy_stack.sh up` and set the GitHub variables, the `Deploy` workflow's
*production* environment shows the URL.

## Contents

| Path | What |
|---|---|
| [`frontend/`](frontend/) | `index.html`, `style.css`, `app.js`, `nginx.conf` (static + same-origin proxy) |
| [`backend/`](backend/) | `cloudops_api/` package (config, db, routes, metrics, logging), `tests/`, requirements |
| [`database/`](database/) | `init.sql` (tasks, deployments), `seed.sql` |
| [`docker/`](docker/) | `Dockerfile.backend`, `Dockerfile.frontend`, `docker-compose.yml` (dev), `docker-compose.prod.yml`, `.env.example` |
| [`infrastructure/`](infrastructure/) | `cloudformation/cloudops-stack.yml`, `scripts/deploy_stack.sh` (laptop), `bootstrap.sh` + `deploy.sh` (host) |
| [`docs/`](docs/) | [architecture](docs/architecture.md) · [runbook](docs/runbook.md) |
| [`/.github/workflows/`](../.github/workflows/) | `ci.yml`, `deploy.yml` (shared with module 05) |
| [`screenshots/`](screenshots/) | evidence checklist + recorded local run |

## Core functionality → where it is implemented

| # | Requirement | Implementation | Verified by |
|---|---|---|---|
| 1 | users access the web app | `frontend/` served by nginx on :80 | `curl / \| grep CloudOps`, CI e2e |
| 2 | app talks to its backend | nginx `location ~ ^/(api\|health\|metrics)` → `backend:8000` | UI status cards, CI e2e |
| 3 | backend talks to PostgreSQL | `cloudops_api/db.py` (psycopg 3), schema from `database/init.sql` | `tests/test_postgres.py`, `/health/ready` |
| 4 | health endpoint | `/health` (liveness), `/health/ready` (DB), container `HEALTHCHECK`s | `tests/test_api.py`, compose `(healthy)` |
| 5 | config via env vars | `cloudops_api/config.py`, `.env.example`, compose `environment:` | `tests` (module 03 config tests cover the same code) |
| 6 | runs through Docker Compose | `docker/docker-compose.yml` | `docker compose up -d --build` |
| 7 | GitHub Actions tests & builds | `ci.yml`: ruff, shellcheck, hadolint, cfn-lint, pytest×2 apps with PostgreSQL, image builds, compose e2e | Actions tab |
| 8 | automated deployment | `deploy.yml`: GHCR push → OIDC → SSM `deploy.sh` → verify sha → rollback | Actions tab, `deploy.log` |
| 9 | health monitored | awslogs → CloudWatch, `Http5xx` filter + alarms (CFN), cron `healthcheck.sh cloudwatch` → `CloudOps/Availability`, `/metrics` | CloudWatch console |

## Technologies

Python 3.12 · Flask 3 · gunicorn · psycopg 3 · PostgreSQL 16 · nginx (unprivileged) · Docker &
Compose · GitHub Actions · GHCR · AWS EC2, IAM (OIDC), SSM, CloudFormation, CloudWatch, SNS.

## Prerequisites

- Local: Docker + Compose (module 04), Python ≥ 3.11 for running tests outside Docker.
- Cloud: everything from module 03's prerequisites (IAM user, CLI, AlmaLinux AMI subscription)
  plus the GitHub OIDC role from module 05 (`06-devops-cicd-monitoring/aws/github_oidc_setup.sh`).

---

## Run locally (local execution)

```bash
cd 07-cloud-devops-capstone/docker
cp .env.example .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 12)/; s/^SECRET_KEY=.*/SECRET_KEY=$(openssl rand -hex 32)/" .env
docker compose up -d --build
docker compose ps                       # db, backend, frontend → (healthy)
```

Open <http://localhost:8080>. Try the API:

```bash
curl -s localhost:8080/health/ready
curl -s -X POST localhost:8080/api/tasks -H 'content-type: application/json' -d '{"title":"Deploy capstone","priority":1}'
curl -s -X PATCH localhost:8080/api/tasks/1 -H 'content-type: application/json' -d '{"status":"doing"}'
curl -s localhost:8080/api/stats
curl -s localhost:8080/metrics | head
docker compose logs -f backend          # JSON request log with request_id
```

Optional demo data: `docker compose exec -T db psql -U cloudops cloudops < ../database/seed.sql`.

Tests and lint (without Docker):

```bash
cd ../backend && python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements-dev.txt
ruff check . && pytest -v                                        # 7 passed, 1 skipped
TEST_DATABASE_URL=postgresql://cloudops:<pw>@localhost:5432/cloudops pytest -v   # 8 passed (needs a local Postgres)
```

Stop: `docker compose down` (keeps data) · `docker compose down -v` (**deletes the database volume**).

## Deploy to AWS (resource provisioning — costs apply outside the free tier)

```bash
# 0. one-time: GitHub OIDC role (module 05)
06-devops-cicd-monitoring/aws/github_oidc_setup.sh --repo Lucifer-Newstar/codomax-internship

# 1. the stack: EC2 + role + SG + log group + alarms (≈ 4 min + 4 min of user-data)
cd 07-cloud-devops-capstone/infrastructure/scripts
./deploy_stack.sh up --email you@example.com          # add --key cloudops-dev to allow SSH from your IP
./deploy_stack.sh status                               # outputs: InstanceId, PublicIp, AppUrl
```

What happens: `deploy_stack.sh` finds the default VPC, a public subnet and the latest AlmaLinux 9
AMI, validates the template and runs `cloudformation deploy`. User-data clones this repository and
runs `bootstrap.sh`: installs Docker + AWS CLI, writes `/opt/cloudops/.env` with generated secrets
(0600, never leaves the host), installs `deploy.sh` and the cron health check, pulls the
`:latest` images from GHCR and starts the stack. After ~8 minutes `AppUrl/health/ready` answers.

```bash
# 2. GitHub → Settings → Secrets and variables → Actions → Variables
AWS_REGION=ap-south-1
AWS_ROLE_ARN=arn:aws:iam::<account>:role/cloudops-github-deploy
EC2_INSTANCE_ID=<InstanceId output>
APP_URL=<AppUrl output>

# 3. merge to main → Actions → Deploy
```

The GHCR packages must be **public** for the host to pull anonymously (Packages → package →
settings → change visibility), or run `docker login ghcr.io` once on the host with a read-only PAT.

Each deployment: CI → build/push `cloudops-api:<sha12>` and `cloudops-ui:<sha12>` → OIDC →
`ssm send-command` → `deploy.sh` pulls, switches, waits for `/health/ready` **and** the UI, rolls
back on failure → the workflow checks `/api/info.git_sha == commit`. The board's *Last deployment*
card updates because the backend records each start-up in the `deployments` table.

Tear down (**destructive**): `./deploy_stack.sh down` — deletes the instance (and its data
volume), role, security group, alarms and log group. Verify with
`04-cloud-services/scripts/cost_check.sh running`.

## Monitoring

| Signal | Where |
|---|---|
| container logs (JSON per request) | CloudWatch `/cloudops/capstone`, streams per container; locally `docker compose logs` |
| 5xx rate | metric filter `Http5xx` → alarm ≥ 5 / 5 min |
| availability | cron `healthcheck.sh cloudwatch` every 5 min → `CloudOps/Availability`, `LatencyMs` |
| host | `StatusCheckFailed`, `CPUUtilization` alarms (SNS e-mail if `--email` was given) |
| app metrics | `GET /metrics` (Prometheus text): requests by route/status, latency histogram, uptime |
| ad-hoc | `06-devops-cicd-monitoring/monitoring/docker_stats_snapshot.sh cloudops-capstone` |

## Testing and verification (what was run on this branch)

| Check | Command | Result |
|---|---|---|
| lint | `ruff check backend`, `shellcheck -x -P SCRIPTDIR:. **/*.sh`, `hadolint docker/Dockerfile.*`, `cfn-lint`, `actionlint` | clean |
| unit tests | `pytest` in `backend/` | 7 passed, 1 skipped |
| integration | `TEST_DATABASE_URL=… pytest` | 8 passed, incl. `/health/ready` → 503 when DB is down |
| images | `docker build` ×2; `id -u` in API container | 10001 (api), 101 (nginx) |
| stack | `docker compose up -d --build`, `docker compose ps` | 3 × healthy |
| end-to-end | UI HTML, `POST/PATCH /api/tasks`, `/api/stats`, `/metrics`, `/style.css` via nginx | all 200/201 |
| isolation | `docker network inspect cloudops-capstone_backend` | `internal: true`, db has no published port |
| secrets | `git ls-files \| grep -E '\.env$'`, `docker history` | nothing committed; no secrets in layers |
| CFN dry run | `deploy_stack.sh up --dry-run` | prints the exact `cloudformation deploy` call |

## Troubleshooting

| Symptom | Fix |
|---|---|
| UI loads, cards red | backend not healthy: `docker compose logs backend`; most often `SECRET_KEY`/`POSTGRES_PASSWORD` missing in `.env` |
| `frontend` restarts with `bind() to 0.0.0.0:80 failed` | you changed the image to plain nginx; the unprivileged image must listen on 8080 (the Dockerfile rewrites it) |
| CI e2e step times out | look at `docker compose logs backend` printed in the job; usually a schema error in `init.sql` |
| `deploy.sh: refusing unexpected image refs` | image names must be `ghcr.io/<owner>/cloudops-api\|ui:<tag>` — check the `REGISTRY` lowercase step |
| stack `ROLLBACK_COMPLETE` | `aws cloudformation describe-stack-events --stack-name cloudops-capstone-prod` — common: AMI not subscribed, `KeyName` does not exist, IAM permission missing |
| `AppUrl` never answers | wait 8 min; then `aws ssm start-session` → `tail -f /var/log/user-data.log` (GHCR pull denied = package is private) |
| Deploy job `AccessDenied` on `SendCommand` | instance lacks tag `Project=cloudops` (the CFN stack sets it) or the role policy was not rendered for this region |

## Deliverables checklist

- [x] Complete GitHub repository (modules 01–07, this branch merged to `main`)
- [x] Functional application (UI + REST API + PostgreSQL)
- [x] Dockerfiles (api, ui) and Docker Compose (dev + prod)
- [x] CI/CD pipeline (`ci.yml`, `deploy.yml`)
- [x] Cloud deployment configuration (CloudFormation + scripts)
- [x] Database integration (schema, migrations-by-idempotent-SQL, integration tests)
- [x] Monitoring implementation (CloudWatch logs/alarms, `/metrics`, synthetic checks)
- [x] Architecture diagram (`docs/architecture.md`)
- [x] README documentation (this file, runbook)
- [x] Screenshots checklist (`screenshots/`)
- [ ] Live deployment URL — not published (no AWS account attached while building; see above)
