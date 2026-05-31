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
  count                  = 3
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  key_name               = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.worker_sg.id]
  tags                   = { Name = "Worker-Direct-${count.index + 1}" }

  user_data = <<-EOF
    #!/bin/bash
    
    # 1. Ajustes del Kernel
    echo "fs.file-max = 2097152" >> /etc/sysctl.conf
    echo "net.core.somaxconn = 65535" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_max_syn_backlog = 65535" >> /etc/sysctl.conf
    echo "net.ipv4.ip_local_port_range = 1024 65535" >> /etc/sysctl.conf
    sysctl -p
    echo "* soft nofile 65535" >> /etc/security/limits.conf
    echo "* hard nofile 65535" >> /etc/security/limits.conf

    # 2. Instalación de dependencias y código
    dnf update -y
    dnf install -y python3 python3-pip git
    
    cd /home/ec2-user
    git clone https://github.com/waliguren/nuevapractica1_sd.git repo
    mv repo/archivosWorker ./
    rm -rf repo
    
    cd archivosWorker
    python3 -m venv venv
    venv/bin/pip install fastapi uvicorn redis
    
    # 3. Inyectar la IP de Redis para que el Worker sepa dónde conectarse
    echo "export REDIS_HOST=${aws_instance.redis.private_ip}" >> /home/ec2-user/.bashrc
    export REDIS_HOST=${aws_instance.redis.private_ip}

    # 4. Aplicar el ulimit y arrancar la API
    ulimit -n 65535
    nohup venv/bin/uvicorn direct_worker:app --host 0.0.0.0 --port 5000 > worker.log 2>&1 &
  EOF
}

resource "aws_instance" "nginx" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.small"
  key_name               = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.nginx_sg.id]
  tags                   = { Name = "NGINX-Balancer" }

  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    
    # 1. Ajustes del Kernel para alto tráfico (Adiós cuello de botella)
    echo "fs.file-max = 2097152" >> /etc/sysctl.conf
    echo "net.core.somaxconn = 65535" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_max_syn_backlog = 65535" >> /etc/sysctl.conf
    echo "net.ipv4.ip_local_port_range = 1024 65535" >> /etc/sysctl.conf
    sysctl -p
    echo "* soft nofile 65535" >> /etc/security/limits.conf
    echo "* hard nofile 65535" >> /etc/security/limits.conf

    # 2. Instalación (Prevención de bloqueo DNF)
    while pidof dnf > /dev/null; do sleep 5; done
    dnf update -y
    dnf install -y docker
    systemctl start docker && systemctl enable docker
    
    # 3. NGINX Config (Aumentamos worker_connections)
    cat <<'EOT' > /home/ec2-user/nginx.conf
    events { 
        worker_connections 65535; 
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
    
    # 4. Lanzar NGINX pasándole el límite abierto (--ulimit)
    docker run -d --name mi-nginx --restart unless-stopped --ulimit nofile=65535:65535 -p 80:80 -v /home/ec2-user/nginx.conf:/etc/nginx/nginx.conf:ro nginx:latest
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
    
    # 1. Ajustes del Kernel para disparar sin ahogarse
    echo "fs.file-max = 2097152" >> /etc/sysctl.conf
    echo "net.core.somaxconn = 65535" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_max_syn_backlog = 65535" >> /etc/sysctl.conf
    echo "net.ipv4.ip_local_port_range = 1024 65535" >> /etc/sysctl.conf
    sysctl -p
    echo "* soft nofile 65535" >> /etc/security/limits.conf
    echo "* hard nofile 65535" >> /etc/security/limits.conf
    
    # 2. Instalación
    dnf update -y
    dnf install -y python3 python3-pip git
    
    cd /home/ec2-user
    git clone https://github.com/waliguren/nuevapractica1_sd.git repo
    mv repo/archivosCliente ./
    rm -rf repo
    
    cd archivosCliente
    python3 -m venv venv
    venv/bin/pip install aiohttp uvloop redis
    
    # Generar benchmark de alta contencion (80% en 5% asientos)
    python3 << 'PYEOF'
import random
random.seed(42)
with open('benchmarks/benchmark_numbered_hotspot.txt', 'w') as f:
    for i in range(60000):
        seat = random.randint(1, 1000) if i < 48000 else random.randint(1001, 20000)
        f.write(f'BUY user{i+1:05d} {seat} {i+1:05d}\n')
print('Benchmark hotspot generado: 48000/60000 en asientos 1-1000')
PYEOF
    
    # 3. Variables de entorno
    echo "export NGINX_HOST=${aws_instance.nginx.private_ip}" >> /home/ec2-user/.bashrc
    echo "export REDIS_HOST=${aws_instance.redis.private_ip}" >> /home/ec2-user/.bashrc
    
    # 4. Hacer que el ulimit se aplique automáticamente al entrar por SSH
    echo "ulimit -n 65535" >> /home/ec2-user/.bashrc
  EOF
}

output "CLIENTE_SSH" {
  value = "ssh -i clave-rabbitmq-server.pem ec2-user@${aws_instance.client.public_ip}"
}