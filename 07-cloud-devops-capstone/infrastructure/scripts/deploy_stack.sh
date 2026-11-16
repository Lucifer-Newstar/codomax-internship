#!/usr/bin/env bash
# deploy_stack.sh — create/update/delete the capstone CloudFormation stack from your laptop.
#   up      : look up default VPC/subnet + AlmaLinux 9 AMI, create or update the stack, print outputs
#   status  : stack status + outputs
#   down    : DELETE the stack (instance, role, SG, alarms, log group) — asks for confirmation
# Usage: ./deploy_stack.sh <up|status|down> [--env prod] [--email you@x.com] [--key name] [--type t3.micro] [--region ..] [--dry-run]
# shellcheck source=04-cloud-services/scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../04-cloud-services/scripts/lib" && pwd)/common.sh"
ENV_NAME=prod
parse_common_flags "$@"; set -- "${REMAINING[@]}"
ACTION="${1:-}"; shift || true
EMAIL=""; KEY=""; TYPE="t3.micro"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --email) EMAIL="${2:?}"; shift ;; --key) KEY="${2:?}"; shift ;; --type) TYPE="${2:?}"; shift ;;
    *) die "unknown option $1" ;;
  esac; shift
done
[[ -n "$ACTION" ]] || { sed -n '2,6p' "$0"; exit 1; }
aws_preflight
TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../cloudformation" && pwd)/cloudops-stack.yml"
STACK="cloudops-capstone-$ENV_NAME"

case "$ACTION" in
  up)
    step "1. Inputs"
    if [[ "$DRY_RUN" == true ]]; then VPC=vpc-dryrun; SUBNET=subnet-dryrun; AMI=ami-dryrun
    else
      VPC="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
      SUBNET="$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=map-public-ip-on-launch,Values=true --query 'Subnets[0].SubnetId' --output text)"
      arch=x86_64; [[ "$TYPE" == t4g.* ]] && arch=arm64
      AMI="$(aws ec2 describe-images --owners 764336703387 --filters "Name=name,Values=AlmaLinux OS 9*" "Name=architecture,Values=$arch" "Name=state,Values=available" --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)"
      [[ "$VPC" != None && "$SUBNET" != None && "$AMI" != None ]] || die "could not find default vpc/subnet/ami"
    fi
    MYIP="$(my_ip || echo 127.0.0.1)"
    log "vpc=$VPC subnet=$SUBNET ami=$AMI admin=$MYIP/32 type=$TYPE"
    step "2. Validate template"
    run aws cloudformation validate-template --template-body "file://$TEMPLATE" --query Description --output text
    step "3. Deploy stack $STACK (creates: EC2, SG, IAM role, log group, alarms)"
    run aws cloudformation deploy --stack-name "$STACK" --template-file "$TEMPLATE" \
      --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset \
      --tags Project=cloudops Env="$ENV_NAME" \
      --parameter-overrides EnvName="$ENV_NAME" InstanceType="$TYPE" AmiId="$AMI" VpcId="$VPC" \
        SubnetId="$SUBNET" AdminCidr="$MYIP/32" KeyName="$KEY" AlarmEmail="$EMAIL"
    [[ "$DRY_RUN" == true ]] && exit 0
    ;&
  status)
    step "Stack $STACK"
    run aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackStatus' --output text
    run aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
    log "Set GitHub variables EC2_INSTANCE_ID and APP_URL from the outputs. user-data needs ~4 min."
    ;;
  down)
    step "DELETE stack $STACK (instance + data volume are destroyed)"
    if [[ "$DRY_RUN" == false ]]; then confirm "Delete $STACK?" || die aborted; fi
    run aws cloudformation delete-stack --stack-name "$STACK"
    [[ "$DRY_RUN" == false ]] && { log "waiting..."; aws cloudformation wait stack-delete-complete --stack-name "$STACK"; log deleted; }
    ;;
  *) die "unknown action $ACTION" ;;
esac
