# Despliegue de Microservicios Asíncronos en AWS (Learner Lab)

## Descripción

Arquitectura orientada a eventos con FastAPI, RabbitMQ, PostgreSQL y un Worker asíncrono, desplegado 100% como Infraestructura como Código (IaC) usando Terraform en AWS Learner Lab.

## Arquitectura del Proyecto

- **Load Balancer (HAProxy)**: 1 Instancia EC2 como único punto de entrada público.
- **Backend API (FastAPI)**: 2 Instancias EC2 ubicadas en distintas Zonas de Disponibilidad (Alta Disponibilidad).
- **Message Broker (RabbitMQ)**: 1 Instancia EC2.
- **Worker (Python)**: 1 Instancia EC2 que consume mensajes de la cola de forma asíncrona.
- **Base de Datos (PostgreSQL)**: 1 Instancia EC2.

---

## 1. Requisitos Previos

- Docker instalado localmente (usaremos un contenedor de desarrollo para aislar el entorno de Terraform y AWS CLI).
- Cuenta activa en AWS Learner Lab.
- Credenciales temporales (`aws_access_key_id`, `aws_secret_access_key`, `aws_session_token`).

---

## 2. Instrucciones de Configuración Inicial

### Paso 2.1: Entrar al entorno Docker

Para asegurar que las versiones de terraform y aws-cli sean consistentes en cualquier máquina, levantamos el entorno de desarrollo:

```bash
docker build -t iot_dev_environment_image .
docker run -it --name iot_dev_environment -v "$(pwd):/app" iot_dev_environment_image bash
```

_(Todos los pasos siguientes deben ejecutarse dentro de este contenedor)._

### Paso 2.2: Configurar las Credenciales de AWS

En la consola de AWS Learner Lab, haz clic en **"AWS Details" -> "Show"** y copia las credenciales de la consola. En tu terminal del contenedor, ejecuta:

```bash
aws configure set aws_access_key_id TU_ACCESS_KEY_ID
aws configure set aws_secret_access_key TU_SECRET_ACCESS_KEY
aws configure set aws_session_token TU_SESSION_TOKEN
aws configure set region us-east-1
```

_(Para verificar que tienes conexión ejecuta: `aws sts get-caller-identity`)_

### Paso 2.3: Obtener los IDs de tu propia cuenta AWS

Para correr este proyecto en otra máquina o cuenta, necesitas obtener tus propios IDs de AWS. Ejecuta los siguientes comandos y anota los resultados:

**1. Obtener la VPC ID:**

```bash
aws ec2 describe-vpcs --query "Vpcs[0].VpcId" --output text
```

**2. Obtener dos Subnets PÚBLICAS (Zonas de Disponibilidad distintas):**
_⚠️ Muy Importante: Debes escoger subredes que digan "True" en la última columna, de lo contrario no tendrás acceso por Internet._

```bash
aws ec2 describe-subnets --filters "vpc-0258bccb3effe2eb0" --query "Subnets[*].[SubnetId, AvailabilityZone, MapPublicIpOnLaunch]" --output table
```

**3. Obtener el nombre de la Llave de Acceso (Key Pair):**

```bash
aws ec2 describe-key-pairs --query "KeyPairs[*].KeyName" --output text
```

_(En AWS Learner Lab suele llamarse `vockey`)_.

### Paso 2.4: Actualizar el archivo `variables.tf`

Abre el archivo `variables.tf` en el directorio principal y reemplaza los valores por defecto con la información que acabas de anotar:

- `vpc_id`: Resultado del paso 1.
- `subnet_id`: Una subnet pública del paso 2.
- `subnet_id_2`: Otra subnet pública (en una zona diferente) del paso 2.
- `key_name`: Resultado del paso 3 (`vockey`).

---

## 3. Despliegue de Infraestructura

Dentro del contenedor, inicializa Terraform y aplica los cambios:

```bash
terraform init
terraform apply
```

Escribe `yes` cuando te pregunte.
Al final, Terraform imprimirá una lista de IPs. Copia el valor de **`haproxy_public_ip`**.
⏳ **Importante:** Espera de 3 a 5 minutos después de que Terraform termine. Aunque las máquinas existan, AWS sigue instalando Docker, PostgreSQL y descargando repositorios de Python en segundo plano.

---

## 4. Pruebas de la Aplicación

1. Abre tu navegador web (asegurándote de que no se cambie a "https") e ingresa a: `http://<haproxy_public_ip>/docs`.
2. **Prueba Productor:**
   - Despliega la caja verde `POST /Tasks` -> `Try it out` -> `Execute`.
   - Copia el `"task_id"` devuelto y nota que el `"status"` es `"pending"`.
3. **Prueba Consumidor (Worker asíncrono):**
   - Despliega `GET /Tasks/{id}` -> `Try it out` -> pega el `task_id` -> `Execute`.
   - Verás que el estado cambió automáticamente a `"completed"`.
4. **Verificar Postgres:**
   - Despliega `GET /Orders` -> `Try it out` -> `Execute`. Verás los datos procesados e insertados por el worker.

---

## 5. Lecciones Aprendidas (Troubleshooting y Errores Solucionados)

Durante el desarrollo nos topamos con restricciones típicas de entornos "Sandbox" (como el Learner Lab) y problemas de arquitectura que se resolvieron así:

1. **Error IAM (`AccessDenied` al hacer `terraform apply`):**
   - _Problema:_ El Learner Lab bloquea la creación de roles IAM personalizados (`aws_iam_role`).
   - _Solución:_ Usamos el rol preexistente `LabInstanceProfile` nativo del laboratorio asignándolo directamente al `iam_instance_profile` de las máquinas en `main.tf`.

2. **Timeouts en el Balanceador HAProxy (`Took too long to respond`):**
   - _Problema:_ Habíamos asignado `subnet_id`s en `variables.tf` que correspondían a "Private Subnets" (subredes sin acceso desde Internet Gateway). Aunque AWS les asignó IP Pública, el router nativo de AWS botaba las peticiones.
   - _Solución:_ Usamos comandos de AWS CLI para auditar las subnets y descubrir cuáles tenían el flag `MapPublicIpOnLaunch=True`, migrando los recursos a las subredes públicas.

3. **Error al usar AWS Systems Manager (SSM Parameter Store):**
   - _Problema:_ Al intentar que Python leyera las IPs de las bases de datos de forma dinámica a través de `boto3`, el código fallaba porque el rol del Learner Lab no incluía el permiso explícito `ssm:GetParameter`.
   - _Solución:_ Eliminamos la dependencia de Boto3/SSM y aprovechamos el motor de Terraform. Usamos la función `templatefile()` en `main.tf` para inyectar dinámicamente las IPs Privadas (`aws_instance.postgres.private_ip`) en los scripts de instalación de la API y el Worker (`install_api.sh`).

4. **Error `503 Service Unavailable` y Crash loops en FastAPI:**
   - _Problema:_ El script `install_postgres.sh` creaba por defecto una base de datos llamada `mydb`, pero el código Python exigía conectarse a `tasksdb`. Python detectaba el error fatal y el contenedor se reiniciaba en un loop infinito. HAProxy notaba las caídas en el endpoint `/health` y respondía con `503`.
   - _Solución:_ Se emparejaron las variables. Se actualizó el script bash de la base de datos para que construyera exactamente la BD y los usuarios que espera la aplicación (`tasksdb`).

---

## 6. Limpieza del Proyecto

⚠️ **IMPORTANTE:** Para evitar consumir todos los créditos del laboratorio, destruye la infraestructura siempre que termines tus pruebas.

```bash
terraform destroy
```
