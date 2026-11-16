# Module 05 — DevOps, CI/CD & Monitoring

**GitHub → Build → Test → Docker → Deploy → Monitor**

The containerized CloudOps Notes app (modules 03–04) now builds, tests and ships itself. Every push
runs the CI pipeline; a merge to `main` publishes the image to GitHub Container Registry and rolls it
out to the EC2 instance through AWS Systems Manager, authenticated with OIDC instead of stored keys.
Logs and health are visible locally (`docker logs/stats/inspect`) and in CloudWatch.

## Contents

| Path | What |
|---|---|
| [`/.github/workflows/ci.yml`](../.github/workflows/ci.yml) | CI: lint → pytest + PostgreSQL service → docker build + smoke test |
| [`/.github/workflows/deploy.yml`](../.github/workflows/deploy.yml) | CD: main only, GHCR push, OIDC → SSM Run Command → health verification, manual rollback |
| [`workflows/`](workflows/) | index + local validation commands for the workflows |
| [`deploy/`](deploy/) | what runs on the instance: `ec2-docker-bootstrap.sh`, `deploy.sh` (with rollback), `docker-compose.prod.yml`, `nginx.conf` |
| [`aws/`](aws/) | GitHub OIDC trust policy, scoped deploy policy, `github_oidc_setup.sh` |
| [`monitoring/`](monitoring/) | `healthcheck.sh`, `docker_stats_snapshot.sh`, awslogs `daemon.json`, Logs Insights queries |
| [`docs/`](docs/) | [git workflow](docs/git-workflow.md) · [pipeline architecture](docs/pipeline.md) · [observability](docs/observability.md) |
| [`screenshots/`](screenshots/) | evidence checklist |

## Learning objectives

- Work with feature branches, pull requests and a consistent commit convention.
- Build a CI pipeline that lints, tests against a real database and builds the Docker image.
- Build a CD pipeline that deploys only from the production branch with no long-lived credentials.
- Verify a deployment automatically and roll back when it fails.
- Read container logs/metrics, understand logs vs metrics vs traces, liveness vs readiness.

## Technologies

GitHub Actions (`actions/checkout`, `setup-python`, `docker/build-push-action`,
`aws-actions/configure-aws-credentials`), GitHub Container Registry, AWS IAM OIDC, SSM Run Command,
CloudWatch Logs (awslogs driver), Docker Compose, ruff, shellcheck, hadolint, actionlint.

## Prerequisites

- Modules 03 and 04 done: an EC2 instance launched with `04-cloud-services/scripts/ec2_launch.sh`
  (it already has the SSM agent, an instance role with CloudWatch permissions and the `Project=cloudops` tag).
- Repository on GitHub with Actions enabled; permission to create repository variables.
- AWS CLI configured locally (IAM user, not root) for the one-time OIDC setup.
- Local: `actionlint`, `yamllint` (optional) to validate workflow files before pushing.

---

## Part A — CI (runs by itself)

Nothing to configure. Push any branch or open a PR and watch *Actions → CI*:

```
lint  ──▶  test (postgres service)  ──▶  docker (build, non-root check, run, /health, compose config)
```

Run the same checks locally before pushing:

```bash
cd 04-cloud-services/app && ruff check . && ruff format --check . && pytest       # unit tests
TEST_DATABASE_URL=postgresql://cloudops:localdevpass@localhost:5432/cloudops pytest  # + integration
cd ../.. && find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 shellcheck -x -P SCRIPTDIR:.
hadolint 05-docker-containerization/Dockerfile && actionlint
docker build -f 05-docker-containerization/Dockerfile -t cloudops-notes:ci 04-cloud-services/app
```

Expected: all green; the `test` job prints `17 passed`, the `docker` job prints the JSON health
responses from the running container.

## Part B — CD (one-time setup, then automatic)

> **Note (after module 06):** `deploy.yml` now ships the capstone's two images (`cloudops-api`,
> `cloudops-ui`) to the host created by the capstone CloudFormation stack
> ([`07-cloud-devops-capstone/infrastructure/`](../07-cloud-devops-capstone/infrastructure/)).
> The files in [`deploy/`](deploy/) are the single-image version used while this module was built;
> they still work for deploying the module 03/04 app by hand with the same mechanism:
> `aws ssm send-command --instance-ids <id> --document-name AWS-RunShellScript --parameters 'commands=["sudo /opt/cloudops/deploy.sh ghcr.io/<owner>/cloudops-notes:<tag> <sha>"]'`.

### B1. Prepare the instance (*on the instance*, provisioning)

```bash
# laptop → instance (rsync the repo or git pull on the instance)
ssh -i ~/.ssh/cloudops-dev.pem ec2-user@<public-ip>
cd ~/codomax-internship/06-devops-cicd-monitoring/deploy
sudo ./ec2-docker-bootstrap.sh ghcr.io/lucifer-newstar/cloudops-notes:latest           # local postgres container
# or, to reuse the RDS from module 03:
sudo ./ec2-docker-bootstrap.sh ghcr.io/lucifer-newstar/cloudops-notes:latest --use-rds
```

Installs Docker, sets the **awslogs** log driver for all containers, copies the production compose
file + `deploy.sh` into `/opt/cloudops`, generates `/opt/cloudops/.env` (0600, never leaves the
box) and performs the first deploy. The GHCR package must be public, or the instance needs a
`docker login ghcr.io` with a read-only PAT (do that once, interactively — not in the repo).

### B2. Allow GitHub to deploy (laptop, provisioning, free)

```bash
cd 06-devops-cicd-monitoring/aws
./github_oidc_setup.sh --repo Lucifer-Newstar/codomax-internship
```

Creates the OIDC provider and role `cloudops-github-deploy`. The trust policy accepts tokens only
from `repo:Lucifer-Newstar/codomax-internship:ref:refs/heads/main`; the permission policy allows
`ssm:SendCommand` only on instances tagged `Project=cloudops` and only with the
`AWS-RunShellScript` document. *Why OIDC:* GitHub proves "this job runs on main of this repo" with
a signed token; AWS hands out credentials that expire in an hour; there is no key to leak or rotate.

### B3. Repository variables (GitHub → Settings → Secrets and variables → Actions → Variables)

| Variable | Example |
|---|---|
| `AWS_REGION` | `ap-south-1` |
| `AWS_ROLE_ARN` | `arn:aws:iam::123456789012:role/cloudops-github-deploy` |
| `EC2_INSTANCE_ID` | `i-0abc…` (from `.deploy-state/dev.env` or the console) |
| `APP_URL` | `http://13.x.x.x` |

Optionally create the `production` environment with *required reviewers* to make every deploy a
manual approval.

### B4. Deploy

Merge a PR into `main` (or push a change under `04-cloud-services/app/`). *Actions → Deploy* shows:

```
Run CI first ──▶ Build & push image to GHCR ──▶ Deploy to EC2 via SSM
                                                  ├─ configure AWS credentials (OIDC)
                                                  ├─ send deploy command → instance pulls, restarts, self-checks
                                                  ├─ wait for the command, show instance output in the summary
                                                  └─ verify: /health/ready 200 and git_sha matches
```

Rollback: *Run workflow* → `image_tag` = an earlier 12-char sha (listed under the repository's
*Packages*). The build is skipped and that image is redeployed.

## Part C — Monitoring

```bash
# local stack (module 04)
docker logs -f cloudops-web                          # JSON request log
docker stats --no-stream                             # CPU / memory per container
docker inspect cloudops-web --format '{{json .State.Health}}' | jq
06-devops-cicd-monitoring/monitoring/docker_stats_snapshot.sh
06-devops-cicd-monitoring/monitoring/healthcheck.sh once http://localhost:8080
06-devops-cicd-monitoring/monitoring/healthcheck.sh watch http://<public-ip> --interval 30

# cloud
aws logs tail /cloudops/docker --follow --format short          # all container stdout
06-devops-cicd-monitoring/monitoring/healthcheck.sh cloudwatch http://<public-ip>   # publishes Availability + LatencyMs
aws cloudwatch describe-alarms --alarm-name-prefix cloudops-     # alarms from module 03
```

Add a cron on the instance for a free synthetic monitor:
`*/5 * * * * /opt/cloudops/healthcheck.sh cloudwatch http://127.0.0.1 >> /var/log/cloudops/healthcheck.log 2>&1`
and an alarm on `CloudOps/Availability < 1` (same pattern as `cloudwatch_setup.sh`).

Concepts are explained in [`docs/observability.md`](docs/observability.md).

## Testing and verification

| Check | Command | Result on this branch |
|---|---|---|
| workflow syntax | `actionlint` | clean |
| scripts | `shellcheck -x -P SCRIPTDIR:. **/*.sh` | clean |
| prod compose | `IMAGE=… POSTGRES_PASSWORD=x SECRET_KEY=y docker compose -f deploy/docker-compose.prod.yml config --quiet` | ok |
| health checker | `monitoring/healthcheck.sh once http://localhost:8080` | 5/5 ok |
| snapshot | `monitoring/docker_stats_snapshot.sh` | three healthy containers, 0 restarts |
| CI | push → Actions | lint, test, docker green (see screenshots) |
| CD | merge to main with variables set | summary shows instance output + "Deployed … ✅" |

## Troubleshooting

| Symptom | Fix |
|---|---|
| CI `test` job: `connection refused` | the postgres service is not healthy yet — the health options are in the workflow; check `services:` logs |
| `docker` job: `/app/.env exists` | something copied a `.env` into the build context; check `.dockerignore` is in `04-cloud-services/app` |
| Deploy: `AWS_ROLE_ARN … not set — skipping` | set the four repository *variables* |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | branch is not `main`, or repo name differs from the trust policy → rerun `github_oidc_setup.sh --repo` |
| `InvalidInstanceId` from `send-command` | SSM agent not running / instance missing the `Project=cloudops` tag / wrong region |
| instance: `denied: ghcr.io` | package is private → make it public (Packages → settings) or `docker login ghcr.io` on the instance once |
| verify step: `git_sha` mismatch | an old container kept running: on the instance `docker compose -f /opt/cloudops/docker-compose.yml ps`, check `deploy.log` |
| no logs in `/cloudops/docker` | instance role lacks `logs:*` or `daemon.json` not applied (`systemctl restart docker`) |

## Screenshots

See [`screenshots/README.md`](screenshots/README.md).

## Deliverables checklist

- [x] GitHub Actions CI workflow (`ci.yml`)
- [x] GitHub Actions CD workflow (`deploy.yml`, main-only, OIDC, GHCR)
- [x] Docker integration (image build in CI, GHCR push in CD, prod compose on the instance)
- [x] Automated tests (pytest unit + integration with PostgreSQL service)
- [x] Deployment verification (health + sha check, rollback on failure)
- [x] Monitoring configuration (`monitoring/`, awslogs driver, CloudWatch metrics)
- [x] Pipeline architecture diagram (`docs/pipeline.md`)
- [x] Execution documentation (this file, `docs/`)
