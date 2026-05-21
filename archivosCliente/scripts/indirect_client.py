import pika
import time
import os
import sys

# Rescatamos la IP de RabbitMQ de las variables de entorno (configurado por Terraform)
RABBITMQ_HOST = os.getenv('RABBITMQ_HOST', 'localhost')
QUEUE_NAME = 'booking_queue' # Cambia esto si tu indirect_worker.py usa otro nombre de cola

def main(archivo_benchmark):
    print(f"Cargando benchmark desde: {archivo_benchmark}...")
    
    try:
        with open(archivo_benchmark, 'r') as f:
            # Leemos todas las líneas (peticiones) ignorando las vacías
            peticiones = [line.strip() for line in f if line.strip()]
    except FileNotFoundError:
        print(f"❌ Error: No se encontró el archivo {archivo_benchmark}")
        sys.exit(1)

    print(f"Se han cargado {len(peticiones)} peticiones. Conectando a RabbitMQ en {RABBITMQ_HOST}...")

    # Conexión a RabbitMQ usando las credenciales que pusimos en Terraform
    try:
        credentials = pika.PlainCredentials('admin', 'admin123')
        parameters = pika.ConnectionParameters(
            host=RABBITMQ_HOST, 
            port=5672, 
            virtual_host='/', 
            credentials=credentials
        )
        connection = pika.BlockingConnection(parameters)
        channel = connection.channel()
    except Exception as e:
        print(f"❌ Error conectando a RabbitMQ: {e}")
        sys.exit(1)

    # Nos aseguramos de que la cola existe (durable=True para que no se borre si RabbitMQ se reinicia)
    channel.queue_declare(queue=QUEUE_NAME, durable=True)

    print("¡Fuego! Inyectando mensajes en la cola...")
    start_time = time.time()

    # Disparamos los mensajes
    for peticion in peticiones:
        # Enviamos la línea cruda del benchmark a la cola
        channel.basic_publish(
            exchange='',
            routing_key=QUEUE_NAME,
            body=peticion,
            properties=pika.BasicProperties(
                delivery_mode=pika.spec.PERSISTENT_DELIVERY_MODE # Mensajes persistentes en disco
            )
        )

    end_time = time.time()
    connection.close()

    tiempo_total = end_time - start_time
    rendimiento = len(peticiones) / tiempo_total

    print("\n========================================")
    print("📊 RESULTADOS DE INYECCIÓN (ASÍNCRONO)")
    print("========================================")
    print(f"Tiempo total de inyección: {tiempo_total:.2f} segundos")
    print(f"Throughput de entrada:     {rendimiento:.2f} msg/s")
    print("----------------------------------------")
    print("💡 Nota vital para la práctica:")
    print("El cliente indirecto NO espera los códigos HTTP 200 o 409.")
    print("Su trabajo ha terminado. Ahora mismo, los workers están")
    print("consumiendo esta cola en segundo plano a su propio ritmo.")
    print("========================================")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Uso: python3 indirect_client.py <ruta_al_benchmark>")
        sys.exit(1)
    
    archivo = sys.argv[1]
    main(archivo)