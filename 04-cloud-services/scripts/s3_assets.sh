#!/usr/bin/env bash
# s3_assets.sh — object storage demo: a PRIVATE bucket for the app's static assets.
#   create   : bucket (versioning on, public access blocked, SSE-S3), upload app/cloudops/static/
#   upload   : re-sync the static files
#   presign  : generate a temporary URL for one object (safe way to share a private object)
#   public   : print what it WOULD take to make objects public and why we don't
#
# Usage: ./s3_assets.sh <create|upload|presign|public> [--env dev] [--region ..] [--dry-run]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
parse_common_flags "$@"; set -- "${REMAINING[@]}"
ACTION="${1:-}"; [[ -n "$ACTION" ]] || { sed -n '2,8p' "$0"; exit 1; }
aws_preflight

STATIC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../app/cloudops/static" && pwd)"
BUCKET="$(state_get ASSET_BUCKET)"; BUCKET="${BUCKET:-cloudops-assets-$AWS_ACCOUNT_ID-$ENV_NAME}"

create_bucket() {
  step "1. Create private bucket s3://$BUCKET"
  if [[ "$DRY_RUN" == false ]] && aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    log "bucket already exists"
  else
    if [[ "$AWS_REGION" == "us-east-1" ]]; then   # us-east-1 rejects a LocationConstraint
      run aws s3api create-bucket --bucket "$BUCKET"
    else
      run aws s3api create-bucket --bucket "$BUCKET" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi
  fi
  step "2. Block ALL public access (account-level default, enforced per bucket too)"
  run aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  step "3. Versioning + default encryption"
  run aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
  run aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  run aws s3api put-bucket-tagging --bucket "$BUCKET" \
    --tagging "TagSet=[{Key=Project,Value=$PROJECT},{Key=Env,Value=$ENV_NAME}]"
  state_set ASSET_BUCKET "$BUCKET"
  upload_assets
}

upload_assets() {
  step "Upload static assets -> s3://$BUCKET/static/"
  [[ -d "$STATIC_DIR" ]] || die "static dir not found: $STATIC_DIR"
  run aws s3 sync "$STATIC_DIR" "s3://$BUCKET/static/" --delete --cache-control "max-age=3600"
  run aws s3 ls "s3://$BUCKET/static/"
  log "Retrieve a file back:  aws s3 cp s3://$BUCKET/static/style.css /tmp/style.css"
}

presign() {
  step "Pre-signed URL (valid 10 minutes) for static/style.css"
  run aws s3 presign "s3://$BUCKET/static/style.css" --expires-in 600
  log "Anyone with this URL can GET the object until it expires; the bucket stays private."
}

explain_public() {
  cat <<MSG
Public vs private access
------------------------
PRIVATE (what we do):  Block Public Access ON, no bucket policy. Readers must have IAM permission
                       (the EC2 role has s3:GetObject) or a pre-signed URL. Good for configs,
                       uploads, backups, anything with user data.
PUBLIC (static sites): you would (1) disable BlockPublicPolicy, (2) add a bucket policy granting
                       s3:GetObject to Principal "*" on arn:aws:s3:::$BUCKET/static/*, (3) optionally
                       enable static website hosting. Only ever for files that are truly public, and
                       the safer production pattern is CloudFront + Origin Access Control in front of a
                       private bucket. This script deliberately does NOT do it.
MSG
}

case "$ACTION" in
  create)  create_bucket ;;
  upload)  upload_assets ;;
  presign) presign ;;
  public)  explain_public ;;
  *) die "unknown action '$ACTION' (create|upload|presign|public)" ;;
esac
