#!/usr/bin/env bash
# docker_stats_snapshot.sh — one-screen view of the containers for the compose project `cloudops`:
# state + health, resource usage, restart counts, last error lines. Read-only.
# Usage: ./docker_stats_snapshot.sh [project-name]
set -euo pipefail
PROJECT="${1:-cloudops}"
command -v docker >/dev/null || { echo "docker not installed" >&2; exit 1; }
ids="$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")"
[[ -n "$ids" ]] || { echo "no containers for project $PROJECT"; exit 1; }

echo "== containers ($PROJECT) — $(date -Is)"
# shellcheck disable=SC2086
docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'

echo; echo "== live resource usage (docker stats --no-stream)"
# shellcheck disable=SC2086
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}' $ids

echo; echo "== health + restarts (docker inspect)"
for id in $ids; do
  docker inspect "$id" --format '{{.Name}}  health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}  restarts={{.RestartCount}}  started={{.State.StartedAt}}  oom={{.State.OOMKilled}}' | sed 's|^/||'
done

echo; echo "== last failing healthcheck output (if any)"
for id in $ids; do
  docker inspect "$id" --format '{{range .State.Health.Log}}{{if ne .ExitCode 0}}{{.End}} exit={{.ExitCode}} {{.Output}}{{end}}{{end}}' 2>/dev/null | tail -n 2
done

echo; echo "== recent errors in logs (last 200 lines per container)"
for id in $ids; do
  name="$(docker inspect "$id" --format '{{.Name}}' | sed 's|^/||')"
  docker logs --tail 200 "$id" 2>&1 | grep -iE '"level": ?"(ERROR|CRITICAL)"|error|fatal' | tail -n 3 | sed "s|^|$name: |" || true
done
