#!/bin/bash
set -euxo pipefail
apt-get update
apt-get install -y haproxy nginx

# nginx는 임시 목적지라 8080으로 이동 (80은 HAProxy가 사용)
sed -i 's/listen 80 default_server;/listen 8080 default_server;/; s/listen \[::\]:80 default_server;/listen [::]:8080 default_server;/' /etc/nginx/sites-available/default
echo "jammy edge-a: temp backend" > /var/www/html/index.html
systemctl restart nginx

# HAProxy: 80으로 받아서 nginx(8080)로 전달
cat >> /etc/haproxy/haproxy.cfg <<'CFG'

frontend web
    bind *:80
    default_backend temp

backend temp
    server local 127.0.0.1:8080 check
CFG
systemctl restart haproxy
