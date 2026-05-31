import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

STATE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.scale_state.json')
SSH_OPTS = ['-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=30']

def ssh(host, cmd, key_file):
    ssh_cmd = ['ssh'] + SSH_OPTS + ['-i', key_file, f'ec2-user@{host}', cmd]
    result = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=60)
    return result.returncode, result.stdout.strip(), result.stderr.strip()

def scp_file(local_path, remote_host, remote_path, key_file):
    scp_cmd = ['scp'] + SSH_OPTS + ['-i', key_file, local_path, f'ec2-user@{remote_host}:{remote_path}']
    result = subprocess.run(scp_cmd, capture_output=True, text=True, timeout=30)
    return result.returncode == 0

def load_state():
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE) as f:
            return json.load(f)
    return {"direct": {"workers": {}}, "indirect": {"workers": {}}}

def save_state(state):
    with open(STATE_FILE, 'w') as f:
        json.dump(state, f, indent=2, sort_keys=True)

def generate_nginx_config(entries):
    servers = '\n'.join(f'            server {e};' for e in entries)
    return f'''events {{
    worker_connections 65535;
}}
http {{
    upstream workers_api {{
{servers}
    }}
    server {{
        listen 80;
        location / {{
            proxy_pass http://workers_api;
            proxy_connect_timeout 300s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
        }}
    }}
}}
'''

def update_nginx(nginx_ip, key_file, entries):
    config = generate_nginx_config(entries)
    tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.conf', delete=False)
    try:
        tmp.write(config)
        tmp.close()
        ok = scp_file(tmp.name, nginx_ip, '/home/ec2-user/nginx.conf', key_file)
        if not ok:
            return False
        rc, out, err = ssh(nginx_ip, 'docker exec mi-nginx nginx -s reload', key_file)
        if rc != 0:
            print(f"  ⚠️ NGINX reload: {err}")
            return False
        print(f"  ✅ NGINX reloaded OK")
        return True
    finally:
        os.unlink(tmp.name)

def read_nginx_config(nginx_ip, key_file):
    rc, out, err = ssh(nginx_ip, 'cat /home/ec2-user/nginx.conf', key_file)
    if rc == 0:
        return out
    return None


# ─── DIRECT ARCHITECTURE ───────────────────────────────────────────────────

def direct_init(nginx_ip, worker_ips, key_file, state):
    dstate = state.setdefault('direct', {"workers": {}})
    dstate['nginx_ip'] = nginx_ip
    for ip in worker_ips:
        if ip not in dstate['workers']:
            dstate['workers'][ip] = [5000]
    save_state(state)
    print(f"  ✅ Estado inicializado: {len(worker_ips)} workers, puerto base 5000")

def direct_status(nginx_ip, worker_ips, key_file, state):
    dstate = state.get('direct', {"workers": {}})
    print(f"\n{'='*50}")
    print("📊 ESTADO - ARQUITECTURA DIRECTA")
    print(f"{'='*50}")
    print(f"  NGINX: {nginx_ip}")
    
    nginx_config = read_nginx_config(nginx_ip, key_file)
    if nginx_config:
        upstream_lines = [l.strip() for l in nginx_config.split('\n') if 'server ' in l and 'proxy_pass' not in l]
        print(f"  Upstream NGINX: {len(upstream_lines)} entradas")
        for l in upstream_lines:
            print(f"    {l}")
    
    print(f"\n  Workers registrados en estado:")
    total_ports = 0
    for ip, ports in dstate.get('workers', {}).items():
        print(f"    {ip}: puertos {ports}")
        total_ports += len(ports)
    print(f"  Total procesos worker: {total_ports}")
    
    print(f"\n  Workers en EC2 (procesos reales):")
    for ip in worker_ips:
        rc, out, err = ssh(ip, "ps aux | grep 'uvicorn direct_worker' | grep -v grep || true", key_file)
        lines = [l for l in out.split('\n') if l.strip()]
        print(f"    {ip}: {len(lines)} proceso(s) uvicorn")
        for l in lines:
            parts = l.split()
            port_idx = [i for i, p in enumerate(parts) if '--port' in p]
            if port_idx:
                print(f"      → {parts[port_idx[0]+1]}")

def _pick_worker_up(dstate, worker_ips):
    available = [ip for ip in worker_ips if ip in dstate['workers']]
    if not available:
        return None
    available.sort(key=lambda ip: len(dstate['workers'][ip]))
    return available[0]

def _pick_worker_down(dstate, worker_ips):
    available = [ip for ip in worker_ips if ip in dstate['workers'] and len(dstate['workers'][ip]) > 1]
    if not available:
        return None
    available.sort(key=lambda ip: len(dstate['workers'][ip]), reverse=True)
    return available[0]

def direct_up(nginx_ip, worker_ips, key_file, count, state):
    dstate = state.get('direct', {"workers": {}})
    added = []
    
    for _ in range(count):
        target_ip = _pick_worker_up(dstate, worker_ips)
        if not target_ip:
            print("  ❌ No hay workers disponibles")
            break
        
        ports = dstate['workers'][target_ip]
        new_port = max(ports) + 1
        
        cmd = (
            f"cd /home/ec2-user/archivosWorker && "
            f"nohup venv/bin/uvicorn direct_worker:app "
            f"--host 0.0.0.0 --port {new_port} "
            f"> worker_{new_port}.log 2>&1 &"
        )
        rc, out, err = ssh(target_ip, cmd, key_file)
        if rc != 0:
            print(f"  ❌ Error al iniciar worker en {target_ip}:{new_port}: {err}")
            continue
        
        ports.append(new_port)
        added.append(f"{target_ip}:{new_port}")
        print(f"  ✅ Worker iniciado en {target_ip}:{new_port}")
        time.sleep(1)
    
    if not added:
        return
    
    all_entries = []
    for ip, ports in dstate['workers'].items():
        for p in ports:
            all_entries.append(f"{ip}:{p}")
    
    print(f"  🔄 Actualizando NGINX con {len(all_entries)} entradas...")
    if update_nginx(nginx_ip, key_file, all_entries):
        save_state(state)
        print(f"  ✅ Escalado completado: +{len(added)} worker(s)")
    else:
        print(f"  ❌ Error actualizando NGINX, revirtiendo...")
        for ip, ports in dstate['workers'].items():
            if ports and ports[-1] not in [5000]:
                ports.pop()
        save_state(state)

def direct_down(nginx_ip, worker_ips, key_file, count, state):
    dstate = state.get('direct', {"workers": {}})
    removed = []
    
    for _ in range(count):
        target_ip = _pick_worker_down(dstate, worker_ips)
        if not target_ip:
            print("  ❌ No hay workers escalables (todos tienen solo el puerto base 5000)")
            break
        
        ports = dstate['workers'][target_ip]
        target_port = ports.pop()
        
        cmd = (
            f"kill $(ps aux | grep 'uvicorn.*:{target_port}' | grep -v grep | awk '{{print $2}}') 2>/dev/null; "
            f"echo 'OK'"
        )
        rc, out, err = ssh(target_ip, cmd, key_file)
        removed.append(f"{target_ip}:{target_port}")
        print(f"  ✅ Worker detenido en {target_ip}:{target_port}")
        time.sleep(1)
    
    if not removed:
        return
    
    all_entries = []
    for ip, ports in dstate['workers'].items():
        for p in ports:
            all_entries.append(f"{ip}:{p}")
    
    print(f"  🔄 Actualizando NGINX con {len(all_entries)} entradas...")
    if update_nginx(nginx_ip, key_file, all_entries):
        print(f"  ✅ Escalado completado: -{len(removed)} worker(s)")
    save_state(state)


# ─── INDIRECT ARCHITECTURE ────────────────────────────────────────────────

def indirect_init(worker_ips, key_file, state):
    istate = state.setdefault('indirect', {"workers": {}})
    for ip in worker_ips:
        if ip not in istate['workers']:
            istate['workers'][ip] = 1
    save_state(state)
    print(f"  ✅ Estado inicializado: {len(worker_ips)} workers, 1 proceso base c/u")

def indirect_status(nginx_ip, worker_ips, key_file, state):
    istate = state.get('indirect', {"workers": {}})
    print(f"\n{'='*50}")
    print("📊 ESTADO - ARQUITECTURA INDIRECTA")
    print(f"{'='*50}")
    
    total = 0
    for ip, proc_count in istate.get('workers', {}).items():
        print(f"  {ip}: {proc_count} proceso(s) registrados")
        total += proc_count
    
    print(f"\n  Procesos reales en EC2:")
    for ip in worker_ips:
        rc, out, err = ssh(ip, "ps aux | grep 'indirect_worker.py' | grep -v grep || true", key_file)
        lines = [l for l in out.split('\n') if l.strip()]
        print(f"    {ip}: {len(lines)} proceso(s) en ejecución")
    
    print(f"  Total procesos registrados: {total}")

def indirect_up(nginx_ip, worker_ips, key_file, count, state):
    istate = state.get('indirect', {"workers": {}})
    started = 0
    
    for _ in range(count):
        available = [ip for ip in worker_ips if ip in istate['workers']]
        if not available:
            print("  ❌ No hay workers disponibles")
            break
        available.sort(key=lambda ip: istate['workers'][ip])
        target_ip = available[0]
        
        cmd = (
            f"cd /home/ec2-user/archivosWorker && "
            f"nohup venv/bin/python3 indirect_worker.py "
            f"> worker_extra_{istate['workers'][target_ip]}.log 2>&1 &"
        )
        rc, out, err = ssh(target_ip, cmd, key_file)
        if rc != 0:
            print(f"  ❌ Error en {target_ip}: {err}")
            continue
        
        istate['workers'][target_ip] += 1
        started += 1
        print(f"  ✅ Worker indirecto iniciado en {target_ip}")
        time.sleep(1)
    
    if started:
        save_state(state)
        print(f"  ✅ Escalado completado: +{started} worker(s) indirecto(s)")

def indirect_down(nginx_ip, worker_ips, key_file, count, state):
    istate = state.get('indirect', {"workers": {}})
    stopped = 0
    
    for _ in range(count):
        available = [ip for ip in worker_ips if ip in istate['workers'] and istate['workers'][ip] > 1]
        if not available:
            print("  ❌ No hay workers escalables (todos tienen 1 proceso base)")
            break
        available.sort(key=lambda ip: istate['workers'][ip], reverse=True)
        target_ip = available[0]
        
        cmd = (
            f"kill $(ps aux | grep 'indirect_worker.py' | grep -v grep | "
            f"tail -1 | awk '{{print $2}}') 2>/dev/null; echo 'OK'"
        )
        rc, out, err = ssh(target_ip, cmd, key_file)
        istate['workers'][target_ip] -= 1
        stopped += 1
        print(f"  ✅ Worker indirecto detenido en {target_ip}")
        time.sleep(1)
    
    if stopped:
        save_state(state)
        print(f"  ✅ Escalado completado: -{stopped} worker(s) indirecto(s)")


# ─── MAIN ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Escalado dinámico de workers (Directa e Indirecta)"
    )
    parser.add_argument('--key', '-k', required=True, help='Ruta al archivo .pem')
    parser.add_argument('--nginx', '-n', default='', help='IP del NGINX (solo directa)')
    parser.add_argument('--workers', '-w', required=True, help='IPs de workers separadas por coma')
    parser.add_argument('action', choices=['up', 'down', 'status', 'init'],
                        help='Acción a realizar')
    parser.add_argument('arch', choices=['direct', 'indirect'],
                        help='Arquitectura')
    parser.add_argument('count', nargs='?', type=int, default=1,
                        help='Número de workers (por defecto 1)')

    args = parser.parse_args()
    worker_ips = [ip.strip() for ip in args.workers.split(',') if ip.strip()]

    if not os.path.exists(args.key):
        print(f"❌ No se encuentra el archivo clave: {args.key}")
        sys.exit(1)

    state = load_state()
    
    if args.arch == 'direct':
        if not args.nginx:
            print("❌ Se requiere --nginx para la arquitectura directa")
            sys.exit(1)
        if args.action == 'init':
            direct_init(args.nginx, worker_ips, args.key, state)
        elif args.action == 'status':
            direct_status(args.nginx, worker_ips, args.key, state)
        elif args.action == 'up':
            direct_up(args.nginx, worker_ips, args.key, args.count, state)
        elif args.action == 'down':
            direct_down(args.nginx, worker_ips, args.key, args.count, state)
    else:
        if args.action == 'init':
            indirect_init(worker_ips, args.key, state)
        elif args.action == 'status':
            indirect_status('', worker_ips, args.key, state)
        elif args.action == 'up':
            indirect_up('', worker_ips, args.key, args.count, state)
        elif args.action == 'down':
            indirect_down('', worker_ips, args.key, args.count, state)

if __name__ == '__main__':
    main()
