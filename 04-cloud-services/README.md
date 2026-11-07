# Module 03 — Cloud Services & Web Application Deployment

**Application code → Cloud compute (EC2) → Database/Storage (RDS, S3) → Networking (VPC, SG) → Live web app**

This module introduces **CloudOps Notes**, a small Flask + PostgreSQL app that is reused in every
later module (Docker → CI/CD → capstone). Here it runs the "classic" way: a Linux VM on AWS EC2,
gunicorn behind nginx (same nginx/firewalld/SELinux setup as
[`03-linux-server-deploy/`](../03-linux-server-deploy/)), a managed PostgreSQL on RDS, static
assets in S3, secrets in SSM Parameter Store and logs/alarms in CloudWatch.

## Contents

| Path | What |
|---|---|
| [`app/`](app/) | the Flask app (`cloudops/` package, `tests/`, `schema.sql`, `.env.example`) |
| [`scripts/`](scripts/) | AWS CLI automation — every script supports `--dry-run`, `--env`, `--region`, `--help` |
| [`aws/iam/`](aws/iam/) | least-privilege IAM policies + notes on keys vs roles |
| [`aws/networking.md`](aws/networking.md) | VPC / subnets / routing / security groups with diagrams and CLI examples |
| [`aws/ec2-user-data.sh`](aws/ec2-user-data.sh) | first-boot script for the instance |
| [`aws/systemd/`, `aws/nginx/`](aws/) | service unit and reverse-proxy config installed on the VM |
| [`aws/cloudwatch-agent-config.json`](aws/cloudwatch-agent-config.json) | ships app + nginx logs, memory/disk metrics |
| [`screenshots/`](screenshots/) | evidence checklist |

## Learning objectives

- Launch and reach a cloud VM; understand security groups, key pairs and instance roles.
- Store files in object storage (S3) with a secure default (private + pre-signed URLs).
- Use a managed database (RDS PostgreSQL) and connect with TLS from the app tier only.
- Read the networking layer: VPC, subnets, route tables, internet gateway, SG-to-SG rules.
- Apply IAM least privilege; never use the root account or bake keys into servers.
- Keep configuration in environment variables and secrets in SSM Parameter Store.
- See what the app is doing with CloudWatch logs, metrics, alarms and a dashboard.
- Know what costs money, set a budget, and clean up.

## Technologies

Python 3.11, Flask 3, gunicorn, psycopg 3, PostgreSQL 16 · AWS EC2 (AlmaLinux 9), RDS, S3, VPC,
IAM, SSM Parameter Store, CloudWatch, Budgets · AWS CLI v2, bash.

## Prerequisites

- An AWS account with an **IAM user** (not root) that has the permissions in
  [`aws/iam/developer-policy.json`](aws/iam/developer-policy.json), MFA enabled.
- AWS CLI v2 installed and configured on your laptop: `aws configure` (key, secret, region
  `ap-south-1`, output `json`).
- Local: Python ≥ 3.11, `git`, `curl`, `openssl`. For the local DB: PostgreSQL or Docker.
- AlmaLinux 9 AMI: open it once in AWS Marketplace and click *Subscribe* (free), otherwise
  `run-instances` returns `OptInRequired`.

## Cost note

Everything here is sized for the free tier (t3.micro, db.t3.micro, < 1 GB S3, 7-day log retention).
Free-tier eligibility depends on account age and region — **check Billing → Free Tier** in your
account. The RDS instance is the one resource that costs real money if left running (≈ $0.02/h
outside the free tier). `scripts/cleanup.sh` removes everything.

---

## Part 1 — Run the application locally

```bash
cd 04-cloud-services/app
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env                 # edit if your local Postgres differs
```

Local PostgreSQL (pick one):

```bash
# a) Docker (easiest)
docker run -d --name cloudops-pg -e POSTGRES_USER=cloudops -e POSTGRES_PASSWORD=localdevpass \
  -e POSTGRES_DB=cloudops -p 5432:5432 postgres:16-alpine
# b) AlmaLinux package
sudo dnf install -y postgresql-server && sudo postgresql-setup --initdb && sudo systemctl enable --now postgresql
sudo -u postgres psql -c "CREATE USER cloudops WITH PASSWORD 'localdevpass';" -c "CREATE DATABASE cloudops OWNER cloudops;"
```

Run and test:

```bash
ruff check . && pytest                          # lint + unit tests (in-memory store, no DB needed)
TEST_DATABASE_URL=postgresql://cloudops:localdevpass@localhost:5432/cloudops pytest   # + integration tests
gunicorn --bind 0.0.0.0:8000 wsgi:app           # or: flask --app wsgi run --debug
```

Open <http://localhost:8000>. API check:

```bash
curl -s localhost:8000/health                 # {"status":"ok","uptime_seconds":…}   liveness, no DB
curl -s localhost:8000/health/ready           # {"status":"ok","database":{"ok":true,…}}  readiness, hits DB
curl -s -X POST localhost:8000/api/notes -H 'content-type: application/json' \
     -d '{"title":"first note","body":"from curl"}'
curl -s localhost:8000/api/notes
curl -s localhost:8000/api/info               # version, env, hostname — never secrets
```

Expected test output: `17 passed` (16 + 1 skipped without `TEST_DATABASE_URL`).

### How configuration works

`cloudops/config.py` reads everything from environment variables (a local `.env` is loaded only if
present and never overrides real variables). The DB password can come from `DB_PASSWORD`,
`DB_PASSWORD_FILE` (Docker secrets) or `DB_PASSWORD_SSM_PARAMETER` (fetched with boto3 using the
instance role). Bad values fail at start-up with a clear `ConfigError`. `.env` is git-ignored; only
`.env.example` is committed.

---

## Part 2 — Deploy to AWS

All `scripts/*.sh` run **from your laptop** unless marked *on the instance*. Each one prints every
AWS command it runs, writes IDs to `.deploy-state/<env>.env` (git-ignored) so the next script can find
them, and can be previewed with `--dry-run`.

### Step 0 — Preflight (read-only)

```bash
cd 04-cloud-services/scripts
./aws_preflight.sh
```

Verifies the CLI, refuses root credentials, shows the account/region and a permission probe.

### Step 1 — IAM role for the instance (provisioning, free)

```bash
./iam_setup.sh
```

Creates `cloudops-ec2-role-dev` with [`ec2-instance-policy.json`](aws/iam/ec2-instance-policy.json)
(read `/cloudops/dev/*` parameters, read the assets bucket, write CloudWatch) plus the managed
`AmazonSSMManagedInstanceCore` so Session Manager works. *Why:* the VM gets temporary credentials
from its role; no access keys ever touch the server.

### Step 2 — S3 bucket for static assets (provisioning, ~free)

```bash
./s3_assets.sh create      # private bucket, Block Public Access, versioning, SSE-S3, uploads app/cloudops/static/
./s3_assets.sh presign     # temporary URL to one object — the safe way to share from a private bucket
./s3_assets.sh public      # explains what public access would require and why we don't
aws s3 cp s3://cloudops-assets-<account>-dev/static/style.css /tmp/   # retrieve
```

### Step 3 — EC2 instance (provisioning, free tier / ~$0.01 h)

```bash
./ec2_launch.sh                       # t3.micro; use --type t4g.micro for arm
```

What it does and why: default VPC + public subnet (no NAT cost) → ed25519 key pair saved to
`~/.ssh/cloudops-dev.pem` → security group **SSH only from your current IP, HTTP from anywhere** →
latest official AlmaLinux 9 AMI → `run-instances` with the instance profile, IMDSv2 required, 10 GB
gp3 and [`ec2-user-data.sh`](aws/ec2-user-data.sh) (packages, SSM + CloudWatch agents, firewalld,
`cloudops` user). Wait ~3 minutes for user-data, then:

```bash
ssh -i ~/.ssh/cloudops-dev.pem ec2-user@<public-ip>
sudo tail -f /var/log/user-data.log            # until "user-data finished"
```

No-SSH alternative (uses the role + SSM agent): `aws ssm start-session --target <instance-id>`.

### Step 4 — RDS PostgreSQL (provisioning, free tier 12 months / ~$0.02 h — delete when done)

```bash
./rds_create.sh                       # 5–10 minutes
```

Creates SG `cloudops-db` that allows 5432 **only from the web SG**, generates a 32-char master
password straight into SSM as a `SecureString` (never printed), creates `db.t3.micro` PostgreSQL 16,
encrypted storage, *not* publicly accessible, deletion protection on, then publishes
`DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_SSLMODE` to SSM.

Verify the network rule from your laptop — this **should fail**: `nc -zv -w3 <endpoint> 5432`.

### Step 5 — Configuration & secrets (SSM Parameter Store)

```bash
./ssm_params.sh list                                  # DB_* written by rds_create.sh
./ssm_params.sh put APP_VERSION 1.0.0                 # plain String
./ssm_params.sh put ASSET_BASE_URL https://cloudops-assets-<account>-dev.s3.ap-south-1.amazonaws.com/static  # optional
./ssm_params.sh get DB_PASSWORD                       # decrypts — only you and the instance role can
```

Standard parameters are free. SecureStrings are encrypted with the account's KMS key
(`aws/ssm`). Secrets Manager does the same job with rotation built in, at $0.40/secret/month — not
needed here.

### Step 6 — Deploy the app (*on the instance*)

```bash
# laptop: copy the repo over (or git clone it on the instance)
rsync -az -e "ssh -i ~/.ssh/cloudops-dev.pem" --exclude .git --exclude .venv ../../ ec2-user@<public-ip>:~/codomax-internship/
# instance
ssh -i ~/.ssh/cloudops-dev.pem ec2-user@<public-ip>
cd ~/codomax-internship/04-cloud-services/scripts
sudo ./deploy_app.sh
```

`deploy_app.sh` copies the app to `/opt/cloudops`, builds a venv, writes `/etc/cloudops/app.env`
(root-only, `0600`) from the SSM parameters, installs the systemd unit (runs as `cloudops`, hardened)
and nginx reverse proxy, sets the SELinux boolean `httpd_can_network_connect`, starts the CloudWatch
agent and finally checks `http://127.0.0.1/health/ready`.

Open **`http://<public-ip>/`** — the status card should show *Database: connected (PostgreSQL 16.x)*.

### Step 7 — Monitoring (provisioning, free tier)

```bash
./cloudwatch_setup.sh --email you@example.com      # confirm the SNS e-mail
```

Creates the log groups (7-day retention), a metric filter counting `status >= 500` in the JSON app
log, alarms for CPU > 70 % (10 min), failed status checks and ≥ 5 HTTP 5xx / 5 min, and a dashboard.

Useful views:

```bash
aws logs tail /cloudops/app --follow --format short
aws logs start-query --log-group-name /cloudops/app --start-time $(date -d '-1 hour' +%s) --end-time $(date +%s) \
  --query-string 'fields @timestamp, method, path, status, duration_ms | filter status >= 400 | sort @timestamp desc'
aws cloudwatch describe-alarms --alarm-name-prefix cloudops- --query 'MetricAlarms[].{Name:AlarmName,State:StateValue}'
```

Concepts in one line each: **metrics** = numbers over time (CPU %, 5xx count); **logs** = events
with context (one JSON line per request); **alarms** = a rule on a metric that notifies/acts;
**dashboard** = the metrics you look at first when something is wrong.

### Step 8 — Quotas and cost

```bash
./cost_check.sh quotas                      # vCPU / VPC / EIP / bucket / RDS limits in this region
./cost_check.sh running                     # everything tagged Project=cloudops + orphan EIPs/volumes
./cost_check.sh budget --email you@example.com --amount 5    # alert at 80 % of $5/month
./cost_check.sh spend                       # month-to-date by service (this API call costs ~$0.01)
```

### Step 9 — Cleanup (**destructive**)

```bash
./cleanup.sh                # asks for confirmation; --keep-data keeps the bucket + a final RDS snapshot
./cost_check.sh running     # should show nothing
```

Then check the console once more (EC2, RDS, EBS snapshots, S3) and Billing → Bills.

---

## Testing and verification

| Check | Command | Expect |
|---|---|---|
| unit tests | `pytest` in `app/` | all pass, 1 skipped |
| integration | `TEST_DATABASE_URL=… pytest` | `test_integration_pg.py` passes, `/health/ready` 503 when DB down |
| lint | `ruff check .` / `shellcheck -x scripts/*.sh` | clean |
| scripts | `./<script>.sh --dry-run` | prints the AWS calls, touches nothing |
| policies | `python3 -m json.tool aws/iam/*.json` | valid JSON |
| live app | `curl http://<ip>/health/ready` | `"ok": true` |
| DB private | `nc -zv <rds-endpoint> 5432` from laptop | times out |
| secrets | `grep -r "DB_PASSWORD=" --include=*.env .` | nothing committed; `git status` shows no `.env` |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `OptInRequired` on run-instances | subscribe to the AlmaLinux 9 AMI in Marketplace once |
| `UnauthorizedOperation` | your IAM user lacks the action — compare with `developer-policy.json` |
| SSH timeout | your public IP changed → re-run `ec2_launch.sh` (re-adds the rule) or `authorize-security-group-ingress` with the new `/32` |
| `/health/ready` 503 `connection failed` | RDS still creating, DB SG missing the web-SG rule, or wrong `DB_HOST` in SSM (`./ssm_params.sh list`) |
| `502 Bad Gateway` from nginx | gunicorn not running: `journalctl -u cloudops -n 50`; SELinux: `setsebool -P httpd_can_network_connect 1` |
| `ConfigError: No database configured` | `/etc/cloudops/app.env` missing DB_* — rerun `deploy_app.sh` after `rds_create.sh` |
| CloudWatch log group empty | agent not running: `amazon-cloudwatch-agent-ctl -a status`; file perms on `/var/log/cloudops/app.log` |
| Unexpected bill | `./cost_check.sh running` — look for RDS, unattached EIPs, snapshots |

## Screenshots

See [`screenshots/README.md`](screenshots/README.md) for the list of evidence to capture.

## Deliverables checklist

- [x] Working application (`app/`, 17 tests)
- [x] Deployment scripts (`scripts/`, dry-run capable, shellcheck clean)
- [x] AWS CLI examples (scripts + `aws/networking.md`)
- [x] IAM policy examples (`aws/iam/`)
- [x] Environment configuration (`.env.example`, SSM integration)
- [x] Cloud architecture diagram (`aws/networking.md`)
- [x] Deployment documentation (this file)
- [x] Screenshots checklist (`screenshots/`)
- [x] Cleanup instructions (`scripts/cleanup.sh`)
