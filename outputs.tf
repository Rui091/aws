output "rabbitmq_public_ip" {
  value = aws_instance.rabbitmq.public_ip
  description = "IP pública del servidor RabbitMQ"
}

output "haproxy_public_ip" {
  value       = aws_instance.haproxy.public_ip
  description = "IP pública del HAProxy Load Balancer EC2 (punto de entrada a la API)"
}

output "api_server_1_public_ip" {
  value       = aws_instance.api_server[0].public_ip
  description = "IP pública del API Server 1"
}

output "api_server_2_public_ip" {
  value       = aws_instance.api_server[1].public_ip
  description = "IP pública del API Server 2"
}

output "worker_public_ip" {
  value = aws_instance.worker.public_ip
  description = "IP pública del servidor Worker"
}

output "postgres_public_ip" {
  value = aws_instance.postgres.public_ip
  description = "IP pública del servidor PostgreSQL"
}

