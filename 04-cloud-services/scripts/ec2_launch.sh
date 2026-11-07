#!/usr/bin/env bash
# ec2_launch.sh — launch ONE small EC2 instance for the app (compute + networking demo).
#   1. find the default VPC + a public subnet (no new VPC = no NAT gateway charges)
#   2. key pair  cloudops-<env>  (private key saved to ~/.ssh, never in the repo)
#   3. security group: SSH 22 from MY IP only, HTTP 80 from anywhere
#   4. run-instances: t3.micro, AlmaLinux 9 AMI, instance profile from iam_setup.sh, user-data
#   5. wait until running, print public IP
# Idempotent: re-running reuses the key pair / SG and refuses to launch a second instance.
#
# Usage: ./ec2_launch.sh [--type t3.micro] [--env dev] [--region ap-south-1] [--dry-run]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
parse_common_flags "$@"; set -- "${REMAINING[@]}"
INSTANCE_TYPE="t3.micro"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) INSTANCE_TYPE="${2:?}"; shift ;;
    *) die "unknown option $1" ;;
  esac; shift
done
case "$INSTANCE_TYPE" in
  t2.micro|t3.micro|t3.small|t4g.micro) ;;
  *) die "refusing instance type $INSTANCE_TYPE — keep it small (t2.micro/t3.micro/t3.small/t4g.micro)" ;;
esac
aws_preflight
need_cmd curl

USER_DATA="$(cd "$(dirname "${BASH_SOURCE[0]}")/../aws" && pwd)/ec2-user-data.sh"
KEY_NAME="cloudops-$ENV_NAME"
KEY_FILE="$HOME/.ssh/$KEY_NAME.pem"
SG_NAME="cloudops-web-$ENV_NAME"
PROFILE="$(state_get INSTANCE_PROFILE)"
[[ -n "$PROFILE" || "$DRY_RUN" == true ]] || die "no instance profile in state — run ./iam_setup.sh first"
PROFILE="${PROFILE:-cloudops-ec2-profile-$ENV_NAME}"

if [[ -n "$(state_get INSTANCE_ID)" && "$DRY_RUN" == false ]]; then
  state_inst="$(state_get INSTANCE_ID)"
  status="$(aws ec2 describe-instances --instance-ids "$state_inst" \
            --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo gone)"
  [[ "$status" == "terminated" || "$status" == "gone" ]] || die "instance $state_inst already exists ($status). Run cleanup.sh first."
fi

step "1. Default VPC and a public subnet"
if [[ "$DRY_RUN" == true ]]; then
  VPC_ID="vpc-dryrun"; SUBNET_ID="subnet-dryrun"; AMI_ID="ami-dryrun"
else
  VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
  [[ "$VPC_ID" != "None" ]] || die "no default VPC in $AWS_REGION (create one: aws ec2 create-default-vpc)"
  SUBNET_ID="$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" Name=map-public-ip-on-launch,Values=true \
               --query 'Subnets[0].SubnetId' --output text)"
  [[ "$SUBNET_ID" != "None" ]] || die "no public subnet found in $VPC_ID"
  log "vpc=$VPC_ID subnet=$SUBNET_ID"
fi

step "2. Key pair $KEY_NAME"
if [[ "$DRY_RUN" == false ]] && aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  log "key pair exists (private key should be at $KEY_FILE)"
else
  mkdir -p "$HOME/.ssh"
  if [[ "$DRY_RUN" == true ]]; then
    log "+ aws ec2 create-key-pair --key-name $KEY_NAME --key-type ed25519 > $KEY_FILE"
  else
    aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 --key-format pem \
      --tag-specifications "$(tag_spec key-pair "$KEY_NAME")" \
      --query KeyMaterial --output text > "$KEY_FILE"
    chmod 400 "$KEY_FILE"
    log "private key saved to $KEY_FILE (chmod 400)"
  fi
fi

step "3. Security group $SG_NAME"
MY_IP="$(my_ip || true)"; [[ -n "$MY_IP" ]] || die "could not detect my public IP"
if [[ "$DRY_RUN" == true ]]; then
  SG_ID="sg-dryrun"
  log "+ aws ec2 create-security-group --group-name $SG_NAME --vpc-id $VPC_ID"
else
  SG_ID="$(aws ec2 describe-security-groups --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
           --query 'SecurityGroups[0].GroupId' --output text)"
  if [[ "$SG_ID" == "None" ]]; then
    SG_ID="$(aws ec2 create-security-group --group-name "$SG_NAME" --vpc-id "$VPC_ID" \
             --description "CloudOps web: ssh from my ip, http from anywhere" \
             --tag-specifications "$(tag_spec security-group "$SG_NAME")" --query GroupId --output text)"
  fi
  log "sg=$SG_ID"
fi
# Stateful rules: replies are allowed automatically, outbound is open by default.
run aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MY_IP/32,Description=ssh-from-my-ip}]" \
  "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=http}]" \
  --output text --query 'Return' || log "(rules already present)"

step "4. Latest AlmaLinux 9 AMI (official publisher account 764336703387)"
if [[ "$DRY_RUN" == false ]]; then
  arch="x86_64"; [[ "$INSTANCE_TYPE" == t4g.* ]] && arch="arm64"
  AMI_ID="$(aws ec2 describe-images --owners 764336703387 \
            --filters "Name=name,Values=AlmaLinux OS 9*" "Name=architecture,Values=$arch" "Name=state,Values=available" \
            --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)"
  [[ "$AMI_ID" != "None" ]] || die "AlmaLinux 9 AMI not found in $AWS_REGION (accept it once in Marketplace)"
fi
log "ami=$AMI_ID type=$INSTANCE_TYPE"

step "5. Launch"
if [[ "$DRY_RUN" == true ]]; then
  log "+ aws ec2 run-instances --image-id $AMI_ID --instance-type $INSTANCE_TYPE --key-name $KEY_NAME --security-group-ids $SG_ID --subnet-id $SUBNET_ID --iam-instance-profile Name=$PROFILE --user-data file://$USER_DATA"
  exit 0
fi
INSTANCE_ID="$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID" \
  --iam-instance-profile Name="$PROFILE" --user-data "file://$USER_DATA" \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=10,VolumeType=gp3,DeleteOnTermination=true}' \
  --metadata-options HttpTokens=required \
  --tag-specifications "$(tag_spec instance "cloudops-web-$ENV_NAME")" \
  --query 'Instances[0].InstanceId' --output text)"
state_set VPC_ID "$VPC_ID"; state_set SUBNET_ID "$SUBNET_ID"; state_set SG_ID "$SG_ID"
state_set KEY_NAME "$KEY_NAME"; state_set INSTANCE_ID "$INSTANCE_ID"
log "instance $INSTANCE_ID launching, waiting until running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
             --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
state_set PUBLIC_IP "$PUBLIC_IP"
cat <<MSG

Instance running: $INSTANCE_ID  public IP: $PUBLIC_IP
  ssh -i $KEY_FILE ec2-user@$PUBLIC_IP
  (user-data takes ~3 min: tail -f /var/log/user-data.log)
Next: ./rds_create.sh  then  scp this repo over and run deploy_app.sh on the instance.
MSG
