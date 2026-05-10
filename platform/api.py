#!/usr/bin/env python3

import os
import json
import glob
import subprocess
import time
from datetime import datetime
from flask import Flask, request, jsonify

app = Flask(__name__)

BASE_DIR    = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLATFORM    = os.path.join(BASE_DIR, "platform")
ENV_DIR     = os.path.join(BASE_DIR, "envs")
LOG_DIR     = os.path.join(BASE_DIR, "logs")


# Helpers 

def load_state(env_id):
    """Read and return the state file for an env."""
    state_file = os.path.join(ENV_DIR, f"{env_id}.json")
    if not os.path.exists(state_file):
        return None
    with open(state_file) as f:
        return json.load(f)

def all_envs():
    """Return list of all active env state dicts."""
    envs = []
    for f in glob.glob(os.path.join(ENV_DIR, "*.json")):
        try:
            with open(f) as fh:
                envs.append(json.load(fh))
        except Exception:
            pass
    return envs

def run_script(script, *args):
    """
    Run a platform script with arguments.
    Returns (returncode, stdout, stderr).
    """
    cmd = ["bash", os.path.join(PLATFORM, script)] + list(args)
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode, result.stdout.strip(), result.stderr.strip()

def ttl_remaining(state):
    """Calculate seconds remaining before env expires."""
    created_at = state.get("created_at", 0)
    ttl        = state.get("ttl", 1800)
    expiry     = created_at + ttl
    remaining  = expiry - int(time.time())
    return max(remaining, 0)


# Endpoints

# POST /envs — create a new environment
@app.route("/envs", methods=["POST"])
def create_env():
    body = request.get_json(silent=True) or {}
    name = body.get("name")
    ttl  = body.get("ttl", 1800)

    if not name:
        return jsonify({"error": "name is required"}), 400

    code, stdout, stderr = run_script("create_env.sh", name, str(ttl))
    if code != 0:
        return jsonify({"error": stderr or "Failed to create environment"}), 500

    # Extract the ENV_ID from the output
    env_id = None
    for line in stdout.splitlines():
        if "ID:" in line:
            env_id = line.split("ID:")[-1].strip()
            break

    return jsonify({
        "message": f"Environment '{name}' created",
        "env_id":  env_id,
        "url":     f"http://localhost/envs/{env_id}/",
        "ttl":     ttl,
        "output":  stdout
    }), 201


# GET /envs — list all active environments with TTL remaining
@app.route("/envs", methods=["GET"])
def list_envs():
    envs = all_envs()
    result = []
    for env in envs:
        result.append({
            "id":            env.get("id"),
            "name":          env.get("name"),
            "status":        env.get("status"),
            "created_at":    env.get("created_at"),
            "ttl":           env.get("ttl"),
            "ttl_remaining": ttl_remaining(env),
            "url":           f"http://localhost/envs/{env.get('id')}/"
        })
    return jsonify({"envs": result, "count": len(result)})


# DELETE /envs/:id — destroy a specific environment
@app.route("/envs/<env_id>", methods=["DELETE"])
def destroy_env(env_id):
    state = load_state(env_id)
    if not state:
        return jsonify({"error": f"Environment {env_id} not found"}), 404

    code, stdout, stderr = run_script("destroy_env.sh", env_id)
    if code != 0:
        return jsonify({"error": stderr or "Failed to destroy environment"}), 500

    return jsonify({"message": f"Environment {env_id} destroyed", "output": stdout})


# GET /envs/:id/logs — last 100 lines of app.log
@app.route("/envs/<env_id>/logs", methods=["GET"])
def get_logs(env_id):
    state = load_state(env_id)
    if not state:
        return jsonify({"error": f"Environment {env_id} not found"}), 404

    log_file = os.path.join(LOG_DIR, env_id, "app.log")

    # Also check archived logs
    if not os.path.exists(log_file):
        log_file = os.path.join(LOG_DIR, "archived", env_id, "app.log")

    if not os.path.exists(log_file):
        return jsonify({"env_id": env_id, "logs": [], "message": "No logs found"}), 200

    with open(log_file) as f:
        lines = f.readlines()

    last_100 = [l.rstrip() for l in lines[-100:]]
    return jsonify({"env_id": env_id, "logs": last_100, "count": len(last_100)})


# GET /envs/:id/health — last 10 health check results
@app.route("/envs/<env_id>/health", methods=["GET"])
def get_health(env_id):
    state = load_state(env_id)
    if not state:
        return jsonify({"error": f"Environment {env_id} not found"}), 404

    health_file = os.path.join(LOG_DIR, env_id, "health.log")
    if not os.path.exists(health_file):
        return jsonify({"env_id": env_id, "health": [], "status": state.get("status")}), 200

    with open(health_file) as f:
        lines = f.readlines()

    last_10 = [l.rstrip() for l in lines[-10:]]
    return jsonify({
        "env_id":  env_id,
        "status":  state.get("status"),
        "health":  last_10,
        "count":   len(last_10)
    })


# POST /envs/:id/outage — trigger outage simulation
@app.route("/envs/<env_id>/outage", methods=["POST"])
def simulate_outage(env_id):
    state = load_state(env_id)
    if not state:
        return jsonify({"error": f"Environment {env_id} not found"}), 404

    body = request.get_json(silent=True) or {}
    mode = body.get("mode")

    valid_modes = ["crash", "pause", "network", "recover", "stress"]
    if not mode or mode not in valid_modes:
        return jsonify({"error": f"mode must be one of: {', '.join(valid_modes)}"}), 400

    code, stdout, stderr = run_script(
        "simulate_outage.sh",
        "--env", env_id,
        "--mode", mode
    )

    if code != 0:
        return jsonify({"error": stderr or "Outage simulation failed"}), 500

    return jsonify({
        "env_id":  env_id,
        "mode":    mode,
        "message": f"Outage simulation '{mode}' triggered",
        "output":  stdout
    })


# Entry point 

if __name__ == "__main__":
    os.makedirs(ENV_DIR, exist_ok=True)
    os.makedirs(LOG_DIR, exist_ok=True)
    app.run(host="0.0.0.0", port=5000, debug=False)
