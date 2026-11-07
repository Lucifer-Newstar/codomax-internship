#!/usr/bin/env bash
# EC2 user-data: runs once as root on first boot (AlmaLinux 9 AMI).
# Keeps the VM ready for scripts/deploy_app.sh: packages, SSM agent, CloudWatch agent, app user.
# Nothing secret here — user-data is readable from the instance metadata service.
set -euxo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1

dnf -y update
dnf -y install git python3.11 python3.11-pip nginx policycoreutils-python-utils firewalld

# SSM agent lets me run commands / open a shell without SSH (used by the CD pipeline later).
dnf -y install https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm || true
systemctl enable --now amazon-ssm-agent || true

# CloudWatch agent for logs + memory/disk metrics (config applied by deploy_app.sh).
dnf -y install https://amazoncloudwatch-agent.s3.amazonaws.com/redhat/amd64/latest/amazon-cloudwatch-agent.rpm || true

systemctl enable --now firewalld
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --reload

id cloudops &>/dev/null || useradd --system --create-home --shell /sbin/nologin cloudops
install -d -o cloudops -g cloudops -m 0755 /opt/cloudops /var/log/cloudops
install -d -o root -g root -m 0700 /etc/cloudops

hostnamectl set-hostname cloudops-web01
echo "user-data finished $(date -Is)"
