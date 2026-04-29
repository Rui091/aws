#!/bin/bash
# ==========================================
# Worker - User Data Script
# Amazon Linux 2023 — mismo patron que install_api.sh
# Escribe main.py + Dockerfile, hace build y corre el contenedor
# ==========================================
set -e

# 1. Instalar Docker
sudo dnf update -y
sudo dnf install -y docker
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker ec2-user

# 2. Crear directorio de trabajo
mkdir -p /home/ec2-user/worker
cd /home/ec2-user/worker

# 3. Escribir main.py
cat <<'PYEOF' > main.py
#!/usr/bin/env python3
"""
Async Worker
============
Consume mensajes de RabbitMQ y actualiza el estado de las tareas en PostgreSQL.

Flujo:
  1. Lee las IPs de RabbitMQ y PostgreSQL desde AWS Parameter Store (SSM).
  2. Se conecta a RabbitMQ y se queda escuchando la cola 'tasks'.
  3. Por cada mensaje recibido:
     - 'create_task' -> crea/actualiza el registro en PostgreSQL con status 'completed'
     - 'delete_task' -> marca el registro en PostgreSQL como 'deleted'
"""

import json
import time
import logging
import sys

import pika
import psycopg2
import psycopg2.extras

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)

RABBITMQ_DEFAULT_HOST = "localhost"
POSTGRES_DEFAULT_HOST = "localhost"

RABBITMQ_PORT     = 5672
RABBITMQ_USER     = "admin"
RABBITMQ_PASSWORD = "password123"
RABBITMQ_QUEUE    = "tasks"

POSTGRES_PORT     = 5432
POSTGRES_DB       = "tasksdb"
POSTGRES_USER     = "admin"
POSTGRES_PASSWORD = "password123"


RABBITMQ_HOST     = "${rabbitmq_ip}"
POSTGRES_HOST     = "${postgres_ip}"


def get_db_connection(pg_host: str):
    return psycopg2.connect(
        host=pg_host,
        port=POSTGRES_PORT,
        dbname=POSTGRES_DB,
        user=POSTGRES_USER,
        password=POSTGRES_PASSWORD,
    )


def ensure_tables(pg_host: str):
    conn = get_db_connection(pg_host)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS tasks (
                task_id  VARCHAR(64)  PRIMARY KEY,
                status   VARCHAR(32)  NOT NULL DEFAULT 'pending',
                date     TIMESTAMP    NOT NULL DEFAULT NOW()
            );
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS orders (
                order_id  SERIAL       PRIMARY KEY,
                task_id   VARCHAR(64)  REFERENCES tasks(task_id),
                payload   JSONB,
                created   TIMESTAMP    NOT NULL DEFAULT NOW()
            );
        """)
    conn.close()
    log.info("[DB] Tablas verificadas / creadas correctamente.")


def update_task_status(pg_host: str, task_id: str, new_status: str):
    conn = get_db_connection(pg_host)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE tasks SET status = %s, date = NOW() WHERE task_id = %s",
            (new_status, task_id),
        )
        if cur.rowcount == 0:
            log.warning(f"[DB] task_id '{task_id}' no encontrado para UPDATE.")
        else:
            log.info(f"[DB] task_id '{task_id}' -> status='{new_status}'")
    conn.close()


def insert_order(pg_host: str, task_id: str, payload: dict):
    conn = get_db_connection(pg_host)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO orders (task_id, payload) VALUES (%s, %s)",
            (task_id, json.dumps(payload)),
        )
        log.info(f"[DB] Orden insertada para task_id='{task_id}'")
    conn.close()


def process_message(body: bytes, pg_host: str):
    try:
        msg = json.loads(body)
    except json.JSONDecodeError:
        log.error(f"[WORKER] Mensaje no es JSON valido: {body}")
        return

    action  = msg.get("action")
    task_id = msg.get("task_id")
    payload = msg.get("payload", {})

    if not task_id:
        log.error(f"[WORKER] Mensaje sin task_id: {msg}")
        return

    log.info(f"[WORKER] Procesando accion='{action}' task_id='{task_id}'")

    if action == "create_task":
        time.sleep(1)
        update_task_status(pg_host, task_id, "completed")
        insert_order(pg_host, task_id, payload)
    elif action == "delete_task":
        time.sleep(0.5)
        update_task_status(pg_host, task_id, "deleted")
    else:
        log.warning(f"[WORKER] Accion desconocida: '{action}'")


def connect_rabbitmq(host: str, retries: int = 10, delay: int = 5) -> pika.BlockingConnection:
    credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
    params = pika.ConnectionParameters(
        host=host,
        port=RABBITMQ_PORT,
        credentials=credentials,
        heartbeat=600,
        blocked_connection_timeout=300,
    )
    for attempt in range(1, retries + 1):
        try:
            log.info(f"[RabbitMQ] Intento {attempt}/{retries} conectando a {host}:{RABBITMQ_PORT}...")
            conn = pika.BlockingConnection(params)
            log.info("[RabbitMQ] Conexion establecida.")
            return conn
        except Exception as e:
            log.warning(f"[RabbitMQ] Fallo: {e}. Reintentando en {delay}s...")
            time.sleep(delay)
    raise RuntimeError(f"[RabbitMQ] No se pudo conectar despues de {retries} intentos.")


def main():
    rabbitmq_host = RABBITMQ_HOST
    postgres_host = POSTGRES_HOST

    ensure_tables(postgres_host)

    connection = connect_rabbitmq(rabbitmq_host)
    channel = connection.channel()
    channel.queue_declare(queue=RABBITMQ_QUEUE, durable=True)
    channel.basic_qos(prefetch_count=1)

    def on_message(ch, method, properties, body):
        process_message(body, postgres_host)
        ch.basic_ack(delivery_tag=method.delivery_tag)

    channel.basic_consume(queue=RABBITMQ_QUEUE, on_message_callback=on_message)

    log.info(f"[WORKER] Escuchando cola '{RABBITMQ_QUEUE}'. Presiona Ctrl+C para salir.")
    try:
        channel.start_consuming()
    except KeyboardInterrupt:
        log.info("[WORKER] Detenido por el usuario.")
        channel.stop_consuming()
    finally:
        connection.close()


if __name__ == "__main__":
    main()
PYEOF

# 4. Escribir requirements.txt
cat <<EOF > requirements.txt
pika
psycopg2-binary
EOF

# 5. Escribir Dockerfile
cat <<EOF > Dockerfile
FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["python", "main.py"]
EOF

# 6. Build y run del contenedor
sudo docker build -t task-worker .
sudo docker run -d --restart=always --name task-worker task-worker
