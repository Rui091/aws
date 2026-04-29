# 1. RabbitMQ EC2
resource "aws_instance" "rabbitmq" {
  ami               = var.ami_id
  instance_type     = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.rabbitmq_sg.id]
  user_data         = file("${path.module}/install_rabbitmq.sh")

  tags = {
    Name    = "RabbitMQ-Server"
    Role    = "MessageBroker"
  }
}

# 2. Docker / API Rest EC2 (x2 - uno por AZ)
resource "aws_instance" "api_server" {
  count                = 2
  ami                  = var.ami_id
  instance_type        = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = count.index == 0 ? var.subnet_id : var.subnet_id_2
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.api_sg.id]
  user_data                   = templatefile("${path.module}/install_api.sh", {
    rabbitmq_ip = aws_instance.rabbitmq.private_ip
    postgres_ip = aws_instance.postgres.private_ip
  })
  iam_instance_profile        = "LabInstanceProfile"

  tags = {
    Name = "Docker-API-Server-${count.index + 1}"
    Role = "BackendAPI"
  }
}

# 3a. HAProxy Load Balancer EC2
# Corre HAProxy como contenedor Docker (igual que simple_balancer)
resource "aws_instance" "haproxy" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.haproxy_sg.id]

  user_data = templatefile("${path.module}/install_haproxy.sh", {
    api_server_1_ip = aws_instance.api_server[0].private_ip
    api_server_2_ip = aws_instance.api_server[1].private_ip
  })

  tags = {
    Name = "HAProxy-LoadBalancer"
    Role = "LoadBalancer"
  }
}

# 3. Worker EC2
resource "aws_instance" "worker" {
  ami                  = var.ami_id
  instance_type        = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.worker_sg.id]
  user_data                   = templatefile("${path.module}/install_worker.sh", {
    rabbitmq_ip = aws_instance.rabbitmq.private_ip
    postgres_ip = aws_instance.postgres.private_ip
  })
  iam_instance_profile        = "LabInstanceProfile"

  tags = {
    Name    = "Worker-Server"
    Role    = "AsyncWorker"
  }
}

# 4. PostgreSQL EC2
resource "aws_instance" "postgres" {
  ami               = var.ami_id
  instance_type     = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.postgres_sg.id]
  user_data         = file("${path.module}/install_postgres.sh")

  tags = {
    Name    = "Postgres-Server"
    Role    = "Database"
  }
}



# ==========================================
# AWS Systems Manager Parameter Store
# ==========================================

resource "aws_ssm_parameter" "rabbitmq_ip" {
  name  = "/message-queue/dev/rabbitmq/public_ip"
  type  = "String"
  value = aws_instance.rabbitmq.private_ip
  description = "Public IP for RabbitMQ Server"
}

resource "aws_ssm_parameter" "api_ip" {
  name  = "/message-queue/dev/api/public_ip"
  type  = "String"
  value = aws_instance.haproxy.private_ip
  description = "IP pública del HAProxy Load Balancer EC2"
}

resource "aws_ssm_parameter" "worker_ip" {
  name  = "/message-queue/dev/worker/public_ip"
  type  = "String"
  value = aws_instance.worker.private_ip
  description = "Public IP for Async Worker Server"
}

resource "aws_ssm_parameter" "postgres_ip" {
  name        = "/message-queue/dev/postgres/public_ip"
  type        = "String"
  value       = aws_instance.postgres.private_ip
  description = "Public IP for PostgreSQL Server"
}


