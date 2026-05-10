#!/bin/bash
set -euo pipefail

# 1. Accept a name and optional TTL from the user
# 2. Generate a unique ENV_ID (e.g. env-abc123)
# 3. Create a dedicated Docker network for this env
# 4. Start the app container on that network
#    - label it with sandbox.env=$ENV_ID
# 5. Write state file to envs/$ENV_ID.json
#    - records: ID, name, created_at, TTL, status
# 6. Write nginx/conf.d/$ENV_ID.conf 
# 7. Reload Nginx - done
# 8. Start log shipping in background
# 9. Print the env URL and TTL to the user



# Input
ENV_NAME="${1:?"Usage: $0 <env_name> [ttl_seconds]"}"
TTL="${2:-1800}" # default TTL is 60 minutes

# Generate a unique ENV_ID
ENV_ID="env-$(openssl rand -hex 2)"

# PATHS
BASE_DIR="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
NGINX_CONF="$BASE_DIR/nginx/conf.d/$ENV_ID.conf"
LOG_DIR="$BASE_DIR/logs/$ENV_ID"
STATE_FILE="$BASE_DIR/envs/$ENV_ID.json"


# Directory setup
mkdir -p "$LOG_DIR"
mkdir -p "$BASE_DIR/envs"
mkdir -p "$BASE_DIR/nginx/conf.d"

# 1. Create Docker network
docker network create "$ENV_ID" > /dev/null

# Connect Nginx container to this env's network so it can proxy to the app
docker network connect "$ENV_ID" nginx 2>/dev/null || true

# 2. Start app container
docker run -d \
  --name "$ENV_ID" \
  --network "$ENV_ID" \
  --label "sandbox.env=$ENV_ID" \
  -e "ENV_ID=$ENV_ID" \
  -e "ENV_NAME=$ENV_NAME" \
  -v "$LOG_DIR:/app/logs" \
  myapp:latest > /dev/null

# 3. Write state file
CREATED_AT=$(date -u +%s)
TEMP_FILE=$(mktemp)
jq -n \
  --arg id "$ENV_ID" \
  --arg name "$ENV_NAME" \
  --argjson created_at "$CREATED_AT" \
  --argjson ttl "$TTL" \
  --arg status "active" \
  '{id: $id, name: $name, created_at: $created_at, ttl: ($ttl), status: $status}' > "$TEMP_FILE"

mv "$TEMP_FILE" "$STATE_FILE"

# 4. Write Nginx config — location block only (included inside main server block)
cat > "$NGINX_CONF" <<EOL
location /envs/$ENV_ID/ {
    proxy_pass http://$ENV_ID:3000/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}
EOL
docker exec nginx nginx -s reload

# 5. Start log shipping in background
docker logs -f "$ENV_ID" > "$LOG_DIR/app.log" 2>&1 &
# Store the PID of the log shipping process so we can kill it later
echo $! > "$LOG_DIR/log_ship.pid"




# 6. Print env URL and TTL
echo "✔     Environment '$ENV_NAME' created with ID: $ENV_ID"
echo "      Access it at: http://localhost/envs/$ENV_ID/"
echo "      TTL: $TTL seconds"