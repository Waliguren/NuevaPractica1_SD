import random
import os

OUTPUT_FILE = os.path.join(os.path.dirname(__file__), '..', 'benchmarks', 'benchmark_numbered_hotspot.txt')
TOTAL_SEATS = 20000
HOTSPOT_SEATS = int(TOTAL_SEATS * 0.05)   # 1000 asientos (5%)
TOTAL_REQUESTS = 60000
HOTSPOT_RATIO = 0.80                       # 80% al hotspot
HOTSPOT_REQUESTS = int(TOTAL_REQUESTS * HOTSPOT_RATIO)  # 48000
COLD_REQUESTS = TOTAL_REQUESTS - HOTSPOT_REQUESTS       # 12000

random.seed(42)

with open(OUTPUT_FILE, 'w') as f:
    f.write("# Concert Ticket Benchmark - High Contention (Hotspot)\n")
    f.write(f"# 80% of requests -> 5% of seats (1-{HOTSPOT_SEATS})\n")
    f.write(f"# Total requests: {TOTAL_REQUESTS}\n")
    f.write("# Format: BUY <client_id> <seat_id> <request_id>\n\n")

    req_id = 1

    # Hotspot requests: seat_id entre 1 y HOTSPOT_SEATS
    for _ in range(HOTSPOT_REQUESTS):
        seat = random.randint(1, HOTSPOT_SEATS)
        client = f"user{req_id:05d}"
        f.write(f"BUY {client} {seat} {req_id:05d}\n")
        req_id += 1

    # Cold requests: seat_id entre HOTSPOT_SEATS+1 y TOTAL_SEATS
    for _ in range(COLD_REQUESTS):
        seat = random.randint(HOTSPOT_SEATS + 1, TOTAL_SEATS)
        client = f"user{req_id:05d}"
        f.write(f"BUY {client} {seat} {req_id:05d}\n")
        req_id += 1

print(f"Benchmark hotspot generado: {OUTPUT_FILE}")
print(f"  Total requests: {req_id - 1}")
print(f"  Hotspot (asientos 1-{HOTSPOT_SEATS}): {HOTSPOT_REQUESTS} ({HOTSPOT_RATIO*100:.0f}%)")
print(f"  Cold (asientos {HOTSPOT_SEATS+1}-{TOTAL_SEATS}): {COLD_REQUESTS} ({(1-HOTSPOT_RATIO)*100:.0f}%)")
