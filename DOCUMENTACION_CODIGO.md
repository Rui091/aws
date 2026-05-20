# Documentación Detallada: API y Worker

Este documento explica en detalle el funcionamiento del código de la **API** (`api/main.py`) y del **Worker** (`worker/main.py`). Ambos componentes forman el núcleo de la arquitectura asíncrona (orientada a eventos) de este proyecto, utilizando **RabbitMQ** como intermediario (Message Broker) y **PostgreSQL** como almacenamiento persistente.

---

## 1. La API REST (El Productor)
**Archivo:** `api/main.py` o dentro de `install_api.sh`

La API está construida con el framework **FastAPI** en Python. Su responsabilidad principal es interactuar con el usuario (o cliente frontend), recibir peticiones, registrar que una tarea ha comenzado y **delegar el trabajo pesado** enviándolo a una cola de mensajes. Nunca hace el trabajo pesado por sí misma.

### Partes Principales de la API:

#### A. Gestión de Conexiones (PostgreSQL y RabbitMQ)
*   `PG_HOST` y `RABBITMQ_HOST`: Variables que almacenan las IPs de los servidores. Estas IPs son inyectadas dinámicamente por Terraform durante el despliegue en AWS.
*   `get_db_connection()`: Función que usa la librería `psycopg2` para conectarse a PostgreSQL.
*   `connect_rabbitmq()`: Función que usa la librería `pika` para conectarse a RabbitMQ. Tiene lógica de "reintentos" (`retries` y `delay`) para evitar fallos si RabbitMQ tarda en encender.

#### B. Funciones de Base de Datos
*   `ensure_tables()`: Se asegura de que las tablas `tasks` y `orders` existan en la base de datos al arrancar la aplicación.
*   `insert_task()`: **Crucial para la trazabilidad**. Cuando llega una nueva petición, esta función guarda la tarea en PostgreSQL con un estado inicial de `"pending"`. Así, el usuario puede consultar el estado de su tarea inmediatamente, incluso si el Worker aún no la ha procesado.

#### C. Función de Encolado (El Productor)
*   `publish_message(queue, message)`: Esta es la función que actúa como Productor. 
    1. Genera un ID único para la tarea usando el tiempo actual (`task_17...`).
    2. Inserta la tarea en PostgreSQL como `"pending"`.
    3. Se conecta a RabbitMQ y declara la cola (`"tasks"`).
    4. Usa `channel.basic_publish()` para enviar el diccionario de Python (convertido a texto JSON) a la cola de RabbitMQ. Se usa `delivery_mode=2` para asegurar que el mensaje persista en el disco de RabbitMQ y no se borre si el servidor se reinicia.

#### D. Endpoints (Rutas HTTP)
*   `GET /tasks` y `GET /tasks/{task_id}`: Rutas de lectura. Se conectan a PostgreSQL para devolver la lista de tareas y su estado actual (`pending`, `completed`, etc.).
*   `POST /task`: La ruta que usa el usuario para iniciar un proceso. Llama a `publish_message` y retorna el `task_id` al usuario de manera instantánea, sin hacerle esperar a que el trabajo termine.

---

## 2. El Worker Asíncrono (El Consumidor)
**Archivo:** `worker/main.py` o dentro de `install_worker.sh`

El Worker es un script de Python en segundo plano que **nunca duerme**. No tiene rutas HTTP ni se comunica directamente con el usuario. Su única misión es escuchar silenciosamente a RabbitMQ, tomar el siguiente mensaje disponible, realizar el "trabajo pesado" y actualizar la base de datos.

### Partes Principales del Worker:

#### A. Conexión y Bucle Infinito (`main()`)
A diferencia de la API que responde por petición, el Worker se ejecuta en un bucle infinito.
1.  Se conecta a PostgreSQL y RabbitMQ.
2.  Declara la cola `"tasks"` (para asegurarse de que exista).
3.  `channel.basic_qos(prefetch_count=1)`: Le dice a RabbitMQ: *"Solo envíame 1 tarea a la vez. No me des la siguiente hasta que haya terminado con esta"*. Esto distribuye la carga equitativamente si tuvieras múltiples servidores Worker.
4.  `channel.basic_consume(...)`: Configura la función que se disparará automáticamente cada vez que llegue un mensaje.
5.  `channel.start_consuming()`: Inicia el bucle infinito. El script se queda atrapado en esta línea escuchando indefinidamente.

#### B. Procesamiento del Mensaje (`process_message()`)
Cuando llega un mensaje, esta función se ejecuta:
1.  **Parseo**: Convierte el texto JSON de vuelta a un diccionario de Python.
2.  **Enrutamiento (`action`)**: Lee la acción requerida.
    *   Si es `"create_task"`: Simula un trabajo demorado con `time.sleep(1)`. Luego, actualiza el estado en la tabla `tasks` a `"completed"` e inserta los datos finales en la tabla `orders`.
    *   Si es `"delete_task"`: Simula un trabajo rápido (`time.sleep(0.5)`) y cambia el estado a `"deleted"`.

#### C. Confirmación (Acknowledgment)
*   `ch.basic_ack(delivery_tag=method.delivery_tag)`: Esta línea es vital. Se ejecuta al final de `on_message()`. Le avisa a RabbitMQ: *"Ya terminé de procesar esta tarea y guardé los resultados en la base de datos. Ya puedes borrar este mensaje de la cola de forma segura"*. Si el Worker falla o se apaga antes de esta línea, RabbitMQ sabrá que la tarea no terminó y se la reenviará a otro Worker.

---

## 3. Resumen: El Flujo Completo Paso a Paso

Imagina el flujo de una petición de esta manera:

1.  **[API] Recepción:** El usuario envía un JSON al endpoint `POST /task`.
2.  **[API] Registro Inicial:** La API crea el `task_123` y lo guarda en PostgreSQL como `"pending"`.
3.  **[API] Encolado:** La API manda el mensaje JSON a RabbitMQ a la cola `"tasks"`.
4.  **[API] Respuesta Rápida:** La API cierra sus conexiones y le responde un `200 OK` al usuario en milisegundos con su `task_123`. El usuario ya puede irse y consultar luego.
5.  **[RabbitMQ] Retención:** RabbitMQ guarda el mensaje de forma segura en memoria/disco.
6.  **[Worker] Consumo:** El Worker, que está escuchando, recibe el mensaje casi al instante de parte de RabbitMQ.
7.  **[Worker] Trabajo Pesado:** El Worker lee el mensaje, hace el trabajo lento (comunicación externa, cálculos, procesamiento de archivos, etc.).
8.  **[Worker] Guardado Final:** El Worker se conecta a PostgreSQL, busca `task_123` y le cambia el estado a `"completed"`.
9.  **[Worker] Acknowledge:** El Worker le avisa a RabbitMQ que ya acabó y RabbitMQ elimina el mensaje definitivamente.
10. **[Usuario] Consulta Final:** El usuario entra a `GET /tasks/task_123` y ya ve que su proceso dice `"completed"`.
