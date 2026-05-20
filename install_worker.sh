#!/bin/bash
# ==========================================
# Worker - User Data Script
# Amazon Linux 2023 — mismo patron que install_api.sh
# Clona repo, hace build y corre el contenedor
# ==========================================
set -e

# 1. Instalar Docker
sudo dnf update -y
sudo dnf install -y docker git
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker ec2-user

# 2. Clonar o actualizar el repositorio y acceder a la carpeta del Worker
APP_DIR="/home/ec2-user/app"
REPO_URL="https://github.com/Rui091/aws.git"

if [ -d "${APP_DIR}/.git" ]; then
  sudo -u ec2-user git -C "${APP_DIR}" fetch --all
  if ! sudo -u ec2-user git -C "${APP_DIR}" pull --ff-only; then
    sudo rm -rf "${APP_DIR}"
    sudo -u ec2-user git clone "${REPO_URL}" "${APP_DIR}"
  fi
else
  sudo rm -rf "${APP_DIR}"
  sudo -u ec2-user git clone "${REPO_URL}" "${APP_DIR}"
fi

cd "${APP_DIR}/worker"

# 3. Build y run del contenedor inyectando variables de entorno
if sudo docker ps -a --format '{{.Names}}' | grep -q '^task-worker$'; then
  sudo docker rm -f task-worker
fi

sudo docker build -t task-worker .
sudo docker run -d --restart=always --name task-worker \
  -e POSTGRES_HOST="${postgres_ip}" \
  -e RABBITMQ_HOST="${rabbitmq_ip}" \
  task-worker
