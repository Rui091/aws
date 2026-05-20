#!/usr/bin/env python3
"""
API
============

implementa
get /                  : Obtener información general de la API
get /health            : Verificar estado de la API
get /tasks             : Listar todas las tareas
get /tasks/{task_id}   : Obtener detalles de una tarea específica
post /task             : Crear una tarea (asíncrono)
delete /task           : Eliminar una tarea (asíncrono)
"""
import json
import time
import logging
import sys

import pika
import psycopg2
from psycopg2.extras import RealDictCursor
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Configuración de logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Configuración — valores por defecto usados si SSM no está disponible
# ---------------------------------------------------------------------------
RABBITMQ_DEFAULT_HOST = "localhost"
POSTGRES_DEFAULT_HOST = "localhost"

RABBITMQ_PORT     = 5672
RABBITMQ_USER     = "admin"
RABBITMQ_PASSWORD = "password123"

POSTGRES_PORT     = 5432
POSTGRES_DB       = "tasksdb"
POSTGRES_USER     = "admin"
POSTGRES_PASSWORD = "password123"


# ---------------------------------------------------------------------------
# FIX 1: IPs inyectadas a través de variables de entorno (Docker)
# ---------------------------------------------------------------------------
import os
PG_HOST       = os.environ.get("POSTGRES_HOST", "localhost")
RABBITMQ_HOST = os.environ.get("RABBITMQ_HOST", "localhost")


# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------
def get_db_connection() -> psycopg2.extensions.connection:
    """Crea y devuelve una conexión a PostgreSQL usando el host global."""
    return psycopg2.connect(
        host=PG_HOST,
        port=POSTGRES_PORT,
        dbname=POSTGRES_DB,
        user=POSTGRES_USER,
        password=POSTGRES_PASSWORD,
        connect_timeout=5,   # FIX 2: evita bloqueos indefinidos
    )


def ensure_tables():
    """Crea las tablas necesarias si no existen."""
    conn = get_db_connection()
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


def insert_task(task_id: str, status: str):
    """Inserta una tarea con estado inicial en PostgreSQL."""
    conn = get_db_connection()
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO tasks (task_id, status) VALUES (%s, %s)",
            (task_id, status),
        )
        log.info(f"[DB] Tarea inicial insertada task_id='{task_id}' status='{status}'")
    conn.close()


def update_task_status(task_id: str, new_status: str):
    """Actualiza el status de una tarea en PostgreSQL."""
    conn = get_db_connection()
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


def insert_order(task_id: str, payload: dict):
    """Inserta un registro en la tabla Orders."""
    conn = get_db_connection()
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO orders (task_id, payload) VALUES (%s, %s)",
            (task_id, json.dumps(payload)),
        )
        log.info(f"[DB] Orden insertada para task_id='{task_id}'")
    conn.close()


# ---------------------------------------------------------------------------
# RabbitMQ — conexión con reintentos
# ---------------------------------------------------------------------------
def connect_rabbitmq(retries: int = 3, delay: int = 2) -> pika.BlockingConnection:
    """Intenta conectarse a RabbitMQ con reintentos.
    FIX 3: retries y delay reducidos para no bloquear el gateway (antes 10/5 = 50s).
    FIX 4: socket_timeout añadido para fallo rápido si el host no responde.
    FIX 5: usa la variable global RABBITMQ_HOST, no llama a SSM en cada request.
    """
    credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
    params = pika.ConnectionParameters(
        host=RABBITMQ_HOST,
        port=RABBITMQ_PORT,
        credentials=credentials,
        heartbeat=600,
        blocked_connection_timeout=300,
        socket_timeout=3,        # FIX 4
        connection_attempts=1,
    )
    for attempt in range(1, retries + 1):
        try:
            log.info(f"[RabbitMQ] Intento {attempt}/{retries} conectando a {RABBITMQ_HOST}:{RABBITMQ_PORT}...")
            conn = pika.BlockingConnection(params)
            log.info("[RabbitMQ] Conexión establecida.")
            return conn
        except Exception as e:
            log.warning(f"[RabbitMQ] Fallo: {e}. Reintentando en {delay}s...")
            time.sleep(delay)
    raise RuntimeError(f"[RabbitMQ] No se pudo conectar después de {retries} intentos.")


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------
app = FastAPI()


@app.get("/")
def read_root():
    return {"status": "ok", "value": "Fixed Value from FastAPI"}


@app.get("/health")
def health_check():
    return {"status": "healthy"}


@app.get("/tasks")
def get_tasks():
    # FIX 6: SSM ya no se llama aquí; se usa la variable global PG_HOST.
    try:
        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("SELECT * FROM tasks ORDER BY date DESC")
        tasks = cur.fetchall()
        cur.close()
        conn.close()
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    return {"tasks": tasks}


@app.get("/tasks/{task_id}")
def get_task(task_id: str):
    # FIX 7: antes usaba connect_rabbitmq() en lugar de get_db_connection().
    # FIX 8: HTTPException 404 separada del bloque except para no convertirla en 500.
    try:
        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("SELECT * FROM tasks WHERE task_id = %s", (task_id,))
        task = cur.fetchone()
        cur.close()
        conn.close()
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    return {"task": task}


# ---------------------------------------------------------------------------
# Modelos
# ---------------------------------------------------------------------------
class TaskCreate(BaseModel):
    status: str
    payload: str

class TaskDelete(BaseModel):
    task_id: str


# ---------------------------------------------------------------------------
# Publicar en RabbitMQ
# ---------------------------------------------------------------------------
def publish_message(queue: str, message: dict) -> str:
    """Publica un mensaje en la cola de RabbitMQ. Devuelve el task_id."""
    if message["action"] == "create_task":
        message["task_id"] = f"task_{int(time.time()*1000)}"
        # Insertar en DB como pendiente ANTES de enviar a la cola
        insert_task(message["task_id"], message["status"])

    try:
        conn = connect_rabbitmq()   # FIX 5: ya no llama a SSM aquí
        channel = conn.channel()
        channel.queue_declare(queue=queue, durable=True)
        channel.basic_publish(
            exchange="",
            routing_key=queue,
            body=json.dumps(message),
            properties=pika.BasicProperties(delivery_mode=2),
        )
        log.info(f"[API] Mensaje publicado en '{queue}': {message}")
    except Exception as e:
        log.error(f"[API] Error publicando mensaje en '{queue}': {e}")
        raise HTTPException(status_code=503, detail=f"No se pudo encolar la tarea: {e}")
    finally:
        # FIX 9: conn puede no existir si connect_rabbitmq lanzó excepción
        if 'conn' in locals() and conn.is_open:
            conn.close()

    # FIX 10: return fuera del finally para no suprimir excepciones
    return message["task_id"]


@app.post("/task")
def create_task(task: TaskCreate):
    # Enviar a la cola "tasks" (que es la que escucha el worker), no "create_queue"
    tid = publish_message("tasks", {"action": "create_task", "status": task.status, "payload": task.payload})
    return {"message": "Create task request queued", "task_id": tid}


@app.delete("/task")
def delete_task(task: TaskDelete):
    # Enviar a la cola "tasks"
    tid = publish_message("tasks", {"action": "delete_task", "task_id": task.task_id, "payload": {}})
    return {"message": "Delete task request queued", "task_id": tid}