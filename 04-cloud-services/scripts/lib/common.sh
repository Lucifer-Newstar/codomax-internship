#!/usr/bin/env bash
# common.sh — helpers shared by the module 03 AWS scripts. Source it, don't run it.
#
#   source "$(dirname "$0")/lib/common.sh"
#
# Provides: log/warn/die, step, run (dry-run aware), need_cmd, aws_preflight,
# state_get/state_set (small key=value file in .deploy-state/, git-ignored),
# confirm (interactive yes/no), my_ip.

set -euo pipefail

: "${DRY_RUN:=false}"
: "${ENV_NAME:=dev}"
: "${PROJECT:=cloudops}"
STATE_DIR="${STATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.deploy-state}"
STATE_FILE="$STATE_DIR/$ENV_NAME.env"

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$1"; }

# Print the command, run it unless DRY_RUN=true.
run() {
  printf '+ %s\n' "$*"
  if [[ "$DRY_RUN" == false ]]; then
    "$@"
  fi
}

need_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' is required but not installed"
  done
}

# Parse the common flags every script accepts. Call: parse_common_flags "$@"; set -- "${REMAINING[@]}"
REMAINING=()
parse_common_flags() {
  REMAINING=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --env) ENV_NAME="${2:?--env needs a value}"; shift ;;
      --region) AWS_REGION="${2:?--region needs a value}"; export AWS_REGION; shift ;;
      -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) REMAINING+=("$1") ;;
    esac
    shift
  done
  STATE_FILE="$STATE_DIR/$ENV_NAME.env"
}

# Make sure the AWS CLI is configured, we are not root, and a region is set.
aws_preflight() {
  need_cmd aws
  if [[ "$DRY_RUN" == true ]]; then
    AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-123456789012}"
    AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo ap-south-1)}"
    export AWS_ACCOUNT_ID AWS_REGION
    log "dry-run: skipping sts:GetCallerIdentity (account=$AWS_ACCOUNT_ID region=$AWS_REGION)"
    return
  fi
  local identity arn
  identity="$(aws sts get-caller-identity --output json 2>/dev/null)" \
    || die "AWS CLI is not configured. Run 'aws configure' (or set AWS_PROFILE)."
  arn="$(printf '%s' "$identity" | sed -n 's/.*"Arn": *"\([^"]*\)".*/\1/p')"
  AWS_ACCOUNT_ID="$(printf '%s' "$identity" | sed -n 's/.*"Account": *"\([^"]*\)".*/\1/p')"
  [[ "$arn" == *":root" ]] && die "You are using ROOT credentials ($arn). Create an IAM user/role instead."
  AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
  [[ -n "$AWS_REGION" ]] || die "No region set. Use --region ap-south-1 or 'aws configure set region ...'"
  export AWS_ACCOUNT_ID AWS_REGION
  log "AWS identity: $arn"
  log "Account: $AWS_ACCOUNT_ID  Region: $AWS_REGION  Env: $ENV_NAME"
}

# Tiny key=value state store so scripts can find what earlier scripts created.
state_get() { [[ -f "$STATE_FILE" ]] && sed -n "s/^$1=//p" "$STATE_FILE" | tail -n1 || true; }
state_set() {
  mkdir -p "$STATE_DIR"
  touch "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  if grep -q "^$1=" "$STATE_FILE"; then
    sed -i "s|^$1=.*|$1=$2|" "$STATE_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"
  fi
}
state_del() { [[ -f "$STATE_FILE" ]] && sed -i "/^$1=/d" "$STATE_FILE" || true; }

confirm() {
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# Public IP of this laptop, used to restrict SSH to "my IP only".
my_ip() {
  curl -fsS --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]'
}

# Common tags applied to every resource so cost reports can be filtered by Project.
tag_spec() { # usage: tag_spec <resource-type> <Name>
  printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=Project,Value=%s},{Key=Env,Value=%s}]' \
    "$1" "$2" "$PROJECT" "$ENV_NAME"
}

# Fill ${AWS_REGION} ${AWS_ACCOUNT_ID} ${ENV_NAME} ${ASSET_BUCKET} placeholders in a policy template.
render_policy() {
  sed -e "s|\${AWS_REGION}|${AWS_REGION}|g" -e "s|\${AWS_ACCOUNT_ID}|${AWS_ACCOUNT_ID}|g" \
      -e "s|\${ENV_NAME}|${ENV_NAME}|g" -e "s|\${ASSET_BUCKET}|${ASSET_BUCKET:-}|g" "$1"
}
