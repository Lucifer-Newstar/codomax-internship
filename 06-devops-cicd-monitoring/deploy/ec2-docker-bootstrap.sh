#!/usr/bin/env bash
# ec2-docker-bootstrap.sh — one-time setup of an AlmaLinux 9 EC2 instance as the Docker deploy target.
# Run as root on the instance (launched with 04-cloud-services/scripts/ec2_launch.sh, so the SSM agent
# and instance role already exist). Installs Docker, copies the prod compose file + deploy.sh to
# /opt/cloudops, generates the secrets into /opt/cloudops/.env (0600) and does the first deploy.
#
# Usage: sudo ./ec2-docker-bootstrap.sh ghcr.io/<owner>/cloudops-notes:latest [--use-rds]
#   --use-rds   point DB_HOST at the RDS endpoint stored in SSM (/cloudops/dev/DB_HOST) instead of a local db
set -euo pipefail
IMAGE="${1:?usage: ec2-docker-bootstrap.sh <image-ref> [--use-rds]}"
USE_RDS=false; [[ "${2:-}" == "--use-rds" ]] && USE_RDS=true
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR=/opt/cloudops
[[ "$EUID" -eq 0 ]] || { echo "run with sudo"; exit 1; }

echo "==> 1. Docker Engine"
if ! command -v docker >/dev/null; then
  dnf -y install dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
  dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
# Default log driver = CloudWatch for every container (needs logs:* on the instance role).
install -d /etc/docker
cat > /etc/docker/daemon.json <<JSON
{ "log-driver": "awslogs",
  "log-opts": { "awslogs-group": "/cloudops/docker", "awslogs-create-group": "true" },
  "live-restore": true }
JSON
systemctl enable --now docker
docker --version; docker compose version

echo "==> 2. Files"
install -d -m 0750 "$DIR"
install -m 0644 "$HERE/docker-compose.prod.yml" "$DIR/docker-compose.yml"
install -m 0644 "$HERE/nginx.conf" "$DIR/nginx.conf"
install -m 0750 "$HERE/deploy.sh" "$DIR/deploy.sh"

echo "==> 3. Secrets -> $DIR/.env (never leaves the instance)"
if [[ ! -f "$DIR/.env" ]]; then
  {
    echo "POSTGRES_DB=cloudops"
    echo "POSTGRES_USER=cloudops"
    echo "SECRET_KEY=$(openssl rand -hex 32)"
    if [[ "$USE_RDS" == true ]]; then
      region="$(curl -s -H "X-aws-ec2-metadata-token: $(curl -sX PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/placement/region)"
      echo "DB_HOST=$(aws ssm get-parameter --region "$region" --name /cloudops/dev/DB_HOST --query Parameter.Value --output text)"
      echo "POSTGRES_PASSWORD=$(aws ssm get-parameter --region "$region" --name /cloudops/dev/DB_PASSWORD --with-decryption --query Parameter.Value --output text)"
      echo "DB_SSLMODE=require"
    else
      echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)"
    fi
  } > "$DIR/.env"
  chmod 0600 "$DIR/.env"
  echo "created"
else
  echo "exists, keeping"
fi

echo "==> 4. Firewall (http only; ssh stays as configured by the security group)"
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http >/dev/null; firewall-cmd --reload >/dev/null
fi

echo "==> 5. First deploy"
"$DIR/deploy.sh" "$IMAGE" bootstrap
echo
echo "Done. Now set the GitHub variables: EC2_INSTANCE_ID, APP_URL=http://<public-ip>, AWS_REGION, AWS_ROLE_ARN."
