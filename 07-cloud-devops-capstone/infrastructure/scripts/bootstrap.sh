#!/usr/bin/env bash
# bootstrap.sh — first-boot setup ON the EC2 host (called from CloudFormation user-data, or by hand
# as root). Installs Docker, lays out /opt/cloudops, generates secrets, starts the stack.
# Idempotent: safe to re-run. Env: IMAGE_API, IMAGE_UI (defaults = latest on GHCR).
set -euo pipefail
IMAGE_API="${IMAGE_API:-ghcr.io/lucifer-newstar/cloudops-api:latest}"
IMAGE_UI="${IMAGE_UI:-ghcr.io/lucifer-newstar/cloudops-ui:latest}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP="$(cd "$HERE/../.." && pwd)"
DIR=/opt/cloudops
[[ "$EUID" -eq 0 ]] || { echo "run as root"; exit 1; }

echo "==> docker"
if ! command -v docker >/dev/null; then
  dnf -y install dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
  dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
install -d /etc/docker
[[ -f /etc/docker/daemon.json ]] || cat > /etc/docker/daemon.json <<'JSON'
{ "live-restore": true, "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
JSON
systemctl enable --now docker

echo "==> aws cli v2 (for the healthcheck metric publisher; the instance role provides credentials)"
if ! command -v aws >/dev/null; then
  arch="$(uname -m)"; dnf -y install unzip curl
  curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o /tmp/awscli.zip
  unzip -q -o /tmp/awscli.zip -d /tmp && /tmp/aws/install >/dev/null && rm -rf /tmp/aws /tmp/awscli.zip
fi

echo "==> files"
install -d -m 0750 "$DIR" /var/log/cloudops
install -m 0644 "$CAP/docker/docker-compose.prod.yml" "$DIR/docker-compose.yml"
install -m 0750 "$HERE/deploy.sh" "$DIR/deploy.sh"
install -m 0755 "$CAP/../06-devops-cicd-monitoring/monitoring/healthcheck.sh" "$DIR/healthcheck.sh"

echo "==> secrets (generated once, stay on this host)"
if [[ ! -f "$DIR/.env" ]]; then
  {
    echo "POSTGRES_DB=cloudops"; echo "POSTGRES_USER=cloudops"
    echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)"
    echo "SECRET_KEY=$(openssl rand -hex 32)"
    echo "IMAGE_API=$IMAGE_API"; echo "IMAGE_UI=$IMAGE_UI"; echo "GIT_SHA=bootstrap"
  } > "$DIR/.env"
  chmod 0600 "$DIR/.env"
fi

echo "==> firewall"
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http >/dev/null && firewall-cmd --reload >/dev/null
fi

echo "==> synthetic monitor every 5 min -> CloudWatch CloudOps/Availability"
cat > /etc/cron.d/cloudops-healthcheck <<'CRON'
*/5 * * * * root /opt/cloudops/healthcheck.sh cloudwatch http://127.0.0.1 >> /var/log/cloudops/healthcheck.log 2>&1
CRON

echo "==> first deploy"
"$DIR/deploy.sh" "$(sed -n 's/^IMAGE_API=//p' "$DIR/.env")" "$(sed -n 's/^IMAGE_UI=//p' "$DIR/.env")" bootstrap
