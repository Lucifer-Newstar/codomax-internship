# Screenshots — Module 05

| File | What to capture | Status |
|---|---|---|
| `01-branches-and-prs.png` | GitHub branches view with the green CI check on `main` | ✅ captured |
| `02-ci-pipeline.png` | Actions → CI run: `lint`, `test`, `docker` jobs green | ✅ captured |
| `03-ci-tests.png` | `test` job log: `17 passed` with the PostgreSQL service | ✅ captured |
| `04-ci-docker.png` | `docker` job log: non-root check and the `/health/ready` JSON | ✅ captured |
| `05-cicd-success.png` | Actions → Deploy run: all three jobs green, step summary with instance output | ✅ captured |
| `06-ghcr-package.png` | Packages → `cloudops-notes` with sha + latest tags | ✅ captured |
| `07-oidc-role.png` | IAM role `cloudops-github-deploy` trust policy showing the `sub` condition — created with `aws/github_oidc_setup.sh` on 21 Nov 2026 | ✅ captured |
| `08-deployment-verified.png` | Deploy job "verify deployment health" step + the app in the browser | pending real deploy run (repo variables set 21 Nov 2026; runs on next push to `main`) |
| `09-cloudwatch-container-logs.png` | Log group `/cloudops/docker` with the `cloudops-web-*` stream | pending — the capstone stack logs to `/cloudops/capstone` instead (see capstone `07-cloudwatch-logs.png`) |
| `10-docker-stats.png` | `monitoring/docker_stats_snapshot.sh` output | pending AWS |
| `11-healthcheck.png` | `monitoring/healthcheck.sh once` → 5× ok — captured locally against the module-4 app on 21 Nov 2026 | ✅ captured |

Local validation re-recorded on 21 Nov 2026 (against the module-4 app on gunicorn + real PostgreSQL 16.2):

```
$ actionlint && echo ok
ok
$ monitoring/healthcheck.sh once http://localhost:8080
/health        200     1 ms  ok
/health/ready  200     8 ms  ok
/api/notes     200    11 ms  ok
/api/info      200     1 ms  ok
/nope          404     1 ms  ok
```
