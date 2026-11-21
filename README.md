# Codomax Linux, Cloud & DevOps Internship

Hands-on notes, scripts, applications and pipelines from my internship tasks at **Codomax**.
Modules 1–3 were done on **AlmaLinux 9** (RHEL-compatible: `dnf`, `firewalld`, `systemctl`,
SELinux) with Ubuntu equivalents noted; modules 4–7 add AWS, Docker, GitHub Actions and a capstone
project. One application — **CloudOps Notes → CloudOps board** — evolves through modules 4–7
instead of four separate exercises.

## Learning roadmap

```
Linux CLI ─▶ Networking ─▶ Linux server deploy ─▶ Cloud infrastructure (AWS)
                                                        │
                                                        ▼
                                         Web application deployment (EC2 + RDS + S3)
                                                        │
                                                        ▼
                                              Docker containerization
                                                        │
                                                        ▼
                                          CI/CD automation (GitHub Actions)
                                                        │
                                                        ▼
                                          Monitoring & observability (CloudWatch)
                                                        │
                                                        ▼
                                 Integrated Cloud & DevOps capstone (CloudOps platform)
```

| # | Module | Folder | Status |
|---|---|---|---|
| 1 | Linux CLI: files/permissions, users, groups, processes, services, SSH keys | [`01-linux-cli/`](01-linux-cli/) | done |
| 2 | Networking: IP addressing, DNS, ports, firewalls, security groups | [`02-networking/`](02-networking/) | done |
| 3 | Deploy a Linux server: VM → configure → secure → nginx → test | [`03-linux-server-deploy/`](03-linux-server-deploy/) | done |
| 4 | **Cloud services & web app deployment** — EC2, S3, RDS, VPC, IAM, CloudWatch, SSM secrets, cost control; the Flask + PostgreSQL app goes live on AWS | [`04-cloud-services/`](04-cloud-services/) | done |
| 5 | **Docker & containerization** — multi-stage non-root image, compose stack (nginx → app → PostgreSQL), volumes, networks | [`05-docker-containerization/`](05-docker-containerization/) | done |
| 6 | **DevOps, CI/CD & monitoring** — GitHub Actions CI (lint, tests with PostgreSQL, image), CD via OIDC + SSM with rollback, container logs, CloudWatch | [`06-devops-cicd-monitoring/`](06-devops-cicd-monitoring/) | done |
| 7 | **Capstone: CloudOps platform** — UI + REST API + PostgreSQL, Docker Compose, CloudFormation, CI/CD, monitoring, runbook | [`07-cloud-devops-capstone/`](07-cloud-devops-capstone/) | done (deployed live on AWS and verified 21 Nov 2026, then torn down for cost; evidence in `07-cloud-devops-capstone/screenshots/`) |

CI status for this repository: *Actions → CI*. The `Deploy` workflow runs on `main` and skips the
AWS step until the repository variables are set (see module 6).

## Repo map

```
codomax-internship/
├── 01-linux-cli/                 notes.md + scripts (user_setup, permissions_demo, process_monitor, ssh_key_setup)
├── 02-networking/                notes.md, security-group-example.json, scripts (firewall_setup, dns_check, port_check)
├── 03-linux-server-deploy/       steps.md, scripts (provision, harden_ssh, test_connectivity), site/, screenshots/
├── 04-cloud-services/
│   ├── app/                      CloudOps Notes: Flask + psycopg, /health, /health/ready, /api/notes, JSON logs, tests
│   ├── scripts/                  aws_preflight, iam_setup, s3_assets, ec2_launch, rds_create, ssm_params,
│   │                             cloudwatch_setup, deploy_app (on instance), cost_check, cleanup — all --dry-run
│   ├── aws/                      iam/ policies, networking.md (VPC diagram + CLI), user-data, systemd, nginx, CW agent
│   └── README.md
├── 05-docker-containerization/
│   ├── Dockerfile  .dockerignore  docker-compose.yml  nginx/  scripts/smoke_test.sh  docker-commands.md
│   └── README.md
├── 06-devops-cicd-monitoring/
│   ├── workflows/                index of the real workflows in .github/workflows
│   ├── deploy/                   single-image host bootstrap + deploy.sh + prod compose (awslogs)
│   ├── aws/                      GitHub OIDC trust/permission policies + setup script
│   ├── monitoring/               healthcheck.sh, docker_stats_snapshot.sh, daemon.json, Logs Insights queries
│   ├── docs/                     git-workflow.md, pipeline.md, observability.md
│   └── README.md
├── 07-cloud-devops-capstone/
│   ├── frontend/  backend/  database/  docker/  infrastructure/  docs/  screenshots/
│   └── README.md
├── .github/workflows/
│   ├── ci.yml                    lint → pytest (2 apps × PostgreSQL service) → docker builds → compose e2e
│   └── deploy.yml                main only: GHCR push → OIDC → SSM deploy → health + sha verification
├── .gitignore  LICENSE  README.md
```

## Quick start

```bash
git clone https://github.com/Lucifer-Newstar/codomax-internship.git && cd codomax-internship

# modules 1–3 (on an AlmaLinux VM) — see 03-linux-server-deploy/steps.md
# module 4 app locally
cd 04-cloud-services/app && python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements-dev.txt && pytest
# module 5 stack
cd ../../05-docker-containerization && cp .env.example .env && docker compose up -d --build && ./scripts/smoke_test.sh
# module 7 capstone
cd ../07-cloud-devops-capstone/docker && cp .env.example .env && docker compose up -d --build   # http://localhost:8080
```

Cloud steps (EC2/RDS/S3, CloudFormation, OIDC) are in each module's README and are explicit about
what provisions resources, what costs money and how to clean up. No credentials or `.env` files are
committed; secrets live in SSM Parameter Store or on the host.

## Git workflow

One branch per module (`feature/04-cloud-services`, `feature/05-docker-containerization`,
`feature/06-devops-cicd-monitoring`, `feature/07-cloud-devops-capstone`), merged into `main` with
`--no-ff` when the module is complete. Commit convention: `<scope>: <change>` — see
[`06-devops-cicd-monitoring/docs/git-workflow.md`](06-devops-cicd-monitoring/docs/git-workflow.md).

## Skills learned

- **Linux CLI:** navigation, file operations, `find`/`grep`, pipes and redirection
- **Permissions:** `chmod` (octal + symbolic), `chown`, `umask`, SUID/SGID/sticky bit
- **Users & groups:** `useradd`, `usermod -aG`, `groupadd`, `wheel` and `visudo`/sudoers drop-ins
- **Processes:** `ps`, `top`, signals, `kill`, `nice`/`renice`, background jobs
- **Services:** `systemctl` (enable/start/status), `journalctl`, writing a basic unit file
- **SSH:** ed25519 keys, `authorized_keys` permissions, key-only login, `sshd_config.d` drop-ins
- **Networking:** IPv4, CIDR, subnetting a /24 into /26s, private ranges, NAT
- **DNS:** record types, `/etc/hosts` vs `/etc/resolv.conf`, `dig`/`nslookup`
- **Ports & firewalls:** `ss -tulnp`, `nc`, firewalld zones/services/rich rules, SELinux port labels
- **Cloud security:** security groups (stateful) vs NACLs (stateless), least-privilege inbound rules
- **Deployment:** VM setup, hardening, nginx, SELinux file contexts, connectivity testing
- **AWS:** EC2 (AMI, key pairs, instance roles, IMDSv2), S3 (private buckets, pre-signed URLs), RDS PostgreSQL, VPC/subnets/routing, IAM least privilege & OIDC, SSM Parameter Store + Run Command, CloudWatch logs/metrics/alarms/dashboards, Budgets, CloudFormation
- **Application:** Flask app factory, env-based config, health vs readiness, structured JSON logging, request IDs, Prometheus-style metrics, pytest unit + integration tests
- **Docker:** multi-stage builds, non-root images, health checks, `.dockerignore`, user-defined/internal networks, named volumes, Compose dependencies and resource limits
- **CI/CD:** GitHub Actions jobs/matrices/services/artifacts, reusable workflows, GHCR, keyless AWS auth, deployment verification and rollback
- **Observability:** logs vs metrics vs traces, synthetic monitoring, alarm design, Logs Insights

## License

[MIT](LICENSE) © 2026 Navin Jairam M
