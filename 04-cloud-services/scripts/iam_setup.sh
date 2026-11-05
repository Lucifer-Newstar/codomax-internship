#!/usr/bin/env bash
# iam_setup.sh — create the least-privilege IAM role + instance profile for the EC2 instance.
#   role:             cloudops-ec2-role-<env>
#   instance profile: cloudops-ec2-profile-<env>
#   inline policy:    ../aws/iam/ec2-instance-policy.json (placeholders filled in by render_policy)
# Also attaches AmazonSSMManagedInstanceCore so Session Manager / Run Command work without SSH.
#
# Usage: ./iam_setup.sh [--env dev] [--region ap-south-1] [--dry-run]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
parse_common_flags "$@"
aws_preflight

IAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../aws/iam" && pwd)"
ROLE="cloudops-ec2-role-$ENV_NAME"
PROFILE="cloudops-ec2-profile-$ENV_NAME"
ASSET_BUCKET="$(state_get ASSET_BUCKET)"; ASSET_BUCKET="${ASSET_BUCKET:-cloudops-assets-$AWS_ACCOUNT_ID-$ENV_NAME}"
export AWS_REGION AWS_ACCOUNT_ID ENV_NAME ASSET_BUCKET

step "1. Render policy with account/region/bucket"
POLICY_FILE="$(mktemp)"
trap 'rm -f "$POLICY_FILE"' EXIT
render_policy "$IAM_DIR/ec2-instance-policy.json" > "$POLICY_FILE"
python3 -m json.tool "$POLICY_FILE" >/dev/null || die "rendered policy is not valid JSON"
log "policy scoped to: parameters /cloudops/$ENV_NAME/*, bucket $ASSET_BUCKET"

step "2. Role"
if [[ "$DRY_RUN" == false ]] && aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  log "role $ROLE already exists"
else
  run aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document "file://$IAM_DIR/ec2-trust-policy.json" \
    --tags Key=Project,Value="$PROJECT" Key=Env,Value="$ENV_NAME" --output text --query Role.Arn
fi
run aws iam put-role-policy --role-name "$ROLE" --policy-name cloudops-app-access \
  --policy-document "file://$POLICY_FILE"
run aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

step "3. Instance profile"
if [[ "$DRY_RUN" == false ]] && aws iam get-instance-profile --instance-profile-name "$PROFILE" >/dev/null 2>&1; then
  log "instance profile $PROFILE already exists"
else
  run aws iam create-instance-profile --instance-profile-name "$PROFILE" --output text --query InstanceProfile.Arn
  run aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE"
  [[ "$DRY_RUN" == false ]] && { log "waiting 10s for IAM to propagate"; sleep 10; }
fi

state_set IAM_ROLE "$ROLE"
state_set INSTANCE_PROFILE "$PROFILE"
log "done: role=$ROLE profile=$PROFILE (saved to $STATE_FILE)"
