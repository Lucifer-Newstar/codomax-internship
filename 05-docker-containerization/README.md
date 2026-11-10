# Module 04 — Docker & Containerization

**Source code → Dockerfile → Image → Container → Docker Compose → Running application**

The CloudOps Notes app from [`04-cloud-services/app/`](../04-cloud-services/app/) is packaged into
a small non-root image and run as a three-container stack (nginx → gunicorn → PostgreSQL) with a
persistent database volume. Nothing is copied: the Dockerfile and Compose file point at the module
03 app directory as their build context.

## Contents

| Path | What |
|---|---|
| [`Dockerfile`](Dockerfile) | multi-stage build, python 3.12-slim, non-root uid 10001, `HEALTHCHECK` |
| [`.dockerignore`](.dockerignore) | keeps `.env`, tests, caches and `.git` out of the image (copy lives in the app dir, where Docker reads it) |
| [`docker-compose.yml`](docker-compose.yml) | `db` (postgres:16-alpine, named volume), `web`, `nginx`; two networks; healthchecks; restart policies |
| [`nginx/default.conf`](nginx/default.conf) | edge proxy: static files from a read-only mount, the rest to `web:8000` |
| [`.env.example`](.env.example) | all variables Compose needs — copy to `.env` |
| [`scripts/smoke_test.sh`](scripts/smoke_test.sh) | 10 end-to-end checks against the running stack |
| [`docker-commands.md`](docker-commands.md) | containers vs VMs, architecture, the 10 core commands, networking, volumes, env vars |
| [`screenshots/`](screenshots/) | evidence checklist |

## Learning objectives

- Explain containers vs VMs, the Docker daemon/CLI/registry split, images vs containers.
- Write a production-conscious Dockerfile (small base, multi-stage, non-root, no secrets, health check).
- Use the everyday commands: `pull build images run ps logs exec stop rm rmi`.
- Connect containers on user-defined networks and publish only the ports that must be public.
- Keep database data in a volume so it survives `down`/`up` and image upgrades.
- Compose a multi-service app with dependencies, health checks and env-based configuration.

## Technologies

Docker Engine ≥ 24 (tested on 29), Docker Compose v2 (tested on v5), python:3.12-slim,
postgres:16-alpine, nginx:1.27-alpine.

## Prerequisites

- Docker + Compose plugin. AlmaLinux 9:
  ```bash
  sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
  sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo systemctl enable --now docker && sudo usermod -aG docker "$USER"   # log out/in afterwards
  ```
  (Ubuntu: `curl -fsSL https://get.docker.com | sh`.)
- About 500 MB disk for the images. No AWS account needed for this module.

---

## Step-by-step (local execution)

All paths relative to the **repo root** unless noted.

### 1. Build the image

```bash
docker build -f 05-docker-containerization/Dockerfile \
  --build-arg GIT_SHA=$(git rev-parse --short HEAD) \
  -t cloudops-notes:dev 04-cloud-services/app
docker images cloudops-notes            # ~60 MB content
```

Why it is built this way:

| Choice | Reason |
|---|---|
| `python:3.12-slim` base | Debian-based (glibc, psycopg wheels work) but ~5× smaller than the full image |
| two stages | pip and its caches stay in the builder; only `/opt/venv` is copied to the runtime image |
| `COPY requirements.txt` before `COPY . .` | dependency layer is cached until requirements change → rebuilds take seconds |
| `USER app` (uid 10001) | a container escape or RCE does not land as root |
| `HEALTHCHECK` on `/health` | Docker marks the container `unhealthy`; Compose waits for `healthy` before starting nginx |
| no `ENV` with secrets, `.dockerignore` | `docker history` shows every layer to anyone with the image |
| `exec gunicorn` as PID 1 | signals from `docker stop` reach gunicorn → graceful shutdown |

Verify the image:

```bash
docker run --rm cloudops-notes:dev id                   # uid=10001(app)
docker run --rm cloudops-notes:dev ls -a /app           # no .env, no tests/
docker history cloudops-notes:dev                       # layer sizes
hadolint 05-docker-containerization/Dockerfile          # linter, optional
```

### 2. Run a single container (image → container)

```bash
docker run -d --name try-web -p 8000:8000 -e NOTES_STORE=memory cloudops-notes:dev
curl -s localhost:8000/health && docker ps --filter name=try-web
docker logs try-web --tail 5
docker stop try-web && docker rm try-web
```

`NOTES_STORE=memory` runs it without a database — handy for checking the image itself. The real
stack uses Postgres below.

### 3. Run the stack with Compose

```bash
cd 05-docker-containerization
cp .env.example .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 12)/; s/^SECRET_KEY=.*/SECRET_KEY=$(openssl rand -hex 32)/" .env
docker compose config --quiet            # validate the file + variable substitution
docker compose up -d --build
docker compose ps
```

Expected after ~20 s:

```
NAME             IMAGE                STATUS                   PORTS
cloudops-db      postgres:16-alpine   Up 31 seconds (healthy)  5432/tcp
cloudops-web     cloudops-notes:dev   Up 25 seconds (healthy)  8000/tcp
cloudops-nginx   nginx:1.27-alpine    Up 20 seconds (healthy)  0.0.0.0:8080->80/tcp
```

Open <http://localhost:8080>. What the file does, and why:

- **Service dependency**: `web` has `depends_on: db: condition: service_healthy` — it starts only
  after `pg_isready` succeeds, not merely after the db *container* exists. nginx likewise waits for
  `web` to be healthy, so the first request never hits a cold proxy.
- **Networking**: `backend` is `internal: true` (db and web only, no internet, no host port);
  `edge` carries nginx ↔ web and is the only network with a published port (`8080:80`). The app
  reaches the database as `db` — Compose's DNS resolves service names.
- **Persistence**: `pgdata` named volume holds `/var/lib/postgresql/data`; `schema.sql` is bind-mounted
  into `docker-entrypoint-initdb.d/` and runs once when the volume is empty.
- **Config**: everything from `.env` (git-ignored); `POSTGRES_PASSWORD` is required (`:?`).
- **Restart policy**: `unless-stopped` brings the stack back after a reboot or crash but respects
  a manual `docker compose stop`.
- **Hardening on `web`**: `read_only` root fs + `tmpfs /tmp`, `no-new-privileges`, CPU/memory limits.

### 4. Test

```bash
./scripts/smoke_test.sh                   # 10 passed, 0 failed
docker compose logs -f web                # JSON request log
docker compose exec db psql -U cloudops -d cloudops -c 'select id,title from notes;'
docker compose exec web sh -c 'getent hosts db'      # DNS inside the backend network
docker network inspect cloudops_backend --format '{{.Internal}}'   # true
docker stats --no-stream                  # web stays under its 256 MB limit
```

### 5. Prove persistence

```bash
curl -s -X POST localhost:8080/api/notes -H 'content-type: application/json' -d '{"title":"survives recreation"}'
docker compose down                       # removes containers + networks, keeps volumes
docker compose up -d && sleep 15
curl -s localhost:8080/api/notes          # the note is still there
docker volume ls | grep pgdata
```

### 6. Stop / clean up (local, destructive where marked)

```bash
docker compose stop                       # keep everything, just stop
docker compose down                       # remove containers + networks (data kept)
docker compose down -v                    # DESTRUCTIVE: also deletes the database volume
docker rmi cloudops-notes:dev && docker image prune -f
```

## Testing and verification summary

| Check | Command | Result on this branch |
|---|---|---|
| Dockerfile lint | `hadolint Dockerfile` | clean |
| Compose validity | `docker compose config --quiet` | ok |
| Build | `docker build …` | image 59 MB content / 239 MB on disk |
| Non-root, no secrets | `docker run --rm cloudops-notes:dev id`, `ls -a /app` | uid 10001, no `.env`/`tests` |
| Stack health | `docker compose ps` | all three `(healthy)` |
| End-to-end | `scripts/smoke_test.sh` | 10 passed |
| Persistence | down → up → `GET /api/notes` | notes retained |
| DB isolation | `docker network inspect cloudops_backend` | `internal=true`, no published port |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `permission denied … docker.sock` | add yourself to the `docker` group and re-login, or use `sudo` |
| `POSTGRES_PASSWORD … set POSTGRES_PASSWORD in .env` | you skipped `cp .env.example .env` |
| `web` restarts, logs show `ConfigError: SECRET_KEY must be set` | `APP_ENV=production` requires a real `SECRET_KEY` in `.env` |
| `web` unhealthy, `/health/ready` 503 | db still initialising; `docker compose logs db`. Wrong password after changing `.env`? the volume keeps the *old* password → `docker compose down -v` (dev only) |
| `port is already allocated` | change `HTTP_PORT` in `.env` |
| nginx 502 | `web` not healthy yet: `docker compose ps`; `docker compose logs web` |
| schema not created | `docker-entrypoint-initdb.d` runs only on an empty volume; the app also runs `CREATE TABLE IF NOT EXISTS` at start, so check the app logs |
| SELinux `Permission denied` on bind mounts (AlmaLinux) | append `:z` to the bind-mount paths or `chcon -Rt container_file_t ./nginx` |
| image too big | `docker history`, make sure `.dockerignore` is in the **build context** directory |

## Screenshots

See [`screenshots/README.md`](screenshots/README.md).

## Deliverables checklist

- [x] Dockerfile (multi-stage, non-root, health check)
- [x] .dockerignore
- [x] Docker Compose configuration (web + PostgreSQL + nginx)
- [x] Containerized application (builds and runs; same code as module 03)
- [x] Execution instructions (this file)
- [x] Testing commands (`scripts/smoke_test.sh`, table above)
- [x] Screenshots checklist
- [x] Troubleshooting documentation
