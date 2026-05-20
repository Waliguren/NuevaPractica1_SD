import pika
import json
import time
import random

# Replace with RabbitMQ private IP
HOST = "10.0.1.117"

credentials = pika.PlainCredentials("admin", "admin123")

connection = pika.BlockingConnection(
    pika.ConnectionParameters(host=HOST, credentials=credentials)
)

channel = connection.channel()

# Declare queue
channel.queue_declare(queue="ticket_queue", durable=True)

r = redis.Redis(host='10.0.1.88', port=6379, password='admin123', decode_responses=True)

def callback(ch, method, properties, body):
    """
    Process messages from the queue.
    """

    msg = json.loads(body)
    
    # Asumiendo que el cliente envía un JSON con el tipo de entrada
    ticket_type = msg.get("type")

    if ticket_type == "unnumbered":
        entradas_restantes = r.decr('entradas_disponibles')
        if entradas_restantes < 0:
            # Si bajamos de 0, devolvemos el contador a 0
            r.incr('entradas_disponibles')
            print("Sold out para entrada no numerada")

    elif ticket_type == "numbered":
        client_id = msg.get("client_id")
        seat_id = msg.get("seat_id")
        
        # HSETNX evita las ventas dobles atómicamente
        success = r.hsetnx('entradas_numeradas', seat_id, client_id)
        if success == 0:
             print(f"Conflicto: El asiento {seat_id} ya estaba vendido")

# Limit messages per worker
channel.basic_qos(prefetch_count=5)

channel.basic_consume(queue="event_queue", on_message_callback=callback)

print("Worker started. Waiting for messages...")

channel.start_consuming()