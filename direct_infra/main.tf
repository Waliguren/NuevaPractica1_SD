provider "aws" { 
  region = "us-east-1" 
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter { 
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"] 
  }
  filter { 
    name   = "virtualization-type"
    values = ["hvm"] 
  }
}

# ==========================================
# SECURITY GROUPS (Arquitectura Directa)
# ==========================================

resource "aws_security_group" "client_sg" {
  name = "direct_client_sg_v2"
  
  ingress { 
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }
  
  egress { 
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] 
  }
}

resource "aws_security_group" "nginx_sg" {
  name = "direct_nginx_sg_v2"
  
  ingress { 
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }
  
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
}

resource "aws_security_group" "worker_sg" {
  name = "direct_worker_sg_v2"
  
  ingress { 
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }
  
  ingress { 
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.nginx_sg.id] 
  }
  
  egress { 
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] 
  }
}

resource "aws_security_group" "redis_sg" {
  name = "direct_redis_sg_v2"
  
  ingress { 
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }
  
  ingress { 
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.worker_sg.id, aws_security_group.client_sg.id] 
  }
  
  egress { 
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] 
  }
}

# ==========================================
# INSTANCIAS EC2
# ==========================================

resource "aws_instance" "redis" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  key_name               = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.redis_sg.id]
  tags                   = { Name = "Redis-Direct" }

  user_data = <<-EOF
              #!/bin/bash
              dnf update -y
              dnf install -y docker
              systemctl start docker && systemctl enable docker
              docker run -d --name mi-redis --restart unless-stopped -p 6379:6379 redis:latest redis-server --requirepass "admin123"
              EOF
}

resource "aws_instance" "worker" {
  count                  = 2
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  key_name               = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.worker_sg.id]
  tags                   = { Name = "Worker-Direct-${count.index + 1}" }

  user_data = <<-EOF
              #!/bin/bash
              dnf update -y
              dnf install -y python3 python3-pip git
              
              cd /home/ec2-user
              git clone https://github.com/waliguren/nuevapractica1_sd.git repo
              mv repo/archivosWorker ./
              rm -rf repo
              
              cd archivosWorker
              python3 -m venv venv
              venv/bin/pip install fastapi uvicorn redis pydantic pika
              
              export REDIS_HOST="${aws_instance.redis.private_ip}"
              nohup venv/bin/uvicorn direct_worker:app --host 0.0.0.0 --port 5000 > worker.log 2>&1 &
              EOF
}

resource "aws_instance" "nginx" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.small"
  key_name               = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.nginx_sg.id]
  tags                   = { Name = "NGINX-Balancer" }

  user_data = <<-EOF
    #!/bin/bash
    
    # 1. Prevención del bloqueo de DNF (Espera a que Amazon Linux termine sus actualizaciones invisibles)
    while pidof dnf > /dev/null; do sleep 5; done
    
    dnf update -y
    dnf install -y docker
    systemctl start docker
    systemctl enable docker
    
    # 2. Generación del archivo NGINX con sintaxis de inyección directa de Terraform
    cat <<'EOT' > /home/ec2-user/nginx.conf
    events { 
        worker_connections 4096; 
    }
    http { 
        upstream workers_api {
            ${join("\n            ", [for w in aws_instance.worker : "server ${w.private_ip}:5000;"])}
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
    
    # 3. Despliegue del contenedor
    docker run -d --name mi-nginx --restart unless-stopped -p 80:80 -v /home/ec2-user/nginx.conf:/etc/nginx/nginx.conf:ro nginx:latest
  EOF
}

resource "aws_instance" "client" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  key_name               = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.client_sg.id]
  tags                   = { Name = "Client-Direct" }

  user_data = <<-EOF
              #!/bin/bash
              dnf update -y
              dnf install -y python3 python3-pip git
              
              cd /home/ec2-user
              git clone https://github.com/waliguren/nuevapractica1_sd.git repo
              mv repo/archivosCliente ./
              rm -rf repo
              
              cd archivosCliente
              python3 -m venv venv
              venv/bin/pip install aiohttp uvloop redis
              
              echo "export NGINX_HOST=${aws_instance.nginx.private_ip}" >> /home/ec2-user/.bashrc
              echo "export REDIS_HOST=${aws_instance.redis.private_ip}" >> /home/ec2-user/.bashrc
              EOF
}

output "CLIENTE_SSH" { 
  value = "ssh -i clave-rabbitmq-server.pem ec2-user@${aws_instance.client.public_ip}" 
}