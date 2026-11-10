# Screenshots — Module 04

| File | What to capture |
|---|---|
| `01-image-built.png` | `docker build` final lines and `docker images cloudops-notes` |
| `02-image-nonroot.png` | `docker run --rm cloudops-notes:dev id` → uid 10001, `ls -a /app` without `.env`/`tests` |
| `03-compose-up.png` | `docker compose up -d --build` followed by `docker compose ps` with all three `(healthy)` |
| `04-docker-containers.png` | `docker ps` showing only nginx has a published port |
| `05-application-running.png` | <http://localhost:8080> with *Database: connected* and notes |
| `06-smoke-test.png` | `scripts/smoke_test.sh` → `10 passed, 0 failed` |
| `07-logs-exec.png` | `docker compose logs web` (JSON lines) and `docker compose exec db psql … select count(*) from notes` |
| `08-volume-persistence.png` | note created → `down` → `up` → note still listed; `docker volume ls` |
| `09-network-isolation.png` | `docker network inspect cloudops_backend` (`Internal: true`) |
| `10-docker-stats.png` | `docker stats --no-stream` |

Run on this branch (Docker 29.10, Compose v5.7):

```
$ docker compose ps
cloudops-db      postgres:16-alpine   Up 31 seconds (healthy)   5432/tcp
cloudops-nginx   nginx:1.27-alpine    Up 20 seconds (healthy)   0.0.0.0:8080->80/tcp
cloudops-web     cloudops-notes:dev   Up 25 seconds (healthy)   8000/tcp
$ ./scripts/smoke_test.sh
… 10 passed, 0 failed
$ docker inspect cloudops-web --format 'health={{.State.Health.Status}} user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}}'
health=healthy user=app readonly=true
```
