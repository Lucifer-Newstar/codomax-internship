# Docker fundamentals and command walkthrough

Companion to the module README. Commands were run on Docker Engine 29 / Compose v5 with the
module 03 app as the build context. Output is trimmed.

## 1. Containers vs virtual machines

| | Virtual machine (module 03 EC2) | Container (this module) |
|---|---|---|
| Isolates | whole OS: own kernel, init, drivers | one process tree; shares the host kernel |
| Built from | AMI / ISO, GBs | image layers, tens of MB |
| Starts in | minutes (boot) | milliseconds–seconds |
| Isolation tech | hypervisor (KVM / Nitro) | Linux namespaces (pid, net, mnt, user) + cgroups (cpu, mem) |
| Good for | strong isolation, different kernels | packaging an app with its exact dependencies, dense & reproducible |

They stack: on AWS, containers run *inside* a VM (our EC2 instance, or ECS/EKS nodes).

## 2. Docker architecture

```
docker CLI ──REST over /var/run/docker.sock──▶ dockerd (daemon)
                                                 ├─ containerd ─ runc  (creates the namespaces/cgroups)
                                                 ├─ image store  (layers, overlayfs)
                                                 ├─ networks     (bridge, host, none, user-defined)
                                                 └─ volumes
registry (Docker Hub, GHCR, ECR) ◀── push / pull ──┘
```

- **Image**: read-only, layered filesystem + metadata (CMD, ENV, EXPOSE, USER). Built from a
  `Dockerfile`; each instruction is a layer; unchanged layers are cached.
- **Container**: a running (or stopped) instance of an image with a thin writable layer on top.
  Delete the container → the writable layer is gone; that is why data goes in **volumes**.
- **Registry**: where images are stored and versioned by tag (`postgres:16-alpine`). We pull public
  images from Docker Hub and, in module 05, push ours to GitHub Container Registry.

## 3. The ten commands

```bash
# pull — download an image (tag = version). Alpine variants are smaller.
docker pull postgres:16-alpine
docker pull nginx:1.27-alpine

# build — turn the Dockerfile + build context into an image (run from the repo root)
docker build -f 05-docker-containerization/Dockerfile \
  --build-arg GIT_SHA=$(git rev-parse --short HEAD) -t cloudops-notes:dev 04-cloud-services/app
#   [+] Building 12.4s  … => exporting to image … naming to docker.io/library/cloudops-notes:dev

# images — what is on this machine and how big
docker images
#   REPOSITORY        TAG          SIZE
#   cloudops-notes    dev          59.2MB   (content size; 239MB unpacked on disk)
#   postgres          16-alpine    ~110MB
#   nginx             1.27-alpine  ~50MB
docker history cloudops-notes:dev          # size per layer: find what made the image big

# run — create + start a container. -d background, -p host:container, -e env, --name, --rm
docker run -d --name demo-db -e POSTGRES_PASSWORD=devpass -e POSTGRES_USER=cloudops -e POSTGRES_DB=cloudops postgres:16-alpine
docker run -d --name demo-web -p 8000:8000 --link demo-db:db \
  -e NOTES_STORE=postgres -e DB_HOST=db -e DB_USER=cloudops -e DB_PASSWORD=devpass -e DB_SSLMODE=disable \
  cloudops-notes:dev
curl -s localhost:8000/health/ready        # {"database":{"ok":true,…},"status":"ok"}

# ps — running containers (-a includes stopped). Note the (healthy) status from HEALTHCHECK.
docker ps
#   NAMES      IMAGE               STATUS                   PORTS
#   demo-web   cloudops-notes:dev  Up 20 seconds (healthy)  0.0.0.0:8000->8000/tcp
#   demo-db    postgres:16-alpine  Up 40 seconds            5432/tcp

# logs — stdout/stderr of the container (our app prints one JSON line per request)
docker logs demo-web --tail 20 -f
#   {"time":"…","level":"INFO","logger":"cloudops.access","message":"request","method":"GET","path":"/api/notes","status":200,"duration_ms":8.7,…}

# exec — run a command inside a running container (debugging, psql, a shell)
docker exec -it demo-db psql -U cloudops -d cloudops -c '\dt'
docker exec demo-web id                    # uid=10001(app) — not root
docker exec -it demo-web sh                # /app $  (read-only fs when run via compose)

# stop — SIGTERM, then SIGKILL after 10 s. gunicorn exits cleanly on SIGTERM.
docker stop demo-web demo-db

# rm — remove stopped containers (writable layer deleted; volume data is kept)
docker rm demo-web demo-db
docker rm -f $(docker ps -aq)              # nuke everything (dev machines only)

# rmi — remove images to free disk
docker rmi cloudops-notes:dev
docker image prune -f                      # dangling layers from rebuilds
docker system df                           # disk used by images / containers / volumes
```

## 4. Networking

```bash
docker network ls                          # bridge (default), host, none + compose networks
docker network create demo-net             # user-defined bridge: containers get DNS by name
docker run -d --name db  --network demo-net -e POSTGRES_PASSWORD=x postgres:16-alpine
docker run -d --name web --network demo-net -p 8000:8000 -e DB_HOST=db … cloudops-notes:dev
docker exec web getent hosts db            # 172.18.0.2  db   ← built-in DNS resolves service names
docker network inspect demo-net
```

- **Default bridge** (`docker0`): containers can reach each other by IP only; `--link` is legacy.
- **User-defined bridge** (what Compose creates): automatic DNS, isolation from other networks.
  Our Compose file has two: `edge` (nginx ↔ web, published port) and `backend`
  (web ↔ db, `internal: true` → no route to the internet, no host port).
- `-p 8080:80` publishes a port through iptables NAT on the host. `expose:` only documents a port
  for other containers. **Postgres has no `-p` at all** — it is only reachable from `backend`.
- `--network host` skips the network namespace entirely (Linux only); not used here.

## 5. Volumes

```bash
docker volume ls                           # cloudops_pgdata
docker volume inspect cloudops_pgdata      # Mountpoint: /var/lib/docker/volumes/cloudops_pgdata/_data
docker compose down && docker compose up -d
curl -s localhost:8080/api/notes           # notes are still there ← data outlived the container
docker compose down -v                     # DESTRUCTIVE: also deletes the volume
```

| | Named volume (`pgdata:`) | Bind mount (`./nginx/default.conf:…:ro`) |
|---|---|---|
| Managed by | Docker, under `/var/lib/docker/volumes` | you, any host path |
| Use for | database data, anything the container owns | config files, source code in dev, read-only assets |
| Portability | works the same on Linux/Mac/Windows, backup with `docker run --rm -v cloudops_pgdata:/d -v $PWD:/b alpine tar czf /b/pgdata.tgz -C /d .` | depends on host paths and permissions (SELinux: add `:z`) |

## 6. Environment variables and secrets

- `environment:` in Compose for non-secret config, `env_file: .env` for the rest; `.env` is
  git-ignored and `.env.example` documents every key.
- `${POSTGRES_PASSWORD:?…}` makes Compose refuse to start without the value instead of silently
  using an empty password.
- Nothing secret goes into the image: no `ENV DB_PASSWORD=` lines, `.dockerignore` excludes `.env`.
  Check with `docker history --no-trunc cloudops-notes:dev | grep -i pass` (nothing) and
  `docker inspect cloudops-web --format '{{.Config.Env}}'` (values are visible to anyone who can run
  `docker inspect` — on a shared host prefer Docker secrets: `DB_PASSWORD_FILE=/run/secrets/db_password`
  is already supported by the app).
