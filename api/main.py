from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Optional
import uuid
import json
import logging
import sys

import pika
import psycopg2
import psycopg2.extras

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Helper: leer IPs desde AWS Parameter Store
# ---------------------------------------------------------------------------
def get_ssm_parameter(name: str, default: str) -> str:
    try:
        import boto3
        client = boto3.client("ssm", region_name="us-east-1")
        response = client.get_parameter(Name=name)
        value = response["Parameter"]["Value"]
        log.info(f"[SSM] {name} = {value}")
        return value
    except Exception as e:
        log.warning(f"[SSM] No se pudo obtener '{name}': {e}. Usando default='{default}'")
        return default

# ---------------------------------------------------------------------------
# Configuracion — se lee al arrancar el contenedor
# ---------------------------------------------------------------------------
RABBITMQ_HOST     = get_ssm_parameter("/message-queue/dev/rabbitmq/public_ip", "localhost")
POSTGRES_HOST     = get_ssm_parameter("/message-queue/dev/postgres/public_ip", "localhost")

RABBITMQ_PORT     = 5672
RABBITMQ_USER     = "admin"
RABBITMQ_PASSWORD = "password123"
RABBITMQ_QUEUE    = "tasks"

POSTGRES_PORT     = 5432
POSTGRES_DB       = "tasksdb"
POSTGRES_USER     = "admin"
POSTGRES_PASSWORD = "password123"

# ---------------------------------------------------------------------------
# Base de datos
# ---------------------------------------------------------------------------
def get_db():
    return psycopg2.connect(
        host=POSTGRES_HOST,
        port=POSTGRES_PORT,
        dbname=POSTGRES_DB,
        user=POSTGRES_USER,
        password=POSTGRES_PASSWORD,
        cursor_factory=psycopg2.extras.RealDictCursor,
    )

def ensure_tables():
    conn = get_db()
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
    log.info("[DB] Tablas verificadas.")

# ---------------------------------------------------------------------------
# RabbitMQ — publicar un mensaje
# ---------------------------------------------------------------------------
def publish_message(action: str, task_id: str, payload: dict):
    credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
    params = pika.ConnectionParameters(
        host=RABBITMQ_HOST,
        port=RABBITMQ_PORT,
        credentials=credentials,
    )
    connection = pika.BlockingConnection(params)
    channel = connection.channel()
    channel.queue_declare(queue=RABBITMQ_QUEUE, durable=True)
    message = json.dumps({"action": action, "task_id": task_id, "payload": payload})
    channel.basic_publish(
        exchange="",
        routing_key=RABBITMQ_QUEUE,
        body=message,
        properties=pika.BasicProperties(delivery_mode=2),  # persistente
    )
    connection.close()
    log.info(f"[RabbitMQ] Mensaje publicado: action={action} task_id={task_id}")

# ---------------------------------------------------------------------------
# FastAPI
# ---------------------------------------------------------------------------
app = FastAPI(title="Task Management API", version="1.0.0")

# Crear tablas al arrancar
@app.on_event("startup")
def on_startup():
    ensure_tables()

# ---------------------------------------------------------------------------
# Modelos
# ---------------------------------------------------------------------------
class TaskPayload(BaseModel):
    data: Optional[dict] = {}

class TaskUpdate(BaseModel):
    status: str

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/")
def read_root():
    return {"status": "ok", "service": "Task Management API"}


@app.get("/health")
def health_check():
    return {"status": "healthy"}


# POST /Tasks — Asíncrono (devuelve 202 inmediatamente)
@app.post("/Tasks", status_code=202)
def create_task(body: TaskPayload):
    task_id = str(uuid.uuid4())

    # 1. Guardar tarea en DB con status 'pending'
    conn = get_db()
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO tasks (task_id, status) VALUES (%s, 'pending')",
            (task_id,)
        )
    conn.close()

    # 2. Enviar trabajo pesado a RabbitMQ
    publish_message("create_task", task_id, body.data)

    return {"task_id": task_id, "status": "pending"}


# DELETE /Tasks/{task_id} — Asíncrono (devuelve 202 inmediatamente)
@app.delete("/Tasks/{task_id}", status_code=202)
def delete_task(task_id: str):
    # Verificar que existe
    conn = get_db()
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("SELECT task_id FROM tasks WHERE task_id = %s", (task_id,))
        row = cur.fetchone()
    conn.close()

    if not row:
        raise HTTPException(status_code=404, detail="Task not found")

    # Encolar el borrado
    publish_message("delete_task", task_id, {})

    return {"task_id": task_id, "status": "delete_queued"}


# PUT /Tasks/{task_id} — Síncrono
@app.put("/Tasks/{task_id}")
def update_task(task_id: str, body: TaskUpdate):
    conn = get_db()
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE tasks SET status = %s, date = NOW() WHERE task_id = %s",
            (body.status, task_id)
        )
        if cur.rowcount == 0:
            conn.close()
            raise HTTPException(status_code=404, detail="Task not found")
    conn.close()
    return {"task_id": task_id, "status": body.status}


# GET /Tasks/{task_id} — Consultar estado de una tarea
@app.get("/Tasks/{task_id}")
def get_task(task_id: str):
    conn = get_db()
    with conn.cursor() as cur:
        cur.execute("SELECT * FROM tasks WHERE task_id = %s", (task_id,))
        row = cur.fetchone()
    conn.close()

    if not row:
        raise HTTPException(status_code=404, detail="Task not found")

    return dict(row)


# GET /Orders — Listar todas las ordenes
@app.get("/Orders")
def get_orders():
    conn = get_db()
    with conn.cursor() as cur:
        cur.execute("SELECT * FROM orders ORDER BY created DESC")
        rows = cur.fetchall()
    conn.close()
    return [dict(r) for r in rows]
