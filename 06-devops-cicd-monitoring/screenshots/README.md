# Screenshots — Module 05

| File | What to capture |
|---|---|
| `01-branches-and-prs.png` | GitHub branches view / a merged PR with the green CI check |
| `02-ci-pipeline.png` | Actions → CI run: `lint`, `test`, `docker` jobs green |
| `03-ci-tests.png` | `test` job log: `17 passed` with the PostgreSQL service |
| `04-ci-docker.png` | `docker` job log: non-root check and the `/health/ready` JSON |
| `05-cicd-success.png` | Actions → Deploy run: all three jobs green, step summary with instance output |
| `06-ghcr-package.png` | Packages → `cloudops-notes` with sha + latest tags |
| `07-oidc-role.png` | IAM role `cloudops-github-deploy` trust policy showing the `sub` condition |
| `08-deployment-verified.png` | Deploy job "verify deployment health" step + the app in the browser |
| `09-cloudwatch-container-logs.png` | Log group `/cloudops/docker` with the `cloudops-web-*` stream |
| `10-docker-stats.png` | `monitoring/docker_stats_snapshot.sh` output |
| `11-healthcheck.png` | `monitoring/healthcheck.sh once` → 5× ok |

Local validation on this branch:

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
