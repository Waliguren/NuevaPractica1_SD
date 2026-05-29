import pika
import redis
import os
import sys
import time

# Variables inyectadas por Terraform (o puestas a mano para pruebas locales)
REDIS_HOST = os.getenv('REDIS_HOST', 'localhost')
RABBITMQ_HOST = os.getenv('RABBITMQ_HOST', 'localhost')
QUEUE_NAME = 'booking_queue'

# 1. Conexión a Redis con paciencia (Reintentos)
max_reintentos = 12
for i in range(max_reintentos):
    try:
        r = redis.Redis(host=REDIS_HOST, port=6379, password="admin123", decode_responses=True)
        r.ping()
        print(f"✅ Conectado a Redis en {REDIS_HOST}")
        break  # Si conecta bien, rompemos el bucle
    except Exception as e:
        print(f"⚠️ Redis no responde. Reintentando en 5 segundos... ({i+1}/{max_reintentos})")
        time.sleep(5)
else:
    print("❌ Imposible conectar a Redis tras 60 segundos. Apagando worker.")
    sys.exit(1)

# 2. Conexión a RabbitMQ con paciencia (Reintentos)
for i in range(max_reintentos):
    try:
        credentials = pika.PlainCredentials('admin', 'admin123')
        parameters = pika.ConnectionParameters(
            host=RABBITMQ_HOST, port=5672, virtual_host='/', credentials=credentials
        )
        connection = pika.BlockingConnection(parameters)
        channel = connection.channel()
        channel.queue_declare(queue=QUEUE_NAME, durable=True)
        channel.basic_qos(prefetch_count=100)
        print(f"✅ Conectado a RabbitMQ en {RABBITMQ_HOST}. Esperando trabajo...")
        break
    except Exception as e:
        print(f"⚠️ RabbitMQ no responde. Reintentando en 5 segundos... ({i+1}/{max_reintentos})")
        time.sleep(5)
else:
    print("❌ Imposible conectar a RabbitMQ. Apagando worker.")
    sys.exit(1)

# 3. La lógica central del Worker
def procesar_mensaje(ch, method, props, body):
    peticion = body.decode()
    
    # 1. Extraemos el asiento real de la petición cruda
    try:
        if "HTTP" in peticion:
            # De "GET /buy/numbered/1234 HTTP/1.1" sacamos el "1234"
            ruta = peticion.split(" ")[1] 
            asiento = ruta.split("/")[-1] 
        else:
            asiento = peticion.strip()
    except:
        asiento = peticion # Por si el formato es distinto
        
    # 2. LÓGICA DE NEGOCIO (REDIS DOUBLE-BOOKING)
    exito = r.setnx(f"asiento_{asiento}", "vendido")
    
    if exito:
        respuesta_http = "200"
    else:
        respuesta_http = "409"
        
    # --- AQUÍ ESTÁ TU MONITORIZACIÓN EN DIRECTO ---
    print(f"📩 Asiento {asiento} procesado. Resultado: {respuesta_http}")
        
    # 3. RESPUESTA AL CLIENTE (RPC)
    if props.reply_to and props.correlation_id:
        ch.basic_publish(
            exchange='',
            routing_key=props.reply_to,
            properties=pika.BasicProperties(
                correlation_id=props.correlation_id
            ),
            body=respuesta_http
        )    
    ch.basic_ack(delivery_tag=method.delivery_tag)

# Arrancamos el bucle infinito
channel.basic_consume(queue=QUEUE_NAME, on_message_callback=procesar_mensaje)

try:
    channel.start_consuming()
except KeyboardInterrupt:
    print("\nApagando worker de forma segura...")
    connection.close()