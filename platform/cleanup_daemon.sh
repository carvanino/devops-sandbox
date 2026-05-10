#!/bin/bash 
set -euo pipefail

# Loop forever:
#   1. Sleep 60 seconds
#   2. For each file in envs/:
#      - Read created_at and TTL
#      - Calculate expiry time
#      - If now > expiry → call destroy_env.sh
#      - Log the action with timestamp to logs/cleanup.log

BASE_DIR="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
ENV_DIR="$BASE_DIR/envs"
LOG_FILE="$BASE_DIR/logs/cleanup.log"


chmod +x "$BASE_DIR/platform/destroy_env.sh"

while true; do
    sleep 60
    for FILE in "$ENV_DIR"/*.json; do
        if [ -f "$FILE" ]; then
            ENV_ID=$(basename "$FILE" .json)
            CREATED_AT=$(jq -r '.created_at' "$FILE")
            TTL=$(jq -r '.ttl' "$FILE")
            EXPIRY_TIME=$((CREATED_AT + TTL))
            CURRENT_TIME=$(date -u +%s)

            if [ "$CURRENT_TIME" -gt "$EXPIRY_TIME" ]; then
                # Log the cleanup action
                echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Expiring environment $ENV_ID (created at $(date -u -d "@$CREATED_AT" +"%Y-%m-%dT%H:%M:%SZ"), TTL: $TTL seconds)" >> "$LOG_FILE"
                # Call destroy_env.sh
                "$BASE_DIR/platform/destroy_env.sh" "$ENV_ID"
            fi
        fi

    done
done

