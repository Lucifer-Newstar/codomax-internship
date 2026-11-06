#!/usr/bin/env bash
# rds_create.sh — managed PostgreSQL on Amazon RDS, reachable ONLY from the EC2 security group.
#   - db.t3.micro, 20 GB gp2, PostgreSQL 16, single-AZ, NOT publicly accessible
#   - master password generated and stored in SSM (/cloudops/<env>/DB_PASSWORD), never printed
#   - writes DB_HOST / DB_PORT / DB_NAME / DB_USER to SSM so deploy_app.sh can build app.env
# Creating takes 5–10 minutes. This is the most expensive resource in the module: delete it when done.
#
# Usage: ./rds_create.sh [--env dev] [--region ap-south-1] [--dry-run]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
parse_common_flags "$@"
aws_preflight
need_cmd openssl

DB_ID="cloudops-db-$ENV_NAME"
DB_NAME="cloudops"
DB_USER="cloudops"
WEB_SG="$(state_get SG_ID)"; VPC_ID="$(state_get VPC_ID)"
[[ -n "$WEB_SG" || "$DRY_RUN" == true ]] || die "no web security group in state — run ./ec2_launch.sh first"
WEB_SG="${WEB_SG:-sg-dryrun}"; VPC_ID="${VPC_ID:-vpc-dryrun}"
DB_SG_NAME="cloudops-db-$ENV_NAME"
SSM="$(dirname "${BASH_SOURCE[0]}")/ssm_params.sh"
COMMON_FLAGS=(--env "$ENV_NAME"); [[ "$DRY_RUN" == true ]] && COMMON_FLAGS+=(--dry-run)

step "1. DB security group: 5432 only from the web SG (not from the internet)"
if [[ "$DRY_RUN" == true ]]; then
  DB_SG="sg-db-dryrun"
  log "+ aws ec2 create-security-group --group-name $DB_SG_NAME --vpc-id $VPC_ID"
else
  DB_SG="$(aws ec2 describe-security-groups --filters Name=group-name,Values="$DB_SG_NAME" Name=vpc-id,Values="$VPC_ID" \
           --query 'SecurityGroups[0].GroupId' --output text)"
  if [[ "$DB_SG" == "None" ]]; then
    DB_SG="$(aws ec2 create-security-group --group-name "$DB_SG_NAME" --vpc-id "$VPC_ID" \
             --description "CloudOps db: postgres from web sg only" \
             --tag-specifications "$(tag_spec security-group "$DB_SG_NAME")" --query GroupId --output text)"
  fi
fi
run aws ec2 authorize-security-group-ingress --group-id "$DB_SG" --ip-permissions \
  "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$WEB_SG,Description=from-web-sg}]" \
  --output text --query Return || log "(rule already present)"
state_set DB_SG_ID "$DB_SG"

step "2. Master password -> SSM SecureString"
"$SSM" put-db-secret "${COMMON_FLAGS[@]}"
if [[ "$DRY_RUN" == true ]]; then PASSWORD="dry-run"; else PASSWORD="$("$SSM" get DB_PASSWORD --env "$ENV_NAME")"; fi

step "3. Create instance $DB_ID (db.t3.micro, PostgreSQL 16)"
if [[ "$DRY_RUN" == false ]] && aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
  log "db instance already exists"
else
  if [[ "$DRY_RUN" == true ]]; then
    log "+ aws rds create-db-instance --db-instance-identifier $DB_ID --engine postgres --engine-version 16 --db-instance-class db.t3.micro --allocated-storage 20 --master-username $DB_USER --master-user-password '<from ssm>' --vpc-security-group-ids $DB_SG --no-publicly-accessible --backup-retention-period 1 --no-multi-az --storage-encrypted"
  else
    aws rds create-db-instance --db-instance-identifier "$DB_ID" \
      --engine postgres --engine-version 16 --db-instance-class db.t3.micro \
      --allocated-storage 20 --storage-type gp2 --storage-encrypted \
      --db-name "$DB_NAME" --master-username "$DB_USER" --master-user-password "$PASSWORD" \
      --vpc-security-group-ids "$DB_SG" --no-publicly-accessible --no-multi-az \
      --backup-retention-period 1 --deletion-protection \
      --tags Key=Project,Value="$PROJECT" Key=Env,Value="$ENV_NAME" \
      --output text --query DBInstance.DBInstanceStatus
  fi
fi

step "4. Wait for 'available' (5–10 min) and publish the endpoint to SSM"
if [[ "$DRY_RUN" == true ]]; then
  log "+ aws rds wait db-instance-available --db-instance-identifier $DB_ID"; exit 0
fi
aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
ENDPOINT="$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
            --query 'DBInstances[0].Endpoint.Address' --output text)"
state_set DB_ID "$DB_ID"; state_set DB_ENDPOINT "$ENDPOINT"
"$SSM" put DB_HOST "$ENDPOINT" --env "$ENV_NAME" >/dev/null
"$SSM" put DB_PORT 5432 --env "$ENV_NAME" >/dev/null
"$SSM" put DB_NAME "$DB_NAME" --env "$ENV_NAME" >/dev/null
"$SSM" put DB_USER "$DB_USER" --env "$ENV_NAME" >/dev/null
"$SSM" put DB_SSLMODE require --env "$ENV_NAME" >/dev/null
cat <<MSG

RDS ready: $ENDPOINT:5432 db=$DB_NAME user=$DB_USER (password in SSM /cloudops/$ENV_NAME/DB_PASSWORD)
The DB is private: test it FROM the EC2 instance, e.g.
  sudo dnf -y install postgresql
  PGPASSWORD="\$(aws ssm get-parameter --name /cloudops/$ENV_NAME/DB_PASSWORD --with-decryption --query Parameter.Value --output text)" \\
    psql "host=$ENDPOINT dbname=$DB_NAME user=$DB_USER sslmode=require" -c 'select version();'
MSG
