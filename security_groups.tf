# ==========================================
# Security Group: RabbitMQ
# ==========================================
resource "aws_security_group" "rabbitmq_sg" {
  name        = "rabbitmq_sg"
  description = "Allow SSH, AMQP, and RabbitMQ Management API"
  vpc_id      = var.vpc_id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # RabbitMQ AMQP
  ingress {
    from_port   = 5672
    to_port     = 5672
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # RabbitMQ Management API
  ingress {
    from_port   = 15672
    to_port     = 15672
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rabbitmq_sg"
  }
}

# ==========================================
# Security Group: HAProxy Load Balancer EC2
# ==========================================
resource "aws_security_group" "haproxy_sg" {
  name        = "haproxy_sg"
  description = "Allow SSH and HTTP to the HAProxy EC2 Load Balancer"
  vpc_id      = var.vpc_id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP (punto de entrada público del balanceador)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "haproxy_sg"
  }
}

# ==========================================
# Security Group: Docker / REST API
# ==========================================
resource "aws_security_group" "api_sg" {
  name        = "api_sg"
  description = "Allow SSH and HTTP only from ALB"
  vpc_id      = var.vpc_id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP solo desde el HAProxy EC2
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.haproxy_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "api_sg"
  }
}

# ==========================================
# Security Group: Async Worker
# ==========================================
resource "aws_security_group" "worker_sg" {
  name        = "worker_sg"
  description = "Allow SSH only for Worker (Initiates outbound connections)"
  vpc_id      = var.vpc_id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # El Worker consume mensajes (Conexión saliente hacia RabbitMQ/Postgres)
  # por ende no necesita puertos Ingress extra.
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "worker_sg"
  }
}

# ==========================================
# Security Group: PostgreSQL
# ==========================================
resource "aws_security_group" "postgres_sg" {
  name        = "postgres_sg"
  description = "Allow SSH and PostgreSQL"
  vpc_id      = var.vpc_id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # PostgreSQL
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "postgres_sg"
  }
}

