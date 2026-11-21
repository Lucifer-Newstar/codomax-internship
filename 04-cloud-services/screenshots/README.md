# Screenshots — Module 03

Evidence to capture while running the module. Blur account IDs, public IPs and key names before
committing. Name the files exactly like this so the README links keep working.

Captured so far (local run, 21 Nov 2026 — app served by gunicorn behind a local edge proxy,
real local PostgreSQL 16):

| File | What to capture | Status |
|---|---|---|
| `01-application-running.png` | the app with *Database: connected* and notes — captured locally (gunicorn + PostgreSQL 16) | ✅ captured |
| `02-cloud-instance.png` | EC2 console: instance `cloudops-web-dev` running, t3.micro, IAM role attached | pending AWS |
| `03-security-groups.png` | SG `cloudops-web` (22 from `/32`, 80 from anywhere) and `cloudops-db` (5432 from `sg-…`) | pending AWS |
| `04-database-connected.png` | RDS console: `cloudops-db-dev` available, *Publicly accessible: No*; terminal: `curl /health/ready` | pending AWS |
| `05-s3-bucket.png` | S3 console: bucket with *Block all public access: On*, `static/` objects | pending AWS |
| `06-ssm-parameters.png` | Parameter Store: `/cloudops/dev/*` with `DB_PASSWORD` as SecureString | pending AWS |
| `07-iam-role.png` | IAM role `cloudops-ec2-role-dev` with inline policy + `AmazonSSMManagedInstanceCore` | pending AWS |
| `08-cloudwatch-logs.png` | Log group `/cloudops/app` showing JSON request lines | pending AWS |
| `09-cloudwatch-alarms.png` | the three alarms in OK state, or the dashboard | pending AWS |
| `10-local-tests.png` | `pytest` output (17 passed against real PostgreSQL) and `shellcheck` clean | ✅ captured |
| `11-cleanup.png` | `cleanup.sh` output and `cost_check.sh running` showing nothing left | pending AWS |

Local run re-recorded on 21 Nov 2026 (Python 3.12, real local PostgreSQL 16.2, no AWS account used):

```
$ cd app && pytest
...........s.....                                                        [100%]
16 passed, 1 skipped
$ TEST_DATABASE_URL=postgresql://cloudops:localdevpass@127.0.0.1:5432/cloudops pytest
.................                                                        [100%]
17 passed
$ shellcheck -x scripts/*.sh scripts/lib/common.sh && echo clean
clean
```
