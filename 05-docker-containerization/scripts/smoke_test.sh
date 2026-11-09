#!/usr/bin/env bash
# smoke_test.sh — end-to-end checks against the compose stack (or any base URL).
#   health, readiness (DB), create/list/delete a note, static file via nginx, security headers.
# Usage: ./smoke_test.sh [base-url]     default http://localhost:8080
set -euo pipefail
BASE="${1:-http://localhost:8080}"
pass=0; fail=0
check() { # name, command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $name"; pass=$((pass+1)); else echo "FAIL  $name"; fail=$((fail+1)); fi
}
json_field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }

echo "Target: $BASE"
check "GET /health is 200"                 curl -fsS --max-time 5 "$BASE/health"
check "GET /health/ready is 200 (db ok)"   curl -fsS --max-time 5 "$BASE/health/ready"
check "GET /nginx-health"                  curl -fsS --max-time 5 "$BASE/nginx-health"
check "static css served"                  curl -fsS --max-time 5 "$BASE/static/style.css"
check "index page has title"               bash -c "curl -fsS '$BASE/' | grep -q 'CloudOps Notes'"
check "security header present"            bash -c "curl -fsSI '$BASE/api/info' | grep -qi 'x-content-type-options: nosniff'"

note_id="$(curl -fsS -X POST "$BASE/api/notes" -H 'content-type: application/json' \
           -d '{"title":"smoke test","body":"created by smoke_test.sh"}' | json_field 'd["id"]' || echo "")"
check "POST /api/notes created id=$note_id" test -n "$note_id"
check "GET /api/notes contains it"         bash -c "curl -fsS '$BASE/api/notes' | grep -q '\"id\":$note_id'"
check "validation: empty title -> 400"     bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -X POST '$BASE/api/notes' -H 'content-type: application/json' -d '{\"title\":\"\"}')\" = 400 ]"
[[ -n "$note_id" ]] && check "DELETE /api/notes/$note_id -> 204" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -X DELETE '$BASE/api/notes/$note_id')\" = 204 ]"

echo; echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
