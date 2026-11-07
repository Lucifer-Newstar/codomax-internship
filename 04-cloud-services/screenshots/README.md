# Screenshots — Module 03

Evidence to capture while running the module. Blur account IDs, public IPs and key names before
committing. Name the files exactly like this so the README links keep working.

| File | What to capture |
|---|---|
| `01-application-running.png` | `http://<public-ip>/` in the browser with *Database: connected* and at least one note |
| `02-cloud-instance.png` | EC2 console: instance `cloudops-web-dev` running, t3.micro, IAM role attached |
| `03-security-groups.png` | SG `cloudops-web` (22 from `/32`, 80 from anywhere) and `cloudops-db` (5432 from `sg-…`) |
| `04-database-connected.png` | RDS console: `cloudops-db-dev` available, *Publicly accessible: No*; terminal: `curl /health/ready` |
| `05-s3-bucket.png` | S3 console: bucket with *Block all public access: On*, `static/` objects |
| `06-ssm-parameters.png` | Parameter Store: `/cloudops/dev/*` with `DB_PASSWORD` as SecureString |
| `07-iam-role.png` | IAM role `cloudops-ec2-role-dev` with inline policy + `AmazonSSMManagedInstanceCore` |
| `08-cloudwatch-logs.png` | Log group `/cloudops/app` showing JSON request lines |
| `09-cloudwatch-alarms.png` | the three alarms in OK state, or the dashboard |
| `10-local-tests.png` | `pytest` output (17 passed) and `shellcheck` clean |
| `11-cleanup.png` | `cleanup.sh` output and `cost_check.sh running` showing nothing left |

Local run on this branch (no AWS account was used while building the module):

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
