provider "aws" { region = "us-east-1" }

data "aws_ami" "ubuntu" {
  most_recent = true
  filter { name = "name"; values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"] }
  filter { name = "virtualization-type"; values = ["hvm"] }
  owners = ["099720109477"]
}

# SECURITY GROUPS (Solo los necesarios para Indirecta)
resource "aws_security_group" "client_sg" {
  name = "indirect_client_sg"
  ingress { from_port = 22; to_port = 22; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "rabbitmq_sg" {
  name = "indirect_rabbitmq_sg"
  ingress { from_port = 22; to_port = 22; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 15672; to_port = 15672; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] } # Panel Web UI
  ingress { from_port = 5672; to_port = 5672; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] } # Abierto para todos dentro de AWS
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "worker_sg" {
  name = "indirect_worker_sg"
  ingress { from_port = 22; to_port = 22; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "redis_sg" {
  name = "indirect_redis_sg"
  ingress { from_port = 22; to_port = 22; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 6379; to_port = 6379; protocol = "tcp"; security_groups = [aws_security_group.worker_sg.id, aws_security_group.client_sg.id] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

# INSTANCIAS
resource "aws_instance" "redis" {
  ami = data.aws_ami.ubuntu.id; instance_type = "t2.micro"; key_name = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.redis_sg.id]
  tags = { Name = "Redis-Indirect" }
  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y && apt-get install docker.io -y
              systemctl start docker && systemctl enable docker
              docker run -d --name mi-redis --restart unless-stopped -p 6379:6379 redis:latest redis-server --requirepass "admin123"
              EOF
}

resource "aws_instance" "rabbitmq" {
  ami = data.aws_ami.ubuntu.id; instance_type = "t2.micro"; key_name = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.rabbitmq_sg.id]
  tags = { Name = "RabbitMQ-Server" }
  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y && apt-get install docker.io -y
              systemctl start docker && systemctl enable docker
              docker run -d --name mi-rabbit --restart unless-stopped -p 5672:5672 -p 15672:15672 rabbitmq:3-management
              EOF
}

resource "aws_instance" "worker" {
  count = 2
  ami = data.aws_ami.ubuntu.id; instance_type = "t2.micro"; key_name = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.worker_sg.id]
  tags = { Name = "Worker-Indirect-${count.index + 1}" }
  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y && apt-get install -y python3-pip python3-venv git
              cd /home/ubuntu && git clone https://github.com/waliguren/nuevapractica1_sd.git practica && cd practica
              
              # Inyectar la IP de Redis Y DE RABBITMQ en el código indirecto
              sed -i 's/IP_DE_TU_REDIS/${aws_instance.redis.private_ip}/g' archivosWorker/indirect_worker.py
              sed -i 's/IP_DE_RABBITMQ/${aws_instance.rabbitmq.private_ip}/g' archivosWorker/indirect_worker.py
              
              python3 -m venv venv && venv/bin/pip install redis pika
              
              # Arrancamos el worker indirecto (en vez del directo con uvicorn)
              nohup venv/bin/python3 archivosWorker/indirect_worker.py > worker.log 2>&1 &
              EOF
}

resource "aws_instance" "client" {
  ami = data.aws_ami.ubuntu.id; instance_type = "t2.micro"; key_name = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.client_sg.id]
  tags = { Name = "Client-Indirect" }
  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y && apt-get install -y python3-pip python3-venv git
              cd /home/ubuntu && git clone https://github.com/waliguren/nuevapractica1_sd.git practica && cd practica
              python3 -m venv venv && venv/bin/pip install pika redis
              
              # Guardamos las IPs en el perfil del usuario ubuntu
              echo "export RABBITMQ_HOST=${aws_instance.rabbitmq.private_ip}" >> /home/ubuntu/.bashrc
              echo "export REDIS_HOST=${aws_instance.redis.private_ip}" >> /home/ubuntu/.bashrc
              EOF
}

output "RABBITMQ_PANEL_WEB" { value = "http://${aws_instance.rabbitmq.public_ip}:15672 (user: guest / pass: guest)" }
output "CLIENTE_SSH" { value = "ssh -i clave-rabbitmq-server.pem ubuntu@${aws_instance.client.public_ip}" }