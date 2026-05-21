provider "aws" { region = "us-east-1" }

data "aws_ami" "ubuntu" {
  most_recent = true
  filter { name = "name"; values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"] }
  filter { name = "virtualization-type"; values = ["hvm"] }
  owners = ["099720109477"]
}

# SECURITY GROUPS (Solo los necesarios para Directa)
resource "aws_security_group" "client_sg" {
  name = "direct_client_sg"
  ingress { from_port = 22; to_port = 22; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "nginx_sg" {
  name = "direct_nginx_sg"
  ingress { from_port = 22; to_port = 22; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 80; to_port = 80; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "worker_sg" {
  name = "direct_worker_sg"
  ingress { from_port = 22; to_port = 22; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 5000; to_port = 5000; protocol = "tcp"; security_groups = [aws_security_group.nginx_sg.id] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "redis_sg" {
  name = "direct_redis_sg"
  ingress { from_port = 22; to_port = 22; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 6379; to_port = 6379; protocol = "tcp"; security_groups = [aws_security_group.worker_sg.id, aws_security_group.client_sg.id] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

# INSTANCIAS
resource "aws_instance" "redis" {
  ami = data.aws_ami.ubuntu.id; instance_type = "t2.micro"; key_name = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.redis_sg.id]
  tags = { Name = "Redis-Direct" }
  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y && apt-get install docker.io -y
              systemctl start docker && systemctl enable docker
              docker run -d --name mi-redis --restart unless-stopped -p 6379:6379 redis:latest redis-server --requirepass "admin123"
              EOF
}

resource "aws_instance" "worker" {
  count = 2
  ami = data.aws_ami.ubuntu.id; instance_type = "t2.micro"; key_name = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.worker_sg.id]
  tags = { Name = "Worker-Direct-${count.index + 1}" }
  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y && apt-get install -y python3-pip python3-venv git
              cd /home/ubuntu && git clone https://github.com/waliguren/nuevapractica1_sd.git practica && cd practica
              sed -i 's/IP_DE_TU_REDIS/${aws_instance.redis.private_ip}/g' archivosWorker/direct_worker.py
              python3 -m venv venv && venv/bin/pip install fastapi uvicorn redis pydantic pika
              nohup venv/bin/uvicorn archivosWorker.direct_worker:app --host 0.0.0.0 --port 5000 > worker.log 2>&1 &
              EOF
}

resource "aws_instance" "nginx" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  key_name               = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.nginx_sg.id]
  tags                   = { Name = "NGINX-Balancer" }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y && apt-get install docker.io -y
              systemctl start docker
              
              cat <<EOT > /home/ubuntu/nginx.conf
              events { worker_connections 4096; }
              http { 
                  upstream workers_api {
                      %{~ for w in aws_instance.worker ~}
                      server ${w.private_ip}:5000;
                      %{~ endfor ~}
                  }
                  server { 
                      listen 80; 
                      location / { 
                          proxy_pass http://workers_api; 
                          proxy_connect_timeout 300s; 
                          proxy_send_timeout 300s; 
                          proxy_read_timeout 300s; 
                      } 
                  } 
              }
              EOT
              docker run -d --name mi-nginx --restart unless-stopped -p 80:80 -v /home/ubuntu/nginx.conf:/etc/nginx/nginx.conf:ro nginx:latest
              EOF
}

resource "aws_instance" "client" {
  ami = data.aws_ami.ubuntu.id; instance_type = "t2.micro"; key_name = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.client_sg.id]
  tags = { Name = "Client-Direct" }
  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y && apt-get install -y python3-pip python3-venv git
              cd /home/ubuntu && git clone https://github.com/waliguren/nuevapractica1_sd.git practica && cd practica
              
              python3 -m venv venv && venv/bin/pip install fastapi uvicorn redis pydantic
              
              # MAGIA: Inyectamos la IP en el sistema justo antes de arrancar
              export REDIS_HOST="${aws_instance.redis.private_ip}"
              
              # Arrancamos Uvicorn (heredará la variable exportada)
              nohup venv/bin/uvicorn archivosWorker.direct_worker:app --host 0.0.0.0 --port 5000 > worker.log 2>&1 &
              EOF
}

output "CLIENTE_SSH" { value = "ssh -i clave-rabbitmq-server.pem ubuntu@${aws_instance.client.public_ip}" }