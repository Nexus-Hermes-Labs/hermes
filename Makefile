.PHONY: help \
        network \
        setup fresh install \
        up up-prod down restart clean \
        dev dev-prod \
        logs logs-traefik logs-backend logs-fe \
        logs-auth logs-user logs-guild logs-channel \
        ps status health \
        db-migrate db-seed db-reset db-shell sqlx-prepare \
        build build-release check test test-verbose lint format fmt ci \
        fe-install fe-build fe-typecheck fe-lint

# ── Colors ────────────────────────────────────────────────────────────────────
BLUE   := \033[0;34m
GREEN  := \033[0;32m
YELLOW := \033[1;33m
RED    := \033[0;31m
CYAN   := \033[0;36m
NC     := \033[0m

# ── Compose shortcuts ─────────────────────────────────────────────────────────
DC              := docker compose
COMPOSE_TRAEFIK := $(DC) -f docker-compose.yml
COMPOSE_BACKEND := $(DC) -f hermes-be/docker-compose.yml
COMPOSE_FE_DEV  := $(DC) -f hermes-fe/docker-compose.yml --profile dev
COMPOSE_FE_PROD := $(DC) -f hermes-fe/docker-compose.yml --profile prod

# ── Default target ────────────────────────────────────────────────────────────
.DEFAULT_GOAL := help

##@ Help

help: ## Show this help
	@echo -e "$(CYAN)Hermes — Real-time Communication Platform$(NC)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"; printf "Usage:\n  make $(GREEN)<target>$(NC)\n"} \
		/^[a-zA-Z_-]+:.*?##/ { printf "  $(GREEN)%-22s$(NC) %s\n", $$1, $$2 } \
		/^##@/ { printf "\n$(YELLOW)%s$(NC)\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ First-time Setup

install: ## Install host dev tools (sqlx-cli, cargo-watch, cargo-audit)
	@echo -e "$(BLUE)Installing Rust dev tools...$(NC)"
	@cargo install sqlx-cli --no-default-features --features postgres
	@cargo install cargo-watch
	@cargo install cargo-audit
	@echo -e "$(BLUE)Installing frontend dev tools...$(NC)"
	@cd hermes-fe && npm install
	@echo -e "$(GREEN)All dev tools installed$(NC)"

setup: ## Full first-time setup: network → env → npm → up → migrate → seed
	@echo -e "$(CYAN)=== Hermes First-time Setup ===$(NC)"
	@$(MAKE) network
	@test -f hermes-be/.env \
		|| (echo -e "$(BLUE)Copying .env.example → .env$(NC)" \
			&& cp hermes-be/.env.example hermes-be/.env \
			&& echo -e "$(YELLOW)Edit hermes-be/.env before continuing if needed$(NC)")
	@$(MAKE) fe-install
	@echo -e "$(BLUE)Starting infrastructure and services...$(NC)"
	@$(COMPOSE_TRAEFIK) up -d --wait
	@$(COMPOSE_BACKEND) up -d --wait
	@echo -e "$(BLUE)Running migrations...$(NC)"
	@$(MAKE) db-migrate
	@echo -e "$(BLUE)Seeding database...$(NC)"
	@$(MAKE) db-seed
	@echo -e "$(BLUE)Starting frontend (dev)...$(NC)"
	@$(COMPOSE_FE_DEV) up -d
	@echo ""
	@echo -e "$(GREEN)Setup complete!$(NC)"
	@echo -e "  App:       $(CYAN)http://localhost$(NC)"
	@echo -e "  Traefik:   $(CYAN)http://localhost:8080$(NC)"
	@echo -e "  Grafana:   $(CYAN)http://localhost:3000$(NC)"
	@echo -e "  Mailpit:   $(CYAN)http://localhost:8025$(NC)"

fresh: clean setup ## Nuke everything and set up from scratch

##@ Network

network: ## Create shared Docker network (idempotent)
	@docker network inspect hermes-network >/dev/null 2>&1 \
		|| (echo -e "$(BLUE)Creating hermes-network...$(NC)" \
			&& docker network create hermes-network \
			&& echo -e "$(GREEN)hermes-network created$(NC)")

##@ Running

up: network ## Start all containers without migrations (dev frontend)
	@echo -e "$(BLUE)Starting Traefik...$(NC)"
	@$(COMPOSE_TRAEFIK) up -d --wait
	@echo -e "$(BLUE)Starting backend + infra...$(NC)"
	@$(COMPOSE_BACKEND) up -d --wait
	@echo -e "$(BLUE)Starting frontend (dev)...$(NC)"
	@$(COMPOSE_FE_DEV) up -d
	@echo -e "$(GREEN)All services up → http://localhost$(NC)"

up-prod: network ## Start all containers in production mode
	@echo -e "$(BLUE)Starting Traefik...$(NC)"
	@$(COMPOSE_TRAEFIK) up -d --wait
	@echo -e "$(BLUE)Starting backend + infra...$(NC)"
	@$(COMPOSE_BACKEND) up -d --wait
	@echo -e "$(BLUE)Building & starting frontend (prod)...$(NC)"
	@$(COMPOSE_FE_PROD) up -d --build
	@echo -e "$(GREEN)All services up → http://localhost$(NC)"

dev: network ## Start dev environment: up → migrate → seed
	@$(MAKE) up
	@echo -e "$(BLUE)Running migrations...$(NC)"
	@$(MAKE) db-migrate
	@echo -e "$(BLUE)Seeding database...$(NC)"
	@$(MAKE) db-seed
	@echo -e "$(GREEN)Dev environment ready → http://localhost$(NC)"

dev-prod: network ## Start prod environment: up-prod → migrate → seed
	@$(MAKE) up-prod
	@echo -e "$(BLUE)Running migrations...$(NC)"
	@$(MAKE) db-migrate
	@echo -e "$(BLUE)Seeding database...$(NC)"
	@$(MAKE) db-seed
	@echo -e "$(GREEN)Prod environment ready → http://localhost$(NC)"

down: ## Stop all services (all profiles)
	@echo -e "$(YELLOW)Stopping frontend...$(NC)"
	@$(COMPOSE_FE_DEV)  down 2>/dev/null || true
	@$(COMPOSE_FE_PROD) down 2>/dev/null || true
	@echo -e "$(YELLOW)Stopping backend + infra...$(NC)"
	@$(COMPOSE_BACKEND) down
	@echo -e "$(YELLOW)Stopping Traefik...$(NC)"
	@$(COMPOSE_TRAEFIK) down
	@echo -e "$(GREEN)All services stopped$(NC)"

restart: down up ## Restart all services (dev mode)

clean: ## Remove all containers, volumes, and the shared network
	@echo -e "$(RED)Cleaning up all Docker resources...$(NC)"
	@docker ps -aq --filter name=hermes | xargs -r docker rm -f 2>/dev/null || true
	@$(COMPOSE_FE_DEV)  down -v 2>/dev/null || true
	@$(COMPOSE_FE_PROD) down -v 2>/dev/null || true
	@$(COMPOSE_BACKEND) down -v
	@$(COMPOSE_TRAEFIK) down -v
	@docker network rm hermes-network 2>/dev/null || true
	@echo -e "$(GREEN)Cleanup complete$(NC)"

##@ Logs

logs: ## Tail logs from all hermes containers (interleaved)
	@docker ps --filter name=hermes --format "{{.Names}}" \
		| xargs -I{} sh -c 'docker logs -f --tail=50 {} 2>&1 | sed "s/^/[{}] /" &' \
		; wait

logs-traefik: ## Traefik logs
	@$(COMPOSE_TRAEFIK) logs -f

logs-backend: ## All backend + infra logs
	@$(COMPOSE_BACKEND) logs -f

logs-fe: ## Frontend logs (dev or prod, whichever is running)
	@$(COMPOSE_FE_DEV) logs -f 2>/dev/null || $(COMPOSE_FE_PROD) logs -f

logs-auth: ## auth-service logs
	@$(COMPOSE_BACKEND) logs -f auth-service

logs-user: ## user-service logs
	@$(COMPOSE_BACKEND) logs -f user-service

logs-guild: ## guild-service logs
	@$(COMPOSE_BACKEND) logs -f guild-service

logs-channel: ## channel-service logs
	@$(COMPOSE_BACKEND) logs -f channel-service

logs-postgres: ## PostgreSQL logs
	@$(COMPOSE_BACKEND) logs -f postgres

logs-redis: ## Redis logs
	@$(COMPOSE_BACKEND) logs -f redis

##@ Status

ps: ## Show all running containers
	@docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

status: ## Detailed health overview
	@echo -e "$(CYAN)=== Hermes Status ===$(NC)"
	@docker ps --filter name=hermes --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

health: ## Show only unhealthy/starting containers
	@echo -e "$(CYAN)Container health:$(NC)"
	@docker ps --filter name=hermes --format "{{.Names}}: {{.Status}}" \
		| grep -v "healthy" || echo -e "$(GREEN)All containers healthy$(NC)"

##@ Database

db-migrate: ## Run all service migrations
	@$(MAKE) -C hermes-be db-migrate

db-seed: ## Seed all service databases
	@$(MAKE) -C hermes-be db-seed

db-reset: ## Drop volumes, restart, migrate, seed
	@$(MAKE) -C hermes-be db-reset

db-shell: ## Open a psql shell into Postgres
	@$(MAKE) -C hermes-be db-shell

sqlx-prepare: ## Generate SQLx offline query metadata (commit the output)
	@echo -e "$(BLUE)Preparing SQLx offline metadata...$(NC)"
	@$(MAKE) -C hermes-be sqlx-prepare

##@ Backend

build: ## Build all Rust services (debug)
	@$(MAKE) -C hermes-be build

build-release: ## Build all Rust services (release)
	@$(MAKE) -C hermes-be build-release

check: ## Cargo check (fast, no codegen)
	@$(MAKE) -C hermes-be check

test: ## Run all Rust tests
	@$(MAKE) -C hermes-be test

test-verbose: ## Run tests with stdout output
	@$(MAKE) -C hermes-be test-verbose

lint: ## Run clippy (deny warnings)
	@$(MAKE) -C hermes-be lint

format: ## Format all Rust code
	@$(MAKE) -C hermes-be format

fmt: format ## Alias for format

ci: ## Run full CI suite: fmt-check + lint + test
	@$(MAKE) -C hermes-be ci

##@ Frontend

fe-install: ## Install npm dependencies
	@echo -e "$(BLUE)Installing frontend dependencies...$(NC)"
	@cd hermes-fe && npm install
	@echo -e "$(GREEN)Done$(NC)"

fe-build: ## Build frontend for production (outputs dist/)
	@echo -e "$(BLUE)Building frontend...$(NC)"
	@cd hermes-fe && npm run build
	@echo -e "$(GREEN)Frontend built$(NC)"

fe-typecheck: ## TypeScript type check
	@cd hermes-fe && npm run type-check

fe-lint: ## ESLint check
	@cd hermes-fe && npm run lint
