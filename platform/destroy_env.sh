#!/bin/bash
set -euo pipefail

# 1. Accept an ENV_ID
# 2. Stop and remove all containers labeled sandbox.env=$ENV_ID
# 3. Kill the log shipping process for this env
# 4. Remove the Docker network
# 5. Delete nginx/conf.d/$ENV_ID.conf
# 6. Reload Nginx
# 7. Archive logs to logs/archived/$ENV_ID/
# 8. Delete envs/$ENV_ID.json


ENV_ID="${1:?"Usage: $0 <env_id>"}"
# PATHS
BASE_DIR="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
NGINX_CONF="$BASE_DIR/nginx/conf.d/$ENV_ID.conf"
LOG_DIR="$BASE_DIR/logs/$ENV_ID"
STATE_FILE="$BASE_DIR/envs/$ENV_ID.json"
ARCHIVE_DIR="$BASE_DIR/logs/archived/$ENV_ID"

# 1. Stop and remove containers
CONTAINERS=$(docker ps -q --filter "label=sandbox.env=$ENV_ID")
if [ -n "$CONTAINERS" ]; then
  docker stop $CONTAINERS > /dev/null
  docker rm $CONTAINERS > /dev/null
fi

# Disconnect Nginx from this env's network before removing it
docker network disconnect "$ENV_ID" nginx 2>/dev/null || true

# 2. Remove Docker network
docker network rm "$ENV_ID" > /dev/null 2>&1 || true

# 3. Remove Nginx config
if [ -f "$NGINX_CONF" ]; then
  rm "$NGINX_CONF"
  # Reload Nginx
  docker exec nginx nginx -s reload
fi

# 4. Kill log shipping process
LOG_SHIP_PID_FILE="$BASE_DIR/logs/$ENV_ID.pid"
if [ -f "$LOG_SHIP_PID_FILE" ]; then
  LOG_SHIP_PID=$(cat "$LOG_SHIP_PID_FILE")
  if ps -p "$LOG_SHIP_PID" > /dev/null; then
    kill "$LOG_SHIP_PID"
  fi
  rm "$LOG_SHIP_PID_FILE"
fi

# 4. Archive logs
if [ -d "$LOG_DIR" ]; then
  mkdir -p "$ARCHIVE_DIR"
  mv "$LOG_DIR"/* "$ARCHIVE_DIR/"
  rmdir "$LOG_DIR"
fi

# 5. Delete state file
if [ -f "$STATE_FILE" ]; then
  rm "$STATE_FILE"
fi

echo "Environment $ENV_ID has been destroyed and logs archived to $ARCHIVE_DIR"