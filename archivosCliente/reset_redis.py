import redis
import sys
import os

REDIS_HOST = os.environ.get('REDIS_HOST', 'localhost')
REDIS_PASSWORD = "admin123"

def resetear_redis():
    print(f"Conectando a Redis en {REDIS_HOST}...")
    try:
        r = redis.Redis(host=REDIS_HOST, port=6379, password=REDIS_PASSWORD, decode_responses=True)
        r.ping() 

        r.set('entradas_disponibles', 20000)
        print("✅ Entradas NO numeradas: Contador reseteado a 20.000")

        r.delete('entradas_numeradas')
        print("✅ Entradas NUMERADAS: Todos los asientos han sido liberados")

        print("\n🚀 ¡Base de datos limpia y lista para el próximo benchmark!")

    except redis.ConnectionError:
        print("❌ Error: No me puedo conectar a Redis. Revisa la IP y el Security Group.")
    except Exception as e:
        print(f"❌ Error inesperado: {e}")

if __name__ == "__main__":
    resetear_redis()