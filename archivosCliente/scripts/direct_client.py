import os
import asyncio
import aiohttp
import time
import sys

# PON AQUÍ LA IP DE TU MÁQUINA NGINX (O DEL WORKER SI PRUEBAS CON UNO SOLO)
NGINX_HOST = os.environ.get('NGINX_HOST', 'localhost')
BASE_URL = f"http://{NGINX_HOST}"

async def send_request(session, url, payload, sem, stats):
    # El semáforo evita que el cliente colapse por intentar abrir 60.000 puertos en el mismo milisegundo
    async with sem:
        try:
            async with session.post(url, json=payload) as response:
                status = response.status
                # Registramos el código HTTP (200, 400, 409...) para las estadísticas
                stats[status] = stats.get(status, 0) + 1
        except Exception as e:
            stats['errors'] = stats.get('errors', 0) + 1

async def main(filename):
    print(f"Cargando benchmark desde: {filename}...")
    
    with open(filename, 'r') as f:
        # Leemos ignorando comentarios y líneas vacías
        lines = [line.strip() for line in f if line.startswith("BUY")]
    
    total_requests = len(lines)
    print(f"Se han cargado {total_requests} peticiones. Preparando el ataque...")

    stats = {}
    tasks = []
    
    # Limitamos a 2000 peticiones concurrentes simultáneas reales para no ahogar la red de AWS
    sem = asyncio.Semaphore(2000) 
    
    # TCPConnector optimiza la reutilización de conexiones
    connector = aiohttp.TCPConnector(limit=None)
    
    async with aiohttp.ClientSession(connector=connector) as session:
        for line in lines:
            parts = line.split()
            
            # Detectar si es el benchmark Unnumbered (3 partes) o Numbered (4 partes)
            if len(parts) == 3:
                url = f"{BASE_URL}/buy/unnumbered"
                payload = {"client_id": parts[1], "request_id": parts[2]}
            elif len(parts) == 4:
                url = f"{BASE_URL}/buy/numbered"
                payload = {"client_id": parts[1], "seat_id": parts[2], "request_id": parts[3]}
            else:
                continue
                
            tasks.append(send_request(session, url, payload, sem, stats))
        
        print("¡Fuego! Enviando peticiones...")
        start_time = time.time()
        
        # Ejecutamos todas las tareas
        await asyncio.gather(*tasks)
        
        end_time = time.time()

    # --- RESULTADOS PARA EL PDF ---
    total_time = end_time - start_time
    throughput = total_requests / total_time

    print("\n" + "="*40)
    print("📊 RESULTADOS DEL BENCHMARK")
    print("="*40)
    print(f"Tiempo total de ejecución: {total_time:.2f} segundos")
    print(f"Throughput (Rendimiento):  {throughput:.2f} req/s")
    print("-" * 40)
    print("Desglose de respuestas HTTP:")
    for status, count in sorted(stats.items()):
        if status == 200:
            print(f"  ✅ [200 OK] Compras exitosas: {count}")
        elif status == 409:
            print(f"  ❌ [409 Conflict] Asiento ya ocupado: {count}")
        elif status == 400:
            print(f"  🚫 [400 Bad Request] Sold Out (Agotadas): {count}")
        else:
            print(f"  ⚠️ [{status}] Otros / Errores de red: {count}")
    print("="*40)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Uso: python3 client_async.py <archivo_benchmark.txt>")
        sys.exit(1)
        
    archivo = sys.argv[1]
    
    # Optimización para que asyncio vaya lo más rápido posible en Linux
    import uvloop
    uvloop.install()
    
    asyncio.run(main(archivo))