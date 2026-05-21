from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel
import redis.asyncio as redis # Usamos la versión asíncrona de Redis
import os

app = FastAPI()

# Conexión a Redis (Cambia la IP_REDIS y la contraseña)
# decode_responses=True hace que Redis nos devuelva texto normal y no bytes.
REDIS_HOST = os.environ.get('REDIS_HOST', 'localhost')

r = redis.Redis(host=REDIS_HOST, port=6379, password='admin123', decode_responses=True)

# 1. Definimos qué forma tiene el JSON que nos va a mandar el cliente
class UnnumberedRequest(BaseModel):
    client_id: str
    request_id: str

class NumberedRequest(BaseModel):
    client_id: str
    seat_id: str
    request_id: str

# 2. Endpoint para entradas NO numeradas
@app.post("/buy/unnumbered")
async def buy_unnumbered(req: UnnumberedRequest):
    # DECR resta 1 y nos devuelve el valor resultante (es atómico)
    entradas_restantes = await r.decr('entradas_disponibles')
    
    if entradas_restantes >= 0:
        return {"status": "success", "message": "Ticket purchased"}
    else:
        # Si bajamos de cero, lo volvemos a subir para no dejar basura en Redis
        await r.incr('entradas_disponibles')
        # Lanzamos un error 400 para que el cliente sepa que ha fallado
        raise HTTPException(status_code=400, detail="Sold out")

# 3. Endpoint para entradas NUMERADAS
@app.post("/buy/numbered")
async def buy_numbered(req: NumberedRequest):
    # HSETNX: Guarda el cliente en el asiento SOLO si el asiento no existe ya.
    # Devuelve 1 (éxito) o 0 (ya existía).
    success = await r.hsetnx('entradas_numeradas', req.seat_id, req.client_id)
    
    if success == 1:
        return {"status": "success", "message": f"Seat {req.seat_id} purchased by {req.client_id}"}
    else:
        # Error 409 Conflict: El asiento ya está pillado
        raise HTTPException(status_code=409, detail="Seat already taken")