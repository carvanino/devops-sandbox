# 5. Health Monitor — The Watchdog
# Loop forever:
#   1. Sleep 30 seconds
#   2. For each active env in envs/:
#      - GET /health on its container
#      - Record timestamp, status code, latency
#      - Write to logs/$ENV_ID/health.log
#      - If 3 consecutive failures:
#        → set status = "degraded" in state file
#        → print warning

import os
import sys
import time
import requests
import glob, json
from datetime import datetime

# Force stdout flush so logs appear when running in background
sys.stdout = open(sys.stdout.fileno(), mode='w', buffering=1)


envs_failure_count = {}
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))



def poll_health(env_id):
    # url = f"http://{env_id}:3000/health"
    url = f"http://localhost/envs/{env_id}/health"
    try:
        start_time = time.time()
        response = requests.get(url, timeout=5)
        latency = time.time() - start_time
        status_code = response.status_code
        return start_time, status_code, latency
    except requests.RequestException:
        return None, None, None


def log_health(env_id, timestamp, status_code, latency):
    LOG_DIR  = os.path.join(BASE_DIR, "logs")
    os.makedirs(os.path.join(LOG_DIR, env_id), exist_ok=True)
    log_file = os.path.join(LOG_DIR, env_id, "health.log")
    with open(log_file, "a") as f:
        f.write(f"{datetime.fromtimestamp(timestamp)} - Status: {status_code}, Latency: {latency:.2f}s\n")


def check_consecutive_failures(env_id, status_code):
    if env_id not in envs_failure_count:
        envs_failure_count[env_id] = 0
    
    if status_code != 200:
        envs_failure_count[env_id] += 1
    else:
        envs_failure_count[env_id] = 0
    
    return envs_failure_count[env_id] >= 3

def mark_degraded(state_file):
    with open(state_file, "r") as f:
        state_data = json.load(f)
    state_data["status"] = "degraded"
    tmp_file = state_file + ".tmp"
    with open(tmp_file, "w") as f:
        json.dump(state_data, f, indent=2)
    os.replace(tmp_file, state_file)

def mark_active(state_file):
    with open(state_file, "r") as f:
        state_data = json.load(f)
    if state_data.get("status") == "degraded":
        state_data["status"] = "active"
        tmp_file = state_file + ".tmp"
        with open(tmp_file, "w") as f:
            json.dump(state_data, f, indent=2)
        os.replace(tmp_file, state_file)
        print(f"  {state_data['id']} recovered — status set back to active")

def main():
    while True:
        time.sleep(30)
        state_files = glob.glob(os.path.join(BASE_DIR, "envs", "*.json"))
        for file in state_files:
            env_id = os.path.basename(file).replace(".json", "")
            timestamp, status_code, latency = poll_health(env_id)
            if timestamp is not None:
                log_health(env_id, timestamp, status_code, latency)
                if check_consecutive_failures(env_id, status_code):
                    mark_degraded(file)
                    print(f"Warning: {env_id} has been marked as degraded due to 3 consecutive failures.")
                elif status_code == 200:
                    mark_active(file)
            else:
                log_health(env_id, time.time(), "Failed", 0)
                if check_consecutive_failures(env_id, status_code):
                    mark_degraded(file)

if __name__ == "__main__":
    main()