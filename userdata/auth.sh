#!/bin/bash
# =============================================================================
# CLOUDKITCHEN – AUTH TIER USER DATA
# Runs on every new Auth ASG instance (Ubuntu 22.04 LTS)
# Spring Boot 3.2 + AWS Cognito (same pattern as app.sh)
# =============================================================================

set -ex
exec > /var/log/userdata-auth.log 2>&1
echo "[$(date)] Starting Auth Tier setup..."

# ── 1. Install dependencies ───────────────────────────────────────────────
apt-get update -y
apt-get install -y openjdk-17-jdk maven git curl jq unzip

# Install CloudWatch Agent
curl -fsSL https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -o /tmp/amazon-cloudwatch-agent.deb
dpkg -i -E /tmp/amazon-cloudwatch-agent.deb

# Install AWS CLI v2
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
aws --version

# ── 2. Download auth service source from S3 ───────────────────────────────
mkdir -p /opt/auth_service
cd /opt
echo "[$(date)] Downloading Auth Service from S3..."
aws s3 cp s3://${s3_bucket}/deployments/auth_service.zip /opt/auth_service.zip
unzip /opt/auth_service.zip -d /opt/auth_service
cd /opt/auth_service

# ── 3. Build the Spring Boot JAR ─────────────────────────────────────────
mkdir -p /var/log/cloudkitchen
echo "[$(date)] Building Auth Service with Maven..."
mvn clean package -DskipTests

JAR_FILE=$(ls target/auth-service-*.jar 2>/dev/null | head -1)
if [ -z "$JAR_FILE" ]; then
  echo "[ERROR] Maven build failed – no JAR found in target/"
  exit 1
fi
echo "[$(date)] Build SUCCESS. JAR: $JAR_FILE"

# ── 4. Create systemd service (Cognito pool IDs injected by Terraform) ────
cat > /etc/systemd/system/authservice.service << SVCEOF
[Unit]
Description=CloudKitchen Auth Service (Spring Boot)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/auth_service
Environment="USER_POOL_ID=${user_pool_id}"
Environment="USER_CLIENT_ID=${user_client_id}"
Environment="RESTAURANT_POOL_ID=${restaurant_pool_id}"
Environment="RESTAURANT_CLIENT_ID=${restaurant_client_id}"
Environment="AWS_REGION=${aws_region}"
ExecStart=/usr/bin/java -Xms128m -Xmx256m -jar /opt/auth_service/$JAR_FILE
StandardOutput=append:/var/log/cloudkitchen/auth.log
StandardError=append:/var/log/cloudkitchen/auth.log
SyslogIdentifier=authservice
Restart=on-failure
RestartSec=30
StartLimitInterval=300
StartLimitBurst=3
TimeoutStopSec=30
KillSignal=SIGTERM
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
SVCEOF

# ── 5. Enable and start the service ──────────────────────────────────────
systemctl daemon-reload
systemctl enable authservice
systemctl start authservice

echo "[$(date)] authservice started."

# ── 6. Configure CloudWatch Agent ────────────────────────────────────────
cat > /opt/aws/amazon-cloudwatch-agent/bin/config.json << CWEOF
{
  "agent": { "run_as_user": "root" },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/cloudkitchen/auth.log",
            "log_group_name": "/cloudkitchen/auth",
            "log_stream_name": "{instance_id}/auth.log"
          },
          {
            "file_path": "/var/log/userdata-auth.log",
            "log_group_name": "/cloudkitchen/auth",
            "log_stream_name": "{instance_id}/userdata.log"
          }
        ]
      }
    }
  }
}
CWEOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json
echo "[$(date)] CloudWatch Agent started."

echo "[$(date)] Auth Tier setup COMPLETE."
echo ""
echo "Debug commands:"
echo "  systemctl status authservice"
echo "  journalctl -u authservice -f"
echo "  tail -f /var/log/cloudkitchen/auth.log"
echo "  curl http://localhost:8001/auth/health"
