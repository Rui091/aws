#!/bin/bash
# Amazon Linux 2023 - Instalar PostgreSQL 15
sudo dnf update -y
sudo dnf install -y postgresql15-server

# Inicializar la base de datos
sudo postgresql-setup --initdb

# Configurar Postgres para aceptar conexiones externas
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/g" /var/lib/pgsql/data/postgresql.conf

# Permitir conexiones IPv4 en pg_hba.conf para el bloque 0.0.0.0/0
echo "host    all             all             0.0.0.0/0               scram-sha-256" | sudo tee -a /var/lib/pgsql/data/pg_hba.conf

# Habilitar y reiniciar Postgres
sudo systemctl enable postgresql
sudo systemctl start postgresql

# Crear base de datos y usuario de prueba
sudo -u postgres psql -c "CREATE USER admin WITH PASSWORD 'password123';"
sudo -u postgres psql -c "CREATE DATABASE tasksdb OWNER admin;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE tasksdb TO admin;"
