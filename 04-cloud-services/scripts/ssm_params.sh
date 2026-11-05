#!/usr/bin/env bash
# ssm_params.sh — manage app configuration/secrets in AWS Systems Manager Parameter Store.
# Standard-tier parameters are free; SecureString values are encrypted with the account's KMS key.
# Parameter names: /cloudops/<env>/<KEY>  (the EC2 role may read only this prefix).
#
#   put  KEY VALUE [--secure]   create/overwrite one parameter
#   put-db-secret               generate a random DB password and store it as SecureString
#   get  KEY                    read one (decrypted)
#   list                        show all parameters under the env prefix (values of secrets hidden)
#   export                      print KEY=VALUE lines (used by deploy_app.sh to build app.env)
#
# Usage: ./ssm_params.sh <put|put-db-secret|get|list|export> [...] [--env dev] [--dry-run]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
parse_common_flags "$@"; set -- "${REMAINING[@]}"
ACTION="${1:-}"; [[ -n "$ACTION" ]] || { sed -n '2,12p' "$0"; exit 1; }
aws_preflight
PREFIX="/cloudops/$ENV_NAME"

valid_key() { [[ "$1" =~ ^[A-Z][A-Z0-9_]{1,63}$ ]] || die "KEY must look like DB_PASSWORD (got '$1')"; }

case "$ACTION" in
  put)
    KEY="${2:-}"; VALUE="${3:-}"; TYPE="String"
    [[ -n "$KEY" && -n "$VALUE" ]] || die "usage: put KEY VALUE [--secure]"
    valid_key "$KEY"
    [[ "${4:-}" == "--secure" ]] && TYPE="SecureString"
    # Value passed via --value is fine for the CLI; it never lands in the repo.
    run aws ssm put-parameter --name "$PREFIX/$KEY" --type "$TYPE" --value "$VALUE" --overwrite \
      --output text --query Version
    ;;
  put-db-secret)
    need_cmd openssl
    PASSWORD="$(openssl rand -base64 30 | tr -d '/+=' | cut -c1-32)"
    if [[ "$DRY_RUN" == true ]]; then
      log "+ aws ssm put-parameter --name $PREFIX/DB_PASSWORD --type SecureString --value '<random 32 chars>' --overwrite"
    else
      aws ssm put-parameter --name "$PREFIX/DB_PASSWORD" --type SecureString --value "$PASSWORD" \
        --overwrite --output text --query Version >/dev/null
      log "stored $PREFIX/DB_PASSWORD (SecureString). Not printing it; read with: $0 get DB_PASSWORD"
    fi
    ;;
  get)
    KEY="${2:-}"; [[ -n "$KEY" ]] || die "usage: get KEY"; valid_key "$KEY"
    run aws ssm get-parameter --name "$PREFIX/$KEY" --with-decryption --output text --query Parameter.Value
    ;;
  list)
    run aws ssm get-parameters-by-path --path "$PREFIX" --output table \
      --query 'Parameters[].{Name:Name,Type:Type,Version:Version,LastModified:LastModifiedDate}'
    ;;
  export)
    # KEY=VALUE lines; strip the prefix. Used on the server, not meant to be committed anywhere.
    if [[ "$DRY_RUN" == true ]]; then
      log "+ aws ssm get-parameters-by-path --path $PREFIX --with-decryption ..."
    else
      aws ssm get-parameters-by-path --path "$PREFIX" --with-decryption --output text \
        --query 'Parameters[].[Name,Value]' | while IFS=$'\t' read -r name value; do
          printf '%s=%s\n' "${name##*/}" "$value"
        done
    fi
    ;;
  *) die "unknown action '$ACTION'" ;;
esac
