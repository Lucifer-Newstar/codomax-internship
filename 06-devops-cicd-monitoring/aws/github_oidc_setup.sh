#!/usr/bin/env bash
# github_oidc_setup.sh — let GitHub Actions deploy WITHOUT storing AWS keys in GitHub.
#   1. IAM OIDC identity provider for token.actions.githubusercontent.com (one per account)
#   2. role cloudops-github-deploy that only the main branch / production environment of ONE repo can assume
#   3. permissions: ssm:SendCommand on instances tagged Project=cloudops + read the result
# Afterwards set the repo variable AWS_ROLE_ARN to the printed ARN.
#
# Usage: ./github_oidc_setup.sh --repo Lucifer-Newstar/codomax-internship [--region ap-south-1] [--dry-run]
# shellcheck source=04-cloud-services/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../04-cloud-services/scripts/lib" && pwd)/common.sh"
parse_common_flags "$@"; set -- "${REMAINING[@]}"
GITHUB_REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in --repo) GITHUB_REPO="${2:?}"; shift ;; *) die "unknown option $1" ;; esac; shift
done
[[ "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must be owner/name"
aws_preflight
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLE="cloudops-github-deploy"
PROVIDER_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"

render() { sed -e "s|\${AWS_ACCOUNT_ID}|$AWS_ACCOUNT_ID|g" -e "s|\${AWS_REGION}|$AWS_REGION|g" -e "s|\${GITHUB_REPO_OWNER}|${GITHUB_REPO%/*}|g" -e "s|\${GITHUB_REPO_NAME}|${GITHUB_REPO#*/}|g" -e "s|\${GITHUB_REPO}|$GITHUB_REPO|g" "$1"; }
TRUST="$(mktemp)"; PERMS="$(mktemp)"; trap 'rm -f "$TRUST" "$PERMS"' EXIT
render "$HERE/github-oidc-trust-policy.json" > "$TRUST"
render "$HERE/github-deploy-policy.json" > "$PERMS"
python3 -m json.tool "$TRUST" >/dev/null && python3 -m json.tool "$PERMS" >/dev/null

step "1. OIDC provider"
if [[ "$DRY_RUN" == false ]] && aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
  log "provider exists"
else
  # AWS now validates GitHub's cert chain itself; the thumbprint is still required by the API.
  run aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
fi

step "2. Role $ROLE (trusts repo:$GITHUB_REPO main ref + production environment)"
if [[ "$DRY_RUN" == false ]] && aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  run aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "file://$TRUST"
else
  run aws iam create-role --role-name "$ROLE" --assume-role-policy-document "file://$TRUST" \
    --max-session-duration 3600 --tags Key=Project,Value=cloudops --output text --query Role.Arn
fi
run aws iam put-role-policy --role-name "$ROLE" --policy-name cloudops-deploy --policy-document "file://$PERMS"

step "3. Done"
log "Set GitHub repo variable AWS_ROLE_ARN=arn:aws:iam::$AWS_ACCOUNT_ID:role/$ROLE"
log "Plus AWS_REGION=$AWS_REGION, EC2_INSTANCE_ID=<id>, APP_URL=http://<ip>"
