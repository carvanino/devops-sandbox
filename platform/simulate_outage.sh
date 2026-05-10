#!/bin/bash
set -euo pipefail

# 1. Accept --env and --mode flags
# 2. Guard: refuse if target is Nginx or daemon container
# 3. Execute the chosen mode:
#    crash   → docker kill container
#    pause   → docker pause container
#    network → docker network disconnect container
#    recover → docker unpause OR reconnect network
#    stress  → spike CPU with stress-ng




ENV_ID=""
MODE=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --env) ENV_ID="$2"; shift ;;
        --mode) MODE="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [[ -z "$ENV_ID" || -z "$MODE" ]]; then
    echo "Usage: $0 --env <env_id> --mode <crash|pause|network|recover|stress>"
    exit 1
fi

# Guard against Nginx and daemon containers
# if [[ "$ENV_ID" == "nginx" || "$ENV_ID" == "daemon" ]]; then
#     echo "Error: Cannot target $ENV_ID container for outage simulation."
#     exit 1
# fi

if ! docker inspect "$ENV_ID" --format '{{index .Config.Labels "sandbox.env"}}' 2>/dev/null | grep -q "$ENV_ID"; then
    echo "Error: $ENV_ID is not a sandbox environment. Simulation refused."
    exit 1
fi



case "$MODE" in
    crash)
        docker kill "$ENV_ID"
        ;;
    pause)
        docker pause "$ENV_ID"
        ;;
    network)
        docker network disconnect "$ENV_ID" "$ENV_ID"
        ;;
    recover)
        # Try to unpause first, if it fails, try to reconnect network
        docker unpause "$ENV_ID" 2>/dev/null || true
        docker network connect "$ENV_ID" "$ENV_ID" 2>/dev/null || true
        echo "Recovery attempted for $ENV_ID"
        ;;
    stress)
        docker exec "$ENV_ID" stress-ng --cpu 4 --timeout 60s
        ;;
    *)
        echo "Unknown mode: $MODE. Valid modes are: crash, pause, network, recover, stress."
        exit 1
        ;;
esac