# DevOps Sandbox Platform
# Usage: make <target> [ENV=env-id] [MODE=crash]

SHELL        := /bin/bash
BASE_DIR     := $(shell pwd)
PLATFORM     := $(BASE_DIR)/platform
ENV_DIR      := $(BASE_DIR)/envs
LOG_DIR      := $(BASE_DIR)/logs

.PHONY: up down create destroy logs health simulate clean

# ── Start the platform ────────────────────────────────────────────
up:
	@echo "Installing Python dependencies..."
	pip install -r $(PLATFORM)/requirements.txt -q
	docker run -d \
		--name nginx \
		-v $(BASE_DIR)/nginx/nginx.conf:/etc/nginx/nginx.conf:ro \
		-v $(BASE_DIR)/nginx/conf.d:/etc/nginx/conf.d \
		-p 80:80 \
		nginx:latest
	@echo "Building demo app image..."
	docker build -t myapp:latest $(PLATFORM)/app
	@echo "Starting cleanup daemon..."
	nohup bash $(PLATFORM)/cleanup_daemon.sh >> $(LOG_DIR)/cleanup.log 2>&1 &
	@echo "Starting health poller..."
	@pkill -f health_poller.py 2>/dev/null || true
	nohup python3 $(BASE_DIR)/monitor/health_poller.py >> $(LOG_DIR)/health_poller.log 2>&1 &
	@echo "Starting API server..."
	@pkill -f api.py 2>/dev/null || true
	nohup python3 $(PLATFORM)/api.py >> $(LOG_DIR)/api.log 2>&1 &
	@echo "✔ Platform is up — API on http://localhost:5000"

# ── Stop the platform ─────────────────────────────────────────────
down:
	@echo "Destroying all active environments..."
	@for file in $(ENV_DIR)/*.json; do \
		[ -f "$$file" ] || continue; \
		ENV_ID=$$(basename $$file .json); \
		echo "  Destroying $$ENV_ID..."; \
		bash $(PLATFORM)/destroy_env.sh $$ENV_ID || true; \
	done
	@echo "Stopping Nginx container..."
	docker stop nginx 2>/dev/null && docker rm nginx 2>/dev/null || true
	@echo "✔ Platform is down"

# ── Create a new environment ──────────────────────────────────────
create:
	@read -p "Environment name: " name; \
	read -p "TTL in seconds [1800]: " ttl; \
	ttl=$${ttl:-1800}; \
	bash $(PLATFORM)/create_env.sh $$name $$ttl

# ── Destroy a specific environment ────────────────────────────────
destroy:
	@[ -n "$(ENV)" ] || (echo "Usage: make destroy ENV=<env-id>" && exit 1)
	bash $(PLATFORM)/destroy_env.sh $(ENV)

# ── Tail logs for a specific environment ─────────────────────────
logs:
	@[ -n "$(ENV)" ] || (echo "Usage: make logs ENV=<env-id>" && exit 1)
	@LOG_FILE=$(LOG_DIR)/$(ENV)/app.log; \
	ARCHIVE=$(LOG_DIR)/archived/$(ENV)/app.log; \
	if [ -f "$$LOG_FILE" ]; then \
		tail -f "$$LOG_FILE"; \
	elif [ -f "$$ARCHIVE" ]; then \
		tail -100 "$$ARCHIVE"; \
	else \
		echo "No logs found for $(ENV)"; \
	fi

# ── Show health status for all environments ───────────────────────
health:
	@echo "=== Environment Health Status ==="; \
	for file in $(ENV_DIR)/*.json; do \
		[ -f "$$file" ] || continue; \
		ENV_ID=$$(basename $$file .json); \
		STATUS=$$(jq -r '.status' $$file); \
		NAME=$$(jq -r '.name' $$file); \
		echo "  $$ENV_ID ($$NAME): $$STATUS"; \
		HEALTH_LOG=$(LOG_DIR)/$$ENV_ID/health.log; \
		if [ -f "$$HEALTH_LOG" ]; then \
			tail -1 "$$HEALTH_LOG"; \
		fi; \
	done

# ── Simulate an outage ────────────────────────────────────────────
simulate:
	@[ -n "$(ENV)" ]  || (echo "Usage: make simulate ENV=<env-id> MODE=<crash|pause|network|recover|stress>" && exit 1)
	@[ -n "$(MODE)" ] || (echo "Usage: make simulate ENV=<env-id> MODE=<crash|pause|network|recover|stress>" && exit 1)
	bash $(PLATFORM)/simulate_outage.sh --env $(ENV) --mode $(MODE)

# ── Wipe all state, logs, and archives ────────────────────────────
clean:
	@echo "Wiping all state and logs..."
	rm -rf $(ENV_DIR)/*.json
	rm -rf $(LOG_DIR)/*
	rm -rf $(BASE_DIR)/nginx/conf.d/*.conf
	@echo "✔ Clean"
