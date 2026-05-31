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
# SECURITY GROUPS (Arquitectura Indirecta)
# ==========================================
resource "aws_security_group" "client_sg" {
  name = "indirect_client_sg"

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

resource "aws_security_group" "rabbitmq_sg" {
  name = "indirect_rabbitmq_sg"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 15672
    to_port     = 15672
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  } # Panel Web UI
  ingress {
    from_port   = 5672
    to_port     = 5672
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  } # AMQP para Workers y Cliente
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "worker_sg" {
  name = "indirect_worker_sg"

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

resource "aws_security_group" "redis_sg" {
  name = "indirect_redis_sg"

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
  tags                   = { Name = "Redis-Indirect" }

  user_data = <<-EOF
    #!/bin/bash
    while pidof dnf > /dev/null; do sleep 5; done
    dnf update -y && dnf install docker -y
    systemctl start docker && systemctl enable docker
    docker run -d --name mi-redis --restart unless-stopped -p 6379:6379 redis:latest redis-server --requirepass "admin123"
  EOF
}

resource "aws_instance" "rabbitmq" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.small"
  key_name               = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.rabbitmq_sg.id]
  tags                   = { Name = "RabbitMQ-Server" }

  user_data = <<-EOF
    #!/bin/bash
    # Límites de Kernel para absorber la cola masiva
    echo "fs.file-max = 2097152" >> /etc/sysctl.conf
    echo "net.core.somaxconn = 65535" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_max_syn_backlog = 65535" >> /etc/sysctl.conf
    echo "net.ipv4.ip_local_port_range = 1024 65535" >> /etc/sysctl.conf
    sysctl -p
    echo "* soft nofile 65535" >> /etc/security/limits.conf
    echo "* hard nofile 65535" >> /etc/security/limits.conf

    while pidof dnf > /dev/null; do sleep 5; done
    dnf update -y && dnf install docker -y
    systemctl start docker && systemctl enable docker
    
    # Arrancamos RabbitMQ con credenciales personalizadas para evitar el bloqueo remoto de "guest"
    docker run -d --name mi-rabbit --restart unless-stopped --ulimit nofile=65535:65535 -e RABBITMQ_DEFAULT_USER=admin -e RABBITMQ_DEFAULT_PASS=admin123 -p 5672:5672 -p 15672:15672 rabbitmq:3-management
  EOF
}

resource "aws_instance" "worker" {
  count                  = 2
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  key_name               = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.worker_sg.id]
  tags                   = { Name = "Worker-Indirect-${count.index + 1}" }

  user_data = <<-EOF
    #!/bin/bash
    # Límites de red para los workers
    echo "fs.file-max = 2097152" >> /etc/sysctl.conf
    echo "net.core.somaxconn = 65535" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_max_syn_backlog = 65535" >> /etc/sysctl.conf
    echo "net.ipv4.ip_local_port_range = 1024 65535" >> /etc/sysctl.conf
    sysctl -p
    echo "* soft nofile 65535" >> /etc/security/limits.conf
    echo "* hard nofile 65535" >> /etc/security/limits.conf

    while pidof dnf > /dev/null; do sleep 5; done
    dnf update -y && dnf install -y python3 python3-pip git
    
    cd /home/ec2-user 
    git clone https://github.com/waliguren/nuevapractica1_sd.git repo
    mv repo/archivosWorker ./
    rm -rf repo
    
    # Parchear worker con version corregida (parseo de mensajes + entradas no numeradas)
    python3 -c "
import re
c = open('/home/ec2-user/archivosWorker/indirect_worker.py').read()
n = '''def procesar_mensaje(ch, method, props, body):
    peticion = body.decode().strip()
    partes = peticion.split()
    if len(partes) < 2 or partes[0] != 'BUY':
        respuesta_http = '400'
    elif len(partes) == 3:
        disponibles = r.decr('entradas_disponibles')
        if disponibles >= 0:
            respuesta_http = '200'
        else:
            r.incr('entradas_disponibles')
            respuesta_http = '400'
    elif len(partes) == 4:
        asiento = partes[2]
        exito = r.setnx(f'asiento_{asiento}', 'vendido')
        respuesta_http = '200' if exito else '409'
    else:
        respuesta_http = '400'
    print(f'{peticion} -> {respuesta_http}')
    if props.reply_to and props.correlation_id:
        ch.basic_publish(exchange='', routing_key=props.reply_to, properties=pika.BasicProperties(correlation_id=props.correlation_id), body=respuesta_http)
    ch.basic_ack(delivery_tag=method.delivery_tag)'''
c = re.sub(r'def procesar_mensaje.*?ch\.basic_ack\(delivery_tag=method\.delivery_tag\)', n, c, flags=re.DOTALL)
open('/home/ec2-user/archivosWorker/indirect_worker.py', 'w').write(c)
print('Worker corregido')
"
    
    cd archivosWorker
    
    # Añadimos variables de entorno
    echo "export REDIS_HOST=${aws_instance.redis.private_ip}" >> /home/ec2-user/.bashrc
    echo "export RABBITMQ_HOST=${aws_instance.rabbitmq.private_ip}" >> /home/ec2-user/.bashrc
    export REDIS_HOST=${aws_instance.redis.private_ip}
    export RABBITMQ_HOST=${aws_instance.rabbitmq.private_ip}
    
    python3 -m venv venv && venv/bin/pip install redis pika
    
    ulimit -n 65535
    nohup venv/bin/python3 indirect_worker.py > worker.log 2>&1 &
  EOF
}

resource "aws_instance" "client" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  key_name               = "clave-rabbitmq-server"
  vpc_security_group_ids = [aws_security_group.client_sg.id]
  tags                   = { Name = "Client-Indirect" }

  user_data = <<-EOF
    #!/bin/bash
    # Límites de red para el cliente
    echo "fs.file-max = 2097152" >> /etc/sysctl.conf
    echo "net.core.somaxconn = 65535" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_max_syn_backlog = 65535" >> /etc/sysctl.conf
    echo "net.ipv4.ip_local_port_range = 1024 65535" >> /etc/sysctl.conf
    sysctl -p
    echo "* soft nofile 65535" >> /etc/security/limits.conf
    echo "* hard nofile 65535" >> /etc/security/limits.conf

    while pidof dnf > /dev/null; do sleep 5; done
    dnf update -y && dnf install -y python3 python3-pip git
    
    cd /home/ec2-user 
    git clone https://github.com/waliguren/nuevapractica1_sd.git repo
    mv repo/archivosCliente ./
    rm -rf repo
    
    cd archivosCliente
    python3 -m venv venv && venv/bin/pip install pika redis aiohttp uvloop
    
    # Generar benchmark de alta contencion (80% en 5% asientos)
    python3 -c "import random;random.seed(42);f=open('benchmarks/benchmark_numbered_hotspot.txt','w');[f.write(f'BUY user{i+1:05d} {random.randint(1,1000) if i<48000 else random.randint(1001,20000)} {i+1:05d}\n') for i in range(60000)];print('Hotspot generado: 48000/60000 en asientos 1-1000')"
    
    # Guardamos las IPs para el cliente y el ulimit automático
    echo "export RABBITMQ_HOST=${aws_instance.rabbitmq.private_ip}" >> /home/ec2-user/.bashrc
    echo "export REDIS_HOST=${aws_instance.redis.private_ip}" >> /home/ec2-user/.bashrc
    echo "ulimit -n 65535" >> /home/ec2-user/.bashrc
  EOF
}

output "RABBITMQ_PANEL_WEB" {
  value = "http://${aws_instance.rabbitmq.public_ip}:15672 (user: admin / pass: admin123)"
}

output "CLIENTE_SSH" {
  value = "ssh -i clave-rabbitmq-server.pem ec2-user@${aws_instance.client.public_ip}"
}