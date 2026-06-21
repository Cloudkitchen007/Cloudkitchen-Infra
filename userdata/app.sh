#!/bin/bash
# =============================================================================
# CLOUDKITCHEN – APP TIER USER DATA
# Runs on every new App ASG instance (Ubuntu 22.04 LTS)
#
# What it does:
#   1. Installs Java 17, Maven wrapper deps, AWS CLI, jq
#   2. Clones backend from emergency-backup branch
#   3. Navigates to the correct nested project path
#   4. Fetches DB credentials from Secrets Manager
#   5. Writes application.yml with real DB connection details
#   6. Builds the Spring Boot JAR (Maven)
#   7. Creates and starts a systemd service for auto-restart
#
# Path note: The GitHub repo emergency-backup branch has this structure:
#   backend/
#     cloudkitchen-aws/
#       backend/        ← pom.xml + mvnw live here
#         src/
# =============================================================================

set -ex
exec > /var/log/userdata-app.log 2>&1
echo "[$(date)] Starting App Tier setup..."

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
aws --version   # log for debugging

# ── 2. Clone backend (emergency-backup branch) ────────────────────────────
cd /opt
git clone --depth 1 -b emergency-backup ${github_repo} app

# ── 3. Navigate to the actual Spring Boot project ─────────────────────────
# CRITICAL FIX: The repo has backend/pom.xml at the root
cd app/backend
APP_DIR=$(pwd)
echo "[$(date)] Working directory: $APP_DIR"

# ── 4. Fetch DB credentials from Secrets Manager ─────────────────────────
echo "[$(date)] Fetching DB credentials from Secrets Manager..."
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${db_secret_arn}" \
  --region "${aws_region}" \
  --query SecretString \
  --output text)

DB_USER=$(echo "$SECRET" | jq -r .username)
DB_PASS=$(echo "$SECRET" | jq -r .password)
DB_HOST=$(echo "$SECRET" | jq -r .host)
DB_PORT=$(echo "$SECRET" | jq -r .port)
DB_NAME=$(echo "$SECRET" | jq -r .dbname)

echo "[$(date)] DB_HOST=$DB_HOST DB_PORT=$DB_PORT DB_NAME=$DB_NAME"

# ── 5. Write application.yml ──────────────────────────────────────────────
# Note: Using unquoted EOF so bash expands $DB_HOST etc.
# Terraform only expands $${...} patterns; bare $DB_HOST is left for bash.
cat > src/main/resources/application.yml << EOF
server:
  port: 8080

spring:
  application:
    name: cloud-kitchen-backend

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

management:
  endpoints:
    web:
      exposure:
        include: health,info
  endpoint:
    health:
      show-details: when-authorized

logging:
  level:
    com.cloudkitchen: INFO
    org.springframework.web: WARN
  file:
    name: /var/log/cloudkitchen/app.log
EOF

echo "[$(date)] application.yml written."

# ── 6. Fix Flyway script name and Build the Spring Boot JAR ─────────────
echo "[$(date)] Fixing Flyway script name..."
mv src/main/resources/db/migration/V1_init_schema.sql src/main/resources/db/migration/V1__init_schema.sql 2>/dev/null || true

mkdir -p /var/log/cloudkitchen
echo "[$(date)] Building Spring Boot application with Maven..."
mvn clean package -DskipTests

JAR_FILE=$(ls target/cloud-kitchen-*.jar 2>/dev/null | head -1)
if [ -z "$JAR_FILE" ]; then
  echo "[ERROR] Maven build failed – no JAR found in target/"
  exit 1
fi
echo "[$(date)] Build SUCCESS. JAR: $JAR_FILE"

# ── 7. Create systemd service ─────────────────────────────────────────────
cat > /etc/systemd/system/cloudkitchen.service << SVCEOF
[Unit]
Description=CloudKitchen Spring Boot Application
Documentation=https://github.com/PruthviBhat-UST/cloudkitchen-aws
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/java -Xms256m -Xmx512m -jar $APP_DIR/$JAR_FILE
StandardOutput=append:/var/log/cloudkitchen/app.log
StandardError=append:/var/log/cloudkitchen/app.log
SyslogIdentifier=cloudkitchen

# Restart policy: auto-restart on failure, but not if it keeps crashing
Restart=on-failure
RestartSec=30
StartLimitInterval=300
StartLimitBurst=3

# Graceful shutdown
TimeoutStopSec=30
KillSignal=SIGTERM
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
SVCEOF

# ── 8. Enable and start the service ──────────────────────────────────────
systemctl daemon-reload
systemctl enable cloudkitchen
systemctl start cloudkitchen

echo "[$(date)] cloudkitchen.service started."

# ── 9. Configure and Start CloudWatch Agent ──────────────────────────────
cat > /opt/aws/amazon-cloudwatch-agent/bin/config.json << CWEOF
{
  "agent": {
    "run_as_user": "root"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/cloudkitchen/app.log",
            "log_group_name": "/cloudkitchen/app",
            "log_stream_name": "{instance_id}/app.log"
          },
          {
            "file_path": "/var/log/userdata-app.log",
            "log_group_name": "/cloudkitchen/app",
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

echo "[$(date)] App Tier setup COMPLETE."
echo ""
echo "Useful debug commands:"
echo "  systemctl status cloudkitchen"
echo "  journalctl -u cloudkitchen -f"
echo "  tail -f /var/log/cloudkitchen/app.log"
echo "  curl http://localhost:8080/api/categories"