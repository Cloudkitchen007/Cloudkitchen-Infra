#!/bin/bash
# =============================================================================
# CLOUDKITCHEN – AI TIER USER DATA (Docker / prebuilt ECR image)
# Runs on every new AI ASG instance (Ubuntu 22.04 LTS, t3.medium)
#
# Instead of a 20-min on-boot pip install of torch/sentence-transformers, this
# pulls the prebuilt image from ECR (built once by Terraform) and runs it.
# Boot time drops to ~2-3 min. LLM: Mistral-7B via HuggingFace Inference API.
# =============================================================================

set -ex
exec > /var/log/userdata-ai.log 2>&1
echo "[$(date)] Starting AI Tier (Docker) setup..."

# ── 1. Wait for network ───────────────────────────────────────────────────────
until ping -c 1 archive.ubuntu.com &>/dev/null; do
  echo "Network not ready — retrying in 5s..."; sleep 5
done

# ── 2. Install Docker + AWS CLI ───────────────────────────────────────────────
apt-get update -y
apt-get install -y ca-certificates curl unzip gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable --now docker

# AWS CLI v2 (for ECR login)
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install || true

# ── 3. CloudWatch Agent (log shipping) ────────────────────────────────────────
curl -fsSL https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb \
  -o /tmp/amazon-cloudwatch-agent.deb
dpkg -i -E /tmp/amazon-cloudwatch-agent.deb || true

# ── 4. Authenticate to ECR and pull the prebuilt image ────────────────────────
echo "[$(date)] Logging in to ECR (${ecr_registry})..."
aws ecr get-login-password --region ${aws_region} \
  | docker login --username AWS --password-stdin ${ecr_registry}

echo "[$(date)] Pulling AI image ${ai_image_uri}..."
docker pull ${ai_image_uri}

# ── 5. Run the container ──────────────────────────────────────────────────────
docker rm -f airecommender 2>/dev/null || true
docker run -d --name airecommender --restart unless-stopped \
  -p 8000:8000 \
  -e SQS_ORDERS_QUEUE_URL="${sqs_queue_url}" \
  -e AWS_REGION="${aws_region}" \
  -e HUGGINGFACEHUB_API_TOKEN="${hf_api_token}" \
  -e HF_MODEL="mistralai/Mistral-7B-Instruct-v0.3" \
  ${ai_image_uri}

echo "[$(date)] AI Tier (Docker) setup COMPLETE. Container 'airecommender' running on :8000"
echo "  Debug: docker logs airecommender   |   curl http://localhost:8000/api/health"
