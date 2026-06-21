#!/bin/bash
# =============================================================================
# CLOUDKITCHEN – MENU SERVICE USER DATA
# Spring Boot 3.2 | Categories + Menu Items | Port 8080
# Flyway enabled – this service owns the full DB schema
# =============================================================================

set -ex
exec > /var/log/userdata-menu.log 2>&1
echo "[$(date)] Starting Menu Service setup..."

# ── 1. Install dependencies ───────────────────────────────────────────────
apt-get update -y
apt-get install -y openjdk-17-jdk maven curl jq unzip

curl -fsSL https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -o /tmp/amazon-cloudwatch-agent.deb
dpkg -i -E /tmp/amazon-cloudwatch-agent.deb

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
aws --version

# ── 2. Download menu-service source from S3 ───────────────────────────────
mkdir -p /opt/menu_service /var/log/cloudkitchen
cd /opt
echo "[$(date)] Downloading Menu Service from S3..."
aws s3 cp s3://${s3_bucket}/deployments/menu_service.zip /opt/menu_service.zip
unzip /opt/menu_service.zip -d /opt/menu_service
cd /opt/menu_service

# ── 3. Fetch DB credentials from Secrets Manager ─────────────────────────
echo "[$(date)] Fetching DB credentials..."
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${db_secret_arn}" \
  --region "${aws_region}" \
  --query SecretString --output text)

DB_USER=$(echo "$SECRET" | jq -r .username)
DB_PASS=$(echo "$SECRET" | jq -r .password)
DB_HOST=$(echo "$SECRET" | jq -r .host)
DB_PORT=$(echo "$SECRET" | jq -r .port)
DB_NAME=$(echo "$SECRET" | jq -r .dbname)

# ── 4. Write production application.yml ──────────────────────────────────
cat > src/main/resources/application.yml << EOF
server:
  port: 8080

spring:
  application:
    name: cloudkitchen-menu-service
  datasource:
    url: jdbc:postgresql://$DB_HOST:$DB_PORT/$DB_NAME
    username: $DB_USER
    password: $DB_PASS
    driver-class-name: org.postgresql.Driver
    hikari:
      connection-timeout: 30000
      maximum-pool-size: 5
      minimum-idle: 2
  jpa:
    hibernate:
      ddl-auto: validate
    show-sql: false
    properties:
      hibernate:
        dialect: org.hibernate.dialect.PostgreSQLDialect
  flyway:
    enabled: true
    locations: classpath:db/migration
    baseline-on-migrate: true

app:
  cors:
    allowed-origins: "*"

logging:
  level:
    com.cloudkitchen: INFO
    org.springframework.web: WARN
  file:
    name: /var/log/cloudkitchen/menu.log
EOF

# ── 5. Build with Maven ───────────────────────────────────────────────────
echo "[$(date)] Building Menu Service with Maven..."
mvn clean package -DskipTests

JAR_FILE=$(ls target/menu-service-*.jar 2>/dev/null | head -1)
[ -z "$JAR_FILE" ] && { echo "[ERROR] Maven build failed"; exit 1; }
echo "[$(date)] Build SUCCESS: $JAR_FILE"

# ── 6. Create systemd service ─────────────────────────────────────────────
cat > /etc/systemd/system/menuservice.service << SVCEOF
[Unit]
Description=CloudKitchen Menu Service (Spring Boot)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/menu_service
ExecStart=/usr/bin/java -Xms256m -Xmx512m -jar /opt/menu_service/$JAR_FILE
StandardOutput=append:/var/log/cloudkitchen/menu.log
StandardError=append:/var/log/cloudkitchen/menu.log
SyslogIdentifier=menuservice
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

systemctl daemon-reload
systemctl enable menuservice
systemctl start menuservice
echo "[$(date)] menuservice started."

# ── 7. CloudWatch Agent ───────────────────────────────────────────────────
cat > /opt/aws/amazon-cloudwatch-agent/bin/config.json << CWEOF
{
  "agent": { "run_as_user": "root" },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/cloudkitchen/menu.log",   "log_group_name": "/cloudkitchen/menu",   "log_stream_name": "{instance_id}/menu.log" },
          { "file_path": "/var/log/userdata-menu.log",        "log_group_name": "/cloudkitchen/menu",   "log_stream_name": "{instance_id}/userdata.log" }
        ]
      }
    }
  }
}
CWEOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json

echo "[$(date)] Menu Service setup COMPLETE."
echo "  curl http://localhost:8080/api/categories"
echo "  curl http://localhost:8080/api/menu"
