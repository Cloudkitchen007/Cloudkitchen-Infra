#!/bin/bash
# =============================================================================
# CLOUDKITCHEN – WEB TIER USER DATA
# Runs on every new Web ASG instance (Ubuntu 22.04 LTS)
#
# What it does:
#   1. Installs Node.js 18 (LTS) via NodeSource + Nginx
#   2. Clones the React frontend from GitHub (main branch)
#   3. Builds the production bundle
#   4. Deploys to Nginx web root
#   5. Writes Nginx config: serves SPA + proxies /api/ to Internal ALB
#      + exposes /health for ALB health checks
# =============================================================================

set -ex
exec > /var/log/userdata-web.log 2>&1
echo "[$(date)] Starting Web Tier setup..."

# ── 1. Base packages ──────────────────────────────────────────────────────
apt-get update -y
apt-get install -y git curl nginx

# ── 2. Node.js 18 LTS via NodeSource ─────────────────────────────────────
# Ubuntu 22.04 ships Node.js 12 which is too old for React 18.
# NodeSource provides a modern, maintained Node.js 18 package.
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs
node --version   # log version for debugging
npm  --version

# ── 3. Clone frontend (main branch) ──────────────────────────────────────
cd /opt
git clone --depth 1 ${github_repo} app
cd app/frontend

# ── 4. Build React production bundle ─────────────────────────────────────
npm install --legacy-peer-deps
# CI=false prevents treating warnings as errors during build
CI=false npm run build

# ── 5. Deploy to Nginx root ───────────────────────────────────────────────
rm -rf /usr/share/nginx/html/*
cp -r build/* /usr/share/nginx/html/

# ── 6. Write Nginx configuration ──────────────────────────────────────────
# NOTE: Shell variables ($uri, $host, etc.) are NGINX variables – they are
# intentionally literal here. ${internal_alb_dns} is injected by Terraform
# templatefile() before this script runs.
cat > /etc/nginx/sites-available/default << 'NGINX_EOF'
server {
    listen 80;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    # ── Health check endpoint (required by ALB target group) ────────────
    location = /health {
        access_log off;
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }

    # ── Proxy /api/ requests to the Internal ALB (Spring Boot) ──────────
    # Nginx forwards the FULL URI so /api/categories reaches Spring Boot as-is.
    location /api/ {
        proxy_pass         http://INTERNAL_ALB_DNS_PLACEHOLDER/api/;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
    }

    # ── Serve React SPA (catch-all for client-side routing) ─────────────
    location / {
        try_files $uri $uri/ /index.html;
        expires -1;
        add_header Cache-Control "no-store, no-cache, must-revalidate";
    }

    # ── Cache static assets aggressively ────────────────────────────────
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
}
NGINX_EOF

# Inject the real Internal ALB DNS (Terraform variable → sed replacement)
sed -i "s|INTERNAL_ALB_DNS_PLACEHOLDER|${internal_alb_dns}|g" \
    /etc/nginx/sites-available/default

# ── 7. Validate and start Nginx ───────────────────────────────────────────
nginx -t   # syntax check – will abort here if config is broken
systemctl enable nginx
systemctl restart nginx

echo "[$(date)] Web Tier setup COMPLETE. Nginx is running."
echo "[$(date)] Internal ALB DNS: ${internal_alb_dns}"