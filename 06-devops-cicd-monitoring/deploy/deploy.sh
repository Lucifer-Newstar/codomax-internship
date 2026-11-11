#!/usr/bin/env bash
# deploy.sh — runs ON the EC2 instance (installed at /opt/cloudops/deploy.sh by ec2-docker-bootstrap.sh).
# Called by the GitHub Actions deploy workflow through SSM Run Command:
#   sudo /opt/cloudops/deploy.sh ghcr.io/<owner>/cloudops-notes:<tag> <git-sha>
# Pulls the new image, rewrites /opt/cloudops/.env (IMAGE, GIT_SHA), restarts only what changed,
# waits for health and rolls back to the previous image if the new one never becomes healthy.
set -euo pipefail

IMAGE="${1:?usage: deploy.sh <image-ref> [git-sha]}"
GIT_SHA="${2:-unknown}"
DIR=/opt/cloudops
ENV_FILE="$DIR/.env"
COMPOSE=(docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml")
LOG=/var/log/cloudops/deploy.log

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date -Is) deploy $IMAGE sha=$GIT_SHA"

[[ "$EUID" -eq 0 ]] || { echo "run as root"; exit 1; }
[[ "$IMAGE" =~ ^ghcr\.io/[a-z0-9._-]+/cloudops-[a-z-]+:[A-Za-z0-9._-]+$ ]] || { echo "refusing unexpected image ref: $IMAGE"; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE missing — run ec2-docker-bootstrap.sh first"; exit 1; }

set_env() { # KEY VALUE
  if grep -q "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi
}

PREVIOUS="$(sed -n 's/^IMAGE=//p' "$ENV_FILE" | tail -n1)"
echo "previous image: ${PREVIOUS:-none}"

echo "--- pull"
docker pull --quiet "$IMAGE"

echo "--- switch"
set_env IMAGE "$IMAGE"
set_env GIT_SHA "$GIT_SHA"
"${COMPOSE[@]}" up -d --remove-orphans --no-build

echo "--- wait for health"
healthy=false
for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 http://127.0.0.1/health/ready >/dev/null 2>&1; then healthy=true; break; fi
  sleep 3
done

if [[ "$healthy" == true ]]; then
  echo "OK: $(curl -fsS http://127.0.0.1/api/info)"
  docker image prune -f >/dev/null
  echo "=== deploy finished"
else
  echo "FAILED: app not ready. Last logs:"
  "${COMPOSE[@]}" logs --tail 50 web || true
  if [[ -n "$PREVIOUS" && "$PREVIOUS" != "$IMAGE" ]]; then
    echo "--- rolling back to $PREVIOUS"
    set_env IMAGE "$PREVIOUS"
    "${COMPOSE[@]}" up -d --no-build
  fi
  exit 1
fi
