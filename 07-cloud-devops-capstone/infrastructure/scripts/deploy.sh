#!/usr/bin/env bash
# deploy.sh — ON the EC2 host (/opt/cloudops/deploy.sh). Invoked by GitHub Actions via SSM:
#   sudo /opt/cloudops/deploy.sh <image-api> <image-ui> <git-sha>
# Pull → update .env → compose up → wait for /health/ready → roll back on failure.
set -euo pipefail
IMAGE_API="${1:?usage: deploy.sh <image-api> <image-ui> [sha]}"
IMAGE_UI="${2:?usage: deploy.sh <image-api> <image-ui> [sha]}"
GIT_SHA="${3:-unknown}"
DIR=/opt/cloudops; ENV_FILE="$DIR/.env"; LOG=/var/log/cloudops/deploy.log
COMPOSE=(docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml")
mkdir -p "$(dirname "$LOG")"; exec > >(tee -a "$LOG") 2>&1
echo "=== $(date -Is) deploy api=$IMAGE_API ui=$IMAGE_UI sha=$GIT_SHA"
[[ "$EUID" -eq 0 ]] || { echo "run as root"; exit 1; }
re='^ghcr\.io/[a-z0-9._-]+/cloudops-(api|ui):[A-Za-z0-9._-]+$'
[[ "$IMAGE_API" =~ $re && "$IMAGE_UI" =~ $re ]] || { echo "refusing unexpected image refs"; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE missing — run bootstrap.sh"; exit 1; }

set_env() { if grep -q "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi; }
PREV_API="$(sed -n 's/^IMAGE_API=//p' "$ENV_FILE" | tail -n1)"
PREV_UI="$(sed -n 's/^IMAGE_UI=//p' "$ENV_FILE" | tail -n1)"

echo "--- pull"; docker pull -q "$IMAGE_API"; docker pull -q "$IMAGE_UI"
echo "--- switch"; set_env IMAGE_API "$IMAGE_API"; set_env IMAGE_UI "$IMAGE_UI"; set_env GIT_SHA "$GIT_SHA"
"${COMPOSE[@]}" up -d --remove-orphans

echo "--- wait for health"
ok=false
for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 http://127.0.0.1/health/ready >/dev/null 2>&1 \
     && curl -fsS --max-time 3 http://127.0.0.1/ | grep -q CloudOps; then ok=true; break; fi
  sleep 3
done
if [[ "$ok" == true ]]; then
  echo "OK: $(curl -fsS http://127.0.0.1/api/info)"; docker image prune -f >/dev/null; echo "=== done"
else
  echo "FAILED — logs:"; "${COMPOSE[@]}" logs --tail 40 backend frontend || true
  if [[ -n "$PREV_API" && ( "$PREV_API" != "$IMAGE_API" || "$PREV_UI" != "$IMAGE_UI" ) ]]; then
    echo "--- rollback to $PREV_API / $PREV_UI"
    set_env IMAGE_API "$PREV_API"; set_env IMAGE_UI "$PREV_UI"; "${COMPOSE[@]}" up -d
  fi
  exit 1
fi
