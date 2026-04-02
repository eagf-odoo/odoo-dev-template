include .env
export

.PHONY: start stop restart restart-all logs shell ps init restore upgrade test test-tags test-file build destroy fetch-all check-worktrees list-worktrees help

check-worktrees:
	@_version=$$(eval echo "$(ODOO_WORKTREE_PATH)/$(ODOO_VERSION)"); \
	if [ ! -d "$$_version" ]; then \
		echo ""; \
		echo "  \033[31mError: worktree not found for ODOO_VERSION=$(ODOO_VERSION)\033[0m"; \
		echo "  Run: bash worktree.sh add $(ODOO_VERSION)"; \
		echo ""; \
		exit 1; \
	fi

start: check-worktrees ## Start the environment
	docker compose up -d
	@echo ""
	@echo "  Waiting for Odoo to be ready..."
	@docker compose logs -f web 2>/dev/null | grep --line-buffered -m 1 "odoo.modules.loading: Modules loaded." > /dev/null \
		&& echo "  \033[32m✓ Odoo is ready → http://localhost:$${ODOO_PORT:-8069}\033[0m" \
		|| true
	@echo ""

stop: ## Stop the environment
	docker compose --profile pgadmin down

restart: ## Restart the Odoo server (keeps the database running)
	docker compose restart web

restart-all: stop start ## Restart the entire stack (Odoo + database)

logs: ## Stream Odoo server logs
	docker compose logs -f web

shell: ## Open a shell inside the Odoo container
	docker compose exec web bash

ps: ## Show container status
	docker compose ps

pgadmin: ## Start pgAdmin4 at http://localhost:5050
	docker compose --profile pgadmin up -d

init: check-worktrees ## Initialize a fresh database with the base module
	@echo ""
	@docker compose stop web > /dev/null 2>&1; true
	@echo "  Starting database service..."
	@docker compose up -d --wait db
	@echo "  Dropping existing database ($(ODOO_DB_NAME))..."
	@docker compose exec db dropdb -U odoo --if-exists $(ODOO_DB_NAME) > /dev/null 2>&1
	@echo "  Creating fresh database ($(ODOO_DB_NAME))..."
	@docker compose exec db createdb -U odoo $(ODOO_DB_NAME) > /dev/null 2>&1
	@echo "  Installing base module (this may take a while)..."
	@docker compose run --rm --no-deps web \
		python3 /mnt/reference/odoo/odoo-bin \
		--config /etc/odoo/odoo.conf \
		-d $(ODOO_DB_NAME) \
		-i base \
		--stop-after-init
	@echo ""
	@echo "  \033[32m✓ Database initialized. Run 'make start' to launch Odoo.\033[0m"
	@echo ""

restore: ## Restore a database. Usage: make restore dump=file.dump
	./restore.sh dumps/$(dump)

upgrade: ## Upgrade Odoo modules. Usage: make upgrade modules=mod1,mod2
	docker compose exec web python /mnt/reference/odoo/odoo-bin \
		-c /etc/odoo/odoo.conf \
		-d $(ODOO_DB_NAME) \
		-u $(modules) \
		--stop-after-init

test: ## Run tests for modules. Usage: make test modules=sale,account
	docker compose exec web python /mnt/reference/odoo/odoo-bin \
		-c /etc/odoo/odoo.conf \
		-d $(ODOO_DB_NAME) \
		-u $(modules) \
		--test-enable \
		--stop-after-init

test-tags: ## Run tests by tag. Usage: make test-tags tags=/module:Class.method
	docker compose exec web python /mnt/reference/odoo/odoo-bin \
		-c /etc/odoo/odoo.conf \
		-d $(ODOO_DB_NAME) \
		--test-tags $(tags) \
		--stop-after-init

test-file: ## Run tests from a file. Usage: make test-file file=/mnt/extra-addons/module/tests/test_x.py
	docker compose exec web python /mnt/reference/odoo/odoo-bin \
		-c /etc/odoo/odoo.conf \
		-d $(ODOO_DB_NAME) \
		--test-file $(file) \
		--stop-after-init

destroy: ## Remove all containers, networks and volumes (deletes the database)
	@echo ""
	@echo "  \033[33mWARNING\033[0m: This will remove all containers, networks and volumes."
	@echo "  The database '$(ODOO_DB_NAME)' will be permanently deleted."
	@echo ""
	@read -p "  Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ] \
		&& docker compose down -v \
		|| echo "Aborted."
	@echo ""

fetch-all: ## Fetch latest refs for all vault repos (odoo, enterprise, design-themes)
	@echo ""
	@for repo in odoo enterprise design-themes; do \
		echo "  Fetching $$repo..."; \
		git -C $(ODOO_VAULT_PATH)/$$repo.git fetch --prune origin; \
	done
	@echo ""

build: ## Build the Docker image for the target version. Usage: make build
	docker build \
		-t odoo-dev:$(ODOO_VERSION) \
		$(ODOO_WORKTREE_PATH)/$(ODOO_VERSION)

list-worktrees: ## List all available worktrees
	@_path=$$(eval echo "$(ODOO_WORKTREE_PATH)"); \
	echo ""; \
	echo "  Available worktrees in $$_path:"; \
	echo ""; \
	if [ ! -d "$$_path" ]; then \
		echo "  \033[31mDirectory not found: $$_path\033[0m"; \
	else \
		for dir in "$$_path"/*/; do \
			version=$$(basename "$$dir"); \
			if [ "$$version" = "$(ODOO_VERSION)" ]; then \
				echo "  \033[32m● $$version\033[0m  (active)"; \
			else \
				echo "  \033[90m○ $$version\033[0m"; \
			fi; \
		done; \
	fi
	@echo ""

help: ## Show this help message
	@echo ""
	@echo "Usage: make <command> [options]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make restore dump=client_prod.dump"
	@echo "  make upgrade modules=sale,account"
	@echo "  make build"
	@echo ""
