#!/bin/bash
# =============================================================================
# CLOUDKITCHEN – ORDER SERVICE USER DATA
# Spring Boot 3.2 | Orders | Port 8082
# Flyway disabled – schema owned by menu-service
# =============================================================================

set -ex
exec > /var/log/userdata-order.log 2>&1
echo "[$(date)] Starting Order Service setup..."

# ── 1. Install dependencies ───────────────────────────────────────────────
apt-get update -y
apt-get install -y openjdk-17-jdk maven curl jq unzip

curl -fsSL https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -o /tmp/amazon-cloudwatch-agent.deb
dpkg -i -E /tmp/amazon-cloudwatch-agent.deb

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
aws --version

# ── 2. Download order-service source from S3 ──────────────────────────────
mkdir -p /opt/order_service /var/log/cloudkitchen
cd /opt
echo "[$(date)] Downloading Order Service from S3..."
aws s3 cp s3://${s3_bucket}/deployments/order_service.zip /opt/order_service.zip
unzip /opt/order_service.zip -d /opt/order_service
cd /opt/order_service

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
  port: 8082

spring:
  application:
    name: cloudkitchen-order-service
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
  # Tolerate uninitialized Hibernate lazy proxies (Order->OrderItem->MenuItem->Category)
  # Without this, placing/listing an order throws 500 (ByteBuddyInterceptor serializer).
  jackson:
    serialization:
      fail-on-empty-beans: false
  flyway:
    enabled: false

app:
  cors:
    allowed-origins: "*"

aws:
  region: ${aws_region}
  sqs:
    orders-queue-url: ${sqs_queue_url}

logging:
  level:
    com.cloudkitchen: INFO
    org.springframework.web: WARN
  file:
    name: /var/log/cloudkitchen/order.log
EOF

# ── 5. Build with Maven ───────────────────────────────────────────────────
echo "[$(date)] Building Order Service with Maven..."
mvn clean package -DskipTests

JAR_FILE=$(ls target/order-service-*.jar 2>/dev/null | head -1)
[ -z "$JAR_FILE" ] && { echo "[ERROR] Maven build failed"; exit 1; }
echo "[$(date)] Build SUCCESS: $JAR_FILE"

# ── 6. Create systemd service ─────────────────────────────────────────────
cat > /etc/systemd/system/orderservice.service << SVCEOF
[Unit]
Description=CloudKitchen Order Service (Spring Boot)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/order_service
ExecStart=/usr/bin/java -Xms256m -Xmx512m -jar /opt/order_service/$JAR_FILE
StandardOutput=append:/var/log/cloudkitchen/order.log
StandardError=append:/var/log/cloudkitchen/order.log
SyslogIdentifier=orderservice
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
systemctl enable orderservice
systemctl start orderservice
echo "[$(date)] orderservice started."

# ── 7. CloudWatch Agent ───────────────────────────────────────────────────
cat > /opt/aws/amazon-cloudwatch-agent/bin/config.json << CWEOF
{
  "agent": { "run_as_user": "root" },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/cloudkitchen/order.log",  "log_group_name": "/cloudkitchen/order",  "log_stream_name": "{instance_id}/order.log" },
          { "file_path": "/var/log/userdata-order.log",       "log_group_name": "/cloudkitchen/order",  "log_stream_name": "{instance_id}/userdata.log" }
        ]
      }
    }
  }
}
CWEOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json

echo "[$(date)] Order Service setup COMPLETE."
echo "  curl http://localhost:8082/api/orders"
