.PHONY: help \
        network \
        setup fresh install \
        up up-prod down restart clean prune \
        dev dev-prod \
        logs logs-traefik logs-backend logs-fe \
        logs-auth logs-user logs-guild logs-channel logs-messaging logs-chat logs-realtime \
        logs-postgres logs-redis logs-nats \
        ps status health \
        db-migrate db-seed db-reset \
        db-shell-auth db-shell-user db-shell-guild db-shell-channel db-shell-messaging \
        sqlx-prepare \
        build build-release check test test-verbose lint format fmt ci \
        fe-install fe-build fe-typecheck fe-lint

# ── Colors ────────────────────────────────────────────────────────────────────
BLUE   := \033[0;34m
GREEN  := \033[0;32m
YELLOW := \033[1;33m
RED    := \033[0;31m
CYAN   := \033[0;36m
NC     := \033[0m

# ── Build flags ───────────────────────────────────────────────────────────────
BUILD_FLAG ?=

# ── Compose shortcuts ─────────────────────────────────────────────────────────
DC                   := docker compose
COMPOSE_TRAEFIK      := $(DC) -f infra/traefik/docker-compose.yml
COMPOSE_INFRA        := $(DC) -f hermes-be/infra/docker-compose.yml
COMPOSE_AUTH         := $(DC) -f hermes-be/services/auth-service/docker-compose.yml
COMPOSE_USER         := $(DC) -f hermes-be/services/user-service/docker-compose.yml
COMPOSE_GUILD        := $(DC) -f hermes-be/services/guild-service/docker-compose.yml
COMPOSE_CHANNEL      := $(DC) -f hermes-be/services/channel-service/docker-compose.yml
COMPOSE_MESSAGING    := $(DC) -f hermes-be/services/messaging-service/docker-compose.yml
COMPOSE_CHAT         := $(DC) -f hermes-be/services/chat-service/docker-compose.yml
COMPOSE_REALTIME     := $(DC) -f hermes-be/services/realtime-service/docker-compose.yml
COMPOSE_FE_DEV       := $(DC) -f hermes-fe/docker-compose.yml --profile dev
COMPOSE_FE_PROD      := $(DC) -f hermes-fe/docker-compose.yml --profile prod

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

setup: ## Full first-time setup: network → env → npm → up
	@echo -e "$(CYAN)=== Hermes First-time Setup ===$(NC)"
	@$(MAKE) network
	@test -f hermes-be/.env \
		|| (echo -e "$(BLUE)Copying .env.example → .env$(NC)" \
			&& cp hermes-be/.env.example hermes-be/.env \
			&& echo -e "$(YELLOW)Edit hermes-be/.env before continuing if needed$(NC)")
	@$(MAKE) fe-install
	@echo -e "$(BLUE)Starting infrastructure and services...$(NC)"
	@$(MAKE) up
	@echo ""
	@echo -e "$(GREEN)Setup complete!$(NC)"
	@echo -e "  App:       $(CYAN)http://localhost$(NC)"
	@echo -e "  Traefik:   $(CYAN)http://localhost:8080$(NC)"
	@echo -e "  Grafana:   $(CYAN)http://localhost:3000$(NC)"
	@echo -e "  Mailpit:   $(CYAN)http://localhost:8025$(NC)"

fresh: clean ## Nuke everything, rebuild all images, and set up from scratch
	@echo -e "$(CYAN)=== Hermes Fresh Start ===$(NC)"
	@$(MAKE) network
	@test -f hermes-be/.env \
		|| (echo -e "$(BLUE)Copying .env.example → .env$(NC)" \
			&& cp hermes-be/.env.example hermes-be/.env \
			&& echo -e "$(YELLOW)Edit hermes-be/.env before continuing if needed$(NC)")
	@$(MAKE) fe-install
	@$(MAKE) up BUILD_FLAG=--build
	@echo ""
	@echo -e "$(GREEN)Setup complete!$(NC)"
	@echo -e "  App:       $(CYAN)http://localhost$(NC)"
	@echo -e "  Traefik:   $(CYAN)http://localhost:8080$(NC)"
	@echo -e "  Grafana:   $(CYAN)http://localhost:3000$(NC)"
	@echo -e "  Mailpit:   $(CYAN)http://localhost:8025$(NC)"

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
	@echo -e "$(BLUE)Starting backend infra...$(NC)"
	@$(COMPOSE_INFRA) up -d --wait
	@echo -e "$(BLUE)Starting backend services...$(NC)"
	@$(COMPOSE_AUTH)      up -d $(BUILD_FLAG) 2>&1 | grep -v "Found orphan"
	@$(COMPOSE_USER)      up -d $(BUILD_FLAG) 2>&1 | grep -v "Found orphan"
	@$(COMPOSE_GUILD)     up -d $(BUILD_FLAG) 2>&1 | grep -v "Found orphan"
	@$(COMPOSE_CHANNEL)   up -d $(BUILD_FLAG) 2>&1 | grep -v "Found orphan"
	@$(COMPOSE_MESSAGING) up -d $(BUILD_FLAG) 2>&1 | grep -v "Found orphan"
	@$(COMPOSE_CHAT)      up -d $(BUILD_FLAG) 2>&1 | grep -v "Found orphan"
	@$(COMPOSE_REALTIME)  up -d $(BUILD_FLAG) 2>&1 | grep -v "Found orphan"
	@echo -e "$(BLUE)Starting frontend (dev)...$(NC)"
	@$(COMPOSE_FE_DEV) up -d
	@echo -e "$(GREEN)All services up → http://localhost$(NC)"

up-prod: network ## Start all containers in production mode
	@echo -e "$(BLUE)Starting Traefik...$(NC)"
	@$(COMPOSE_TRAEFIK) up -d --wait
	@echo -e "$(BLUE)Starting backend infra...$(NC)"
	@$(COMPOSE_INFRA) up -d --wait
	@echo -e "$(BLUE)Starting backend services...$(NC)"
	@$(COMPOSE_AUTH) up -d 2>&1 | grep -v "Found orphan"
	@$(COMPOSE_USER) up -d 2>&1 | grep -v "Found orphan"
	@$(COMPOSE_GUILD) up -d 2>&1 | grep -v "Found orphan"
	@$(COMPOSE_CHANNEL) up -d 2>&1 | grep -v "Found orphan"
	@$(COMPOSE_MESSAGING) up -d 2>&1 | grep -v "Found orphan"
	@$(COMPOSE_CHAT) up -d 2>&1 | grep -v "Found orphan"
	@$(COMPOSE_REALTIME) up -d 2>&1 | grep -v "Found orphan"
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
	@echo -e "$(YELLOW)Stopping backend services...$(NC)"
	@$(COMPOSE_AUTH)      down 2>/dev/null || true
	@$(COMPOSE_USER)      down 2>/dev/null || true
	@$(COMPOSE_GUILD)     down 2>/dev/null || true
	@$(COMPOSE_CHANNEL)   down 2>/dev/null || true
	@$(COMPOSE_MESSAGING) down 2>/dev/null || true
	@$(COMPOSE_CHAT)      down 2>/dev/null || true
	@$(COMPOSE_REALTIME)  down 2>/dev/null || true
	@echo -e "$(YELLOW)Stopping backend infra...$(NC)"
	@$(COMPOSE_INFRA) down
	@echo -e "$(YELLOW)Stopping Traefik...$(NC)"
	@$(COMPOSE_TRAEFIK) down
	@echo -e "$(GREEN)All services stopped$(NC)"

restart: down up ## Restart all services (dev mode)

clean: ## Remove all containers, volumes, locally-built images, and the shared network
	@echo -e "$(RED)Cleaning up all Docker resources...$(NC)"
	@docker ps -aq --filter name=hermes | xargs -r docker rm -f 2>/dev/null || true
	@$(COMPOSE_FE_DEV)    down -v --rmi local 2>/dev/null || true
	@$(COMPOSE_FE_PROD)   down -v --rmi local 2>/dev/null || true
	@$(COMPOSE_AUTH)      down -v --rmi local 2>/dev/null || true
	@$(COMPOSE_USER)      down -v --rmi local 2>/dev/null || true
	@$(COMPOSE_GUILD)     down -v --rmi local 2>/dev/null || true
	@$(COMPOSE_CHANNEL)   down -v --rmi local 2>/dev/null || true
	@$(COMPOSE_MESSAGING) down -v --rmi local 2>/dev/null || true
	@$(COMPOSE_CHAT)      down -v --rmi local 2>/dev/null || true
	@$(COMPOSE_REALTIME)  down -v --rmi local 2>/dev/null || true
	@$(COMPOSE_INFRA)     down -v --rmi local
	@$(COMPOSE_TRAEFIK)   down -v --rmi local
	@docker network rm hermes-network 2>/dev/null || true
	@echo -e "$(BLUE)Pruning dangling images and build cache...$(NC)"
	@docker image prune -f >/dev/null
	@docker builder prune -f >/dev/null
	@echo -e "$(GREEN)Cleanup complete$(NC)"

prune: ## Deep clean: dangling images + builder cache (keeps running containers)
	@echo -e "$(BLUE)Pruning dangling images...$(NC)"
	@docker image prune -f
	@echo -e "$(BLUE)Pruning builder cache...$(NC)"
	@docker builder prune -f
	@echo -e "$(GREEN)Prune complete$(NC)"

##@ Logs

logs: ## Tail logs from all hermes containers (interleaved)
	@docker ps --filter name=hermes --format "{{.Names}}" \
		| xargs -I{} sh -c 'docker logs -f --tail=50 {} 2>&1 | sed "s/^/[{}] /" &' \
		; wait

logs-traefik: ## Traefik logs
	@$(COMPOSE_TRAEFIK) logs -f

logs-backend: ## All backend infra logs
	@$(COMPOSE_INFRA) logs -f

logs-fe: ## Frontend logs (dev or prod, whichever is running)
	@$(COMPOSE_FE_DEV) logs -f 2>/dev/null || $(COMPOSE_FE_PROD) logs -f

logs-auth: ## auth-service logs
	@$(COMPOSE_AUTH) logs -f auth-service

logs-user: ## user-service logs
	@$(COMPOSE_USER) logs -f user-service

logs-guild: ## guild-service logs
	@$(COMPOSE_GUILD) logs -f guild-service

logs-channel: ## channel-service logs
	@$(COMPOSE_CHANNEL) logs -f channel-service

logs-messaging: ## messaging-service logs
	@$(COMPOSE_MESSAGING) logs -f messaging-service

logs-chat: ## chat-service logs
	@$(COMPOSE_CHAT) logs -f chat-service

logs-realtime: ## realtime-service logs
	@$(COMPOSE_REALTIME) logs -f realtime-service

logs-postgres: ## PostgreSQL logs
	@$(COMPOSE_INFRA) logs -f postgres

logs-redis: ## Redis logs
	@$(COMPOSE_INFRA) logs -f redis

logs-nats: ## NATS logs
	@$(COMPOSE_INFRA) logs -f nats

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

db-shell-auth: ## Open psql shell for hermes_auth
	@$(MAKE) -C hermes-be db-shell-auth

db-shell-user: ## Open psql shell for hermes_user
	@$(MAKE) -C hermes-be db-shell-user

db-shell-guild: ## Open psql shell for hermes_guild
	@$(MAKE) -C hermes-be db-shell-guild

db-shell-channel: ## Open psql shell for hermes_channel
	@$(MAKE) -C hermes-be db-shell-channel

db-shell-messaging: ## Open psql shell for hermes_messaging
	@$(MAKE) -C hermes-be db-shell-messaging

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
