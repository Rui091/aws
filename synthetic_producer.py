import sys
import time
import json
import argparse
import concurrent.futures
try:
    import requests
except ImportError:
    print("Error: la librería 'requests' no está instalada.")
    print("Por favor, instálala ejecutando: pip install requests")
    sys.exit(1)

def send_task(url, index):
    """Envía una única tarea a la API."""
    headers = {'Content-Type': 'application/json'}
    payload = {
        "status": "pending",
        "payload": f"Mensaje sintético #{index}"
    }
    
    try:
        response = requests.post(f"{url}/task", headers=headers, json=payload, timeout=5)
        if response.status_code == 200:
            return True, response.json().get('task_id')
        else:
            return False, f"HTTP {response.status_code}"
    except Exception as e:
        return False, str(e)

def run_synthetic_load(url, total_tasks, max_workers):
    print(f"==================================================")
    print(f"🚀 Iniciando Productor Sintético")
    print(f"📍 Objetivo: {url}/task")
    print(f"📦 Total de tareas a enviar: {total_tasks}")
    print(f"⚡ Hilos concurrentes: {max_workers}")
    print(f"==================================================\n")

    start_time = time.time()
    successful = 0
    failed = 0

    # Usamos ThreadPoolExecutor para enviar peticiones concurrentes
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        # Preparamos todas las peticiones
        futures = {executor.submit(send_task, url, i): i for i in range(1, total_tasks + 1)}
        
        # Procesamos a medida que van terminando
        for future in concurrent.futures.as_completed(futures):
            success, result = future.result()
            if success:
                successful += 1
            else:
                failed += 1
                
            # Pequeño feedback visual cada 100 tareas
            total_processed = successful + failed
            if total_processed % (total_tasks // 10 if total_tasks >= 10 else 1) == 0:
                print(f"Progreso: {total_processed}/{total_tasks} procesadas...")

    end_time = time.time()
    duration = end_time - start_time
    tps = total_tasks / duration if duration > 0 else 0

    print(f"\n==================================================")
    print(f"✅ Prueba Finalizada en {duration:.2f} segundos")
    print(f"📊 Tareas enviadas exitosamente: {successful}")
    print(f"❌ Tareas fallidas: {failed}")
    print(f"🏎️ Velocidad promedio: {tps:.2f} peticiones/segundo")
    print(f"==================================================")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Productor Sintético para estresar la API FastAPI + RabbitMQ")
    parser.add_argument("--url", type=str, required=True, help="URL base de la API (ej: http://1.2.3.4)")
    parser.add_argument("--count", type=int, default=1000, help="Cantidad total de tareas a generar (default: 1000)")
    parser.add_argument("--workers", type=int, default=50, help="Nivel de concurrencia / hilos simultáneos (default: 50)")
    
    args = parser.parse_args()
    
    # Limpiamos la URL por si el usuario le puso un / al final
    base_url = args.url.rstrip("/")
    
    run_synthetic_load(base_url, args.count, args.workers)
