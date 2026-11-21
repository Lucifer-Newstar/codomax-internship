# Screenshots — Module 04

Captured 21 Nov 2026 on a real Docker host (EC2 t3.micro, ap-south-1, Docker 29.x) running the
compose stack exactly as documented. The `cloudops-notes:dev` image was pulled from GHCR
(built by the CI pipeline, tag `73533669bbc4`) and re-tagged locally — the t3.micro's 1 GiB of
RAM cannot run a local `docker build` while other stacks are up, so the CI-built image is used
instead. It is the same Dockerfile.

| File | What to capture | Status |
|---|---|---|
| `01-image-built.png` | image pull from GHCR + `docker images cloudops-notes` | ✅ captured |
| `02-image-nonroot.png` | `docker run --rm cloudops-notes:dev id` → uid 10001, `ls -a /app` without `.env`/`tests` | ✅ captured |
| `03-compose-up.png` | `docker compose up -d` followed by `docker compose ps` with all three `(healthy)` | ✅ captured |
| `04-docker-containers.png` | `docker ps` showing only nginx has a published port | ✅ captured |
| `05-application-running.png` | <http://localhost:8080> with *Database: connected* and notes | ✅ captured |
| `06-smoke-test.png` | `scripts/smoke_test.sh` → `10 passed, 0 failed` | ✅ captured |
| `07-logs-exec.png` | `docker compose logs web` (JSON lines) and `docker compose exec db psql … select count(*) from notes` | ✅ captured |
| `08-volume-persistence.png` | note created → `down` → `up` → note still listed; `docker volume ls` | ✅ captured |
| `09-network-isolation.png` | `docker network inspect` (`Internal: true`) | ✅ captured |
| `10-docker-stats.png` | `docker stats --no-stream` | ✅ captured |

Recorded on the AWS host (Docker 29, Compose v2):

```
$ docker compose ps
cloudops-db      postgres:16-alpine   Up (healthy)   5432/tcp
cloudops-nginx   nginx:1.27-alpine    Up (healthy)   0.0.0.0:8080->80/tcp
cloudops-web     cloudops-notes:dev   Up (healthy)   8000/tcp
$ ./scripts/smoke_test.sh
… 10 passed, 0 failed
$ docker inspect cloudops-web --format 'health={{.State.Health.Status}} user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}}'
health=healthy user=app readonly=true
```
