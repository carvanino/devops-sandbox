import os
import time
from flask import Flask, jsonify

app = Flask(__name__)

START_TIME = time.time()
ENV_ID     = os.environ.get("ENV_ID", "unknown")
ENV_NAME   = os.environ.get("ENV_NAME", "unknown")


@app.route("/")
def index():
    return jsonify({
        "message":   f"Hello from sandbox environment '{ENV_NAME}'",
        "env_id":    ENV_ID,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    })


@app.route("/health")
def health():
    return jsonify({
        "status": "ok",
        "env_id": ENV_ID,
        "uptime": int(time.time() - START_TIME)
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=3000)
