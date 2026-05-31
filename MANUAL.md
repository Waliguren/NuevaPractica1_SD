# Manual de Ejecución — Sistema de Entradas para Conciertos

## 1. Inyectar credenciales AWS

powershell
# Desde la raíz del proyecto
python actualizar_aws.py
# O manualmente:
Copy-Item aws_keys.txt "$env:USERPROFILE\.aws\credentials"


## 2. Desplegar infraestructura

### Arquitectura Directa (REST + NGINX + Workers)

```powershell
cd direct_infra
terraform init
terraform apply
```

### Arquitectura Indirecta (RabbitMQ + Workers)

```powershell
cd indirect_infra
terraform init
terraform apply
```

> ⚠️ Espera 3-5 minutos después del `apply` para que las instancias terminen el `user_data` (instalación de paquetes, git clone, etc.).

## 3. Verificar que las instancias están listas

```powershell
# Desde la raíz
ssh -i clave-rabbitmq-server.pem ec2-user@<IP_DEL_CLIENTE>
ssh -i clave-rabbitmq-server.pem ec2-user@<IP_DEL_WORKER>
```

Las IPs aparecen en los outputs de Terraform o en `terraform.tfstate`.

---

## 4. Resetear Redis (entre cada benchmark)

```powershell
ssh -i clave-rabbitmq-server.pem ec2-user@<IP_CLIENTE>
export REDIS_HOST=<IP_PRIVADA_REDIS>
cd archivosCliente
python3 reset_redis.py
```

---

## 5. Ejecutar benchmarks

SSH al cliente y ejecutar:

```bash
cd archivosCliente

# ─── DIRECTA ───────────────────────────────

# No numeradas (20k entradas, todas deben venderse)
bash direct_client_unnumbered.sh

# Numeradas (60k requests todas al asiento 42, solo 1 debe funcionar)
bash direct_client_numbered.sh

# ─── INDIRECTA ─────────────────────────────

# No numeradas
bash indirect_client_unnumbered.sh

# Numeradas
bash indirect_client_numbered.sh
```

---

## 6. Escalado dinámico (durante ejecución)

Ejecutar desde tu máquina local (NO desde el cliente EC2):

```powershell
cd archivosCliente

# 1 vez: inicializar estado
python3 scripts/scale.py direct init -k ../clave-rabbitmq-server.pem -n <IP_NGINX> -w <IP_W1,IP_W2,IP_W3>

# Escalar hacia arriba (+2 workers)
python3 scripts/scale.py direct up -k ../clave-rabbitmq-server.pem -n <IP_NGINX> -w <IP_W1,IP_W2,IP_W3> 2

# Escalar hacia abajo (-1 worker)
python3 scripts/scale.py direct down -k ../clave-rabbitmq-server.pem -n <IP_NGINX> -w <IP_W1,IP_W2,IP_W3> 1

# Ver estado actual
python3 scripts/scale.py direct status -k ../clave-rabbitmq-server.pem -n <IP_NGINX> -w <IP_W1,IP_W2,IP_W3>
```

Para arquitectura indirecta (cuando esté desplegada):

```powershell
python3 scripts/scale.py indirect init -k ../clave-rabbitmq-server.pem -w <IP_W1,IP_W2>
python3 scripts/scale.py indirect up -k ../clave-rabbitmq-server.pem -w <IP_W1,IP_W2> 2
python3 scripts/scale.py indirect down -k ../clave-rabbitmq-server.pem -w <IP_W1,IP_W2> 1
```

Recomendación: durante un benchmark en ejecución, lanza `scale.py up 1` cada 10 segundos para ver cómo mejora el throughput en tiempo real.

---

## 7. Escenario de alta contención (80% → 5% asientos)

El benchmark debe tener 60k requests donde ~48k (80%) apunten al 5% de los asientos (asientos 1-1000) y el resto se distribuyan entre los 19000 restantes.

Crear archivo `benchmarks/benchmark_numbered_hotspot.txt` con ese formato `BUY <client_id> <seat_id> <request_id>` y ejecutar:

```bash
# Directa
python3 scripts/direct_client.py benchmarks/benchmark_numbered_hotspot.txt

# Indirecta
python3 scripts/indirect_client.py benchmarks/benchmark_numbered_hotspot.txt
```

---

## 8. Secuencia completa recomendada (para el reporte)

```powershell
# 1. Reset Redis
ssh -i clave-rabbitmq-server.pem ec2-user@<CLIENTE_IP>
export REDIS_HOST=<REDIS_IP>
cd archivosCliente && python3 reset_redis.py

# 2. Benchmark Directa No Numeradas
bash direct_client_unnumbered.sh

# 3. Reset Redis
python3 reset_redis.py

# 4. Benchmark Directa Numeradas
bash direct_client_numbered.sh

# 5. Reset Redis
python3 reset_redis.py

# 6. Benchmark Indirecta No Numeradas
bash indirect_client_unnumbered.sh

# 7. Reset Redis
python3 reset_redis.py

# 8. Benchmark Indirecta Numeradas
bash indirect_client_numbered.sh
```

Repetir los pasos 1-8 variando el número de workers usando `scale.py` para generar los datos de escalabilidad.

---

## IPs de la infraestructura actual (Directa)

| Recurso | IP Pública | IP Privada |
|---------|-----------|------------|
| NGINX | 54.147.218.199 | 172.31.25.3 |
| Worker 1 | 18.207.93.224 | 172.31.30.217 |
| Worker 2 | 54.224.51.86 | 172.31.30.3 |
| Worker 3 | 52.90.155.20 | 172.31.24.233 |
| Redis | 3.80.70.234 | 172.31.29.200 |
| Cliente | 100.55.20.164 | 172.31.16.220 |
