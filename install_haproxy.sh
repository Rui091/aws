#!/bin/bash
# ==========================================
# HAProxy Load Balancer - User Data Script
# Amazon Linux 2023
# Corre HAProxy como contenedor Docker usando docker run
# ==========================================

set -e

# 1. Instalar Docker
dnf update -y
dnf install -y docker
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

# 2. Crear directorio de trabajo
mkdir -p /opt/haproxy
cd /opt/haproxy

# 3. Escribir haproxy.cfg con las IPs privadas de los backends
#    (Variables inyectadas por Terraform via templatefile)
cat > /opt/haproxy/haproxy.cfg <<EOF
defaults
    mode http
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms

frontend http-in
    bind *:80
    default_backend api_servers

backend api_servers
    balance roundrobin
    option  httpchk GET /health
    server  api1 ${api_server_1_ip}:80 check
    server  api2 ${api_server_2_ip}:80 check
EOF

# 4. Levantar el contenedor directamente (sin docker-compose)
docker run -d \
  --name load_balancer \
  --restart unless-stopped \
  -p 80:80 \
  -v /opt/haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
  haproxy:latest
