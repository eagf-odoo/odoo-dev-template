-include .env
export

ODOO_MODE          ?= development
CUSTOMERS_PATH     ?= $(HOME)/Odoo/Customers
ODOO_VAULT_PATH    ?= $(HOME)/Odoo/.vault
ODOO_WORKTREE_PATH ?= $(HOME)/Odoo/Worktrees
ODOO_UPGRADE_PATH  ?= $(HOME)/Odoo/Upgrade
DUMPS_PATH         ?= $(HOME)/Odoo/Dumps
EXTERNAL_DISK_PATH ?=

# Compose files — base + mode-specific override
COMPOSE_FILES := -f docker-compose.yml -f docker-compose.$(ODOO_MODE).yml

# External disk overlay — redirects Postgres data + filestore off the internal disk
ifneq ($(strip $(EXTERNAL_DISK_PATH)),)
COMPOSE_FILES += -f docker-compose.external.yml
endif

# Auxiliary HTTP port for update/test processes running alongside the live server.
# The container always binds Odoo on 8069; this port avoids the conflict.
ODOO_AUX_HTTP_PORT := 8071

# Agent-specific overlays — appended only when running make agent
AGENT_COMPOSE_EXTRA :=
ifeq ($(ODOO_MODE),upgrade)
AGENT_COMPOSE_EXTRA += -f docker-compose.upgrade.agent.yml
endif
ifeq ($(AGENT_CUSTOMER_ACCESS),true)
AGENT_COMPOSE_EXTRA += -f docker-compose.agent.customer.yml
endif

# Mode-specific variables
ifeq ($(ODOO_MODE),upgrade)
ODOO_BIN      := /opt/odoo-src/odoo/odoo-bin
ODOO_CONF     := /etc/odoo/odoo.upgrade.conf
BUILD_VERSION := $(ODOO_TARGET_VERSION)
else
ODOO_BIN      := /mnt/reference/odoo/odoo-bin
ODOO_CONF     := /etc/odoo/odoo.conf
BUILD_VERSION := $(ODOO_VERSION)
endif

# Demo data flag — Odoo 19 inverted the default (demo was ON by default, now OFF).
# demo=true  → 17/18: no flag needed  |  19: --with-demo
# demo=false → 17/18: --without-demo all  |  19: no flag needed
ifeq ($(demo),true)
_DEMO_FLAG := $(if $(filter 19.%,$(BUILD_VERSION)),--with-demo,)
else
_DEMO_FLAG := $(if $(filter 19.%,$(BUILD_VERSION)),,--without-demo all)
endif

.PHONY: start stop restart restart-all logs shell psql extract ps restore restore-external update test test-tags test-file build build-agent destroy reset-agent pull-all worktree worktree-add worktree-remove check-env check-image check-ports check-worktrees check-version check-agent-image check-claude-md check-running list list-db list-worktrees workspace agent help

check-env:
	@if [ ! -f .env ]; then \
		echo ""; \
		echo "  \033[31mError: .env not found.\033[0m"; \
		echo "  Copy .env.example to .env and configure it before running this command."; \
		echo ""; \
		exit 1; \
	fi
	@ok=1; \
	_fail() { printf "  \033[31mError: %s is not set in .env\033[0m\n" "$$1"; ok=0; }; \
	[ -n "$(ODOO_DB_NAME)" ]   || _fail ODOO_DB_NAME; \
	[ -n "$(CUSTOMER_REPO)" ]  || _fail CUSTOMER_REPO; \
	if [ "$(ODOO_MODE)" = "upgrade" ]; then \
		[ -n "$(ODOO_SOURCE_VERSION)" ] || _fail ODOO_SOURCE_VERSION; \
		[ -n "$(ODOO_TARGET_VERSION)" ] || _fail ODOO_TARGET_VERSION; \
	else \
		[ -n "$(ODOO_VERSION)" ] || _fail ODOO_VERSION; \
	fi; \
	[ "$$ok" = "1" ] || { echo ""; echo "  Fix the above before running make."; echo ""; exit 1; }

check-agent-image:
	@[ -f $(HOME)/.odoo-agent.json ] && [ -s $(HOME)/.odoo-agent.json ] || printf '{}' > $(HOME)/.odoo-agent.json
	@if ! docker image inspect odoo-agent:latest > /dev/null 2>&1; then \
		echo ""; \
		printf "  Building agent image for the first time...\n"; \
		docker build -f dockerfiles/agent.Dockerfile -t odoo-agent:latest . \
			&& printf "  \033[32m✓ Agent image ready.\033[0m\n" \
			|| { echo ""; echo "  \033[31mFailed to build the agent image.\033[0m"; echo ""; exit 1; }; \
		echo ""; \
	fi

check-claude-md:
	@_claude_file="$${CLAUDE_PATH:-$$HOME/Odoo/.claude-md/CLAUDE.md}"; \
	_claude_dir="$$(dirname "$$_claude_file")"; \
	if [ ! -f "$$_claude_file" ]; then \
		echo ""; \
		echo "  \033[31mError: CLAUDE.md system prompt not found at $$_claude_file\033[0m"; \
		echo ""; \
		echo "  Option 1 (recommended):  re-run setup.sh — it skips what's already installed"; \
		echo "  Option 2 (manual):       git clone git@github.com:odoo-ps/psmx-claude-md.git ~/Odoo/.claude-md"; \
		echo ""; \
		exit 1; \
	fi; \
	if [ ! -d "$$_claude_dir/.git" ]; then exit 0; fi; \
	timeout 3s git -C "$$_claude_dir" fetch origin --quiet 2>/dev/null & \
	_pid=$$!; _i=0; \
	while kill -0 "$$_pid" 2>/dev/null; do \
		case $$((_i % 4)) in \
			0) printf '\r  | Checking CLAUDE.md for updates...' ;; \
			1) printf '\r  / Checking CLAUDE.md for updates...' ;; \
			2) printf '\r  - Checking CLAUDE.md for updates...' ;; \
			*) printf '\r  + Checking CLAUDE.md for updates...' ;; \
		esac; \
		sleep 0.15; \
		_i=$$((_i + 1)); \
	done; \
	wait "$$_pid" 2>/dev/null; \
	printf '\r%-60s\r' ''; \
	_local=$$(git -C "$$_claude_dir" rev-parse HEAD 2>/dev/null); \
	_remote=$$(git -C "$$_claude_dir" rev-parse origin/HEAD 2>/dev/null); \
	[ -z "$$_remote" ] && _remote=$$(git -C "$$_claude_dir" rev-parse origin/main 2>/dev/null); \
	if [ -n "$$_local" ] && [ -n "$$_remote" ] && [ "$$_local" != "$$_remote" ]; then \
		_behind=$$(git -C "$$_claude_dir" rev-list HEAD.."$$_remote" --count 2>/dev/null); \
		echo ""; \
		printf "  \033[33m⚠  CLAUDE.md is $$_behind commit(s) behind — run: git -C $$_claude_dir pull\033[0m\n"; \
		echo ""; \
	fi

check-running: check-env
	@if [ -z "$$(docker compose $(COMPOSE_FILES) ps -q --status running web 2>/dev/null)" ]; then \
		echo ""; \
		echo "  \033[31mError: The environment is not running.\033[0m"; \
		echo "  Start it first with: make start"; \
		echo ""; \
		exit 1; \
	fi

check-image:
	@if ! docker info > /dev/null 2>&1; then \
		echo ""; \
		echo "  \033[31mError: Docker is not running.\033[0m"; \
		echo "  Start Docker Desktop and try again."; \
		echo ""; \
		exit 1; \
	fi
	@if ! docker image inspect odoo-dev:$(BUILD_VERSION) > /dev/null 2>&1; then \
		if [ -n "$$(docker images --filter reference=odoo-dev:$(BUILD_VERSION) --format '{{.ID}}')" ]; then \
			printf "  \033[33mDocker Desktop reinitialized — re-registering image (cache)...\033[0m\n"; \
			printf "  (This may take a minute if the cache is cold — output shown below)\n\n"; \
			docker build --progress=plain -t odoo-dev:$(BUILD_VERSION) $(ODOO_WORKTREE_PATH)/$(BUILD_VERSION) \
				&& printf "\n  \033[32m✓ Image re-registered.\033[0m\n" \
				|| { echo ""; echo "  \033[31mFailed to re-register. Run: make build\033[0m"; echo ""; exit 1; }; \
		else \
			echo ""; \
			echo "  \033[31mError: image odoo-dev:$(BUILD_VERSION) not found in current context.\033[0m"; \
			_found=""; \
			_current=$$(docker context show 2>/dev/null); \
			for _ctx in $$(docker context ls -q 2>/dev/null); do \
				[ "$$_ctx" = "$$_current" ] && continue; \
				if docker --context "$$_ctx" image inspect odoo-dev:$(BUILD_VERSION) > /dev/null 2>&1; then \
					_found="$$_ctx"; \
					break; \
				fi; \
			done; \
			if [ -n "$$_found" ]; then \
				echo "  Found in context '\033[33m$$_found\033[0m' but active context is '\033[33m$$_current\033[0m'."; \
				echo "  Option 1: switch context →  docker context use $$_found"; \
				echo "  Option 2: rebuild here   →  make build"; \
			else \
				echo "  Run: make build"; \
			fi; \
			echo ""; \
			exit 1; \
		fi; \
	fi

check-ports:
	@_ok=1; \
	_our_containers=$$(docker compose $(COMPOSE_FILES) ps --format '{{.Name}}' 2>/dev/null); \
	_check_port() { \
		_port=$$1; _var=$$2; \
		_container=$$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null \
			| awk -v p="$$_port" '$$0 ~ ":"p"->" {print $$1}'); \
		if [ -n "$$_container" ]; then \
			if ! echo "$$_our_containers" | grep -qF "$$_container"; then \
				echo ""; \
				echo "  \033[31mError: $$_var=$$_port is already used by container '$$_container'.\033[0m"; \
				echo "  Set a different $$_var in .env (e.g. $$_var=$$((_port + 1)))"; \
				_ok=0; \
			fi; \
		elif lsof -i "TCP:$$_port" -sTCP:LISTEN > /dev/null 2>&1; then \
			echo ""; \
			echo "  \033[31mError: $$_var=$$_port is already in use by another process.\033[0m"; \
			echo "  Set a different $$_var in .env (e.g. $$_var=$$((_port + 1)))"; \
			_ok=0; \
		fi; \
	}; \
	_check_port "$${ODOO_PORT:-8069}" "ODOO_PORT"; \
	_check_port "$${ODOO_DEBUG_PORT:-5678}" "ODOO_DEBUG_PORT"; \
	_check_port "$${PGADMIN_PORT:-5050}" "PGADMIN_PORT"; \
	[ "$$_ok" = "1" ] || { echo ""; exit 1; }

check-worktrees:
	@if [ "$(ODOO_MODE)" = "upgrade" ]; then \
		_target=$$(eval echo "$(ODOO_WORKTREE_PATH)/$(ODOO_TARGET_VERSION)"); \
		if [ ! -d "$$_target" ]; then \
			echo ""; \
			echo "  \033[31mError: worktree not found for ODOO_TARGET_VERSION=$(ODOO_TARGET_VERSION)\033[0m"; \
			echo "  Run: make worktree-add VERSION=$(ODOO_TARGET_VERSION)"; \
			echo ""; \
			exit 1; \
		fi; \
		_source=$$(eval echo "$(ODOO_WORKTREE_PATH)/$(ODOO_SOURCE_VERSION)"); \
		if [ ! -d "$$_source" ]; then \
			echo ""; \
			echo "  \033[31mError: worktree not found for ODOO_SOURCE_VERSION=$(ODOO_SOURCE_VERSION)\033[0m"; \
			echo "  Run: make worktree-add VERSION=$(ODOO_SOURCE_VERSION)"; \
			echo ""; \
			exit 1; \
		fi; \
	else \
		_version=$$(eval echo "$(ODOO_WORKTREE_PATH)/$(ODOO_VERSION)"); \
		if [ ! -d "$$_version" ]; then \
			echo ""; \
			echo "  \033[31mError: worktree not found for ODOO_VERSION=$(ODOO_VERSION)\033[0m"; \
			echo "  Run: make worktree-add VERSION=$(ODOO_VERSION)"; \
			echo ""; \
			exit 1; \
		fi; \
	fi

check-version:
	@_local=$$(git describe --tags --abbrev=0 2>/dev/null); \
	_remote=$$(git ls-remote --tags origin 'v*' 2>/dev/null \
		| grep -v '\^{}' | sed 's|.*refs/tags/||' | sort -V | tail -1); \
	if [ -n "$$_local" ] && [ -n "$$_remote" ] && [ "$$_local" != "$$_remote" ]; then \
		_newer=$$(printf '%s\n%s' "$$_local" "$$_remote" | sort -V | tail -1); \
		if [ "$$_newer" = "$$_remote" ]; then \
			echo ""; \
			echo "  \033[33m⚠ New version available: $$_local → $$_remote  (git pull to update)\033[0m"; \
			echo ""; \
		fi; \
	fi

start: check-env check-worktrees check-image check-ports workspace check-version ## Start the environment
	@_was_running=0; \
	docker compose $(COMPOSE_FILES) ps --services --filter status=running 2>/dev/null | grep -q "^web$$" && _was_running=1; \
	docker compose $(COMPOSE_FILES) up -d && \
	echo "" && \
	if [ "$$_was_running" = "1" ]; then \
		echo "  \033[32m✓ Environment reloaded → http://localhost:$${ODOO_PORT:-8069}\033[0m"; \
		echo "  (picked up any .env changes — version, ports, etc.)"; \
	else \
		echo "  \033[32m✓ Environment started → http://localhost:$${ODOO_PORT:-8069}\033[0m"; \
	fi && \
	echo "  Run 'make logs' in a new terminal to follow the Odoo startup." && \
	echo ""

stop: check-env ## Stop the environment
	docker compose $(COMPOSE_FILES) --profile pgadmin down

restart: check-env ## Restart the Odoo server (keeps the database running)
	docker compose $(COMPOSE_FILES) restart web

restart-all: stop start ## Restart the entire stack (Odoo + database)

logs: check-env ## Stream Odoo server logs
	docker compose $(COMPOSE_FILES) logs -f web

shell: check-running ## Open an Odoo ORM shell. Usage: make shell [script=path/to/script.py] [db=other_name]
ifdef script
	docker compose $(COMPOSE_FILES) exec -T web python $(ODOO_BIN) shell \
		-c $(ODOO_CONF) \
		-d $(if $(db),$(db),$(ODOO_DB_NAME)) < $(script)
else
	docker compose $(COMPOSE_FILES) exec web python $(ODOO_BIN) shell \
		-c $(ODOO_CONF) \
		-d $(if $(db),$(db),$(ODOO_DB_NAME))
endif

psql: check-running ## Open a psql shell. Usage: make psql [db=other_name]
	docker compose $(COMPOSE_FILES) exec db psql -U odoo -d $(if $(db),$(db),$(ODOO_DB_NAME))

extract: check-running ## Extract a file from the db container. Usage: make extract src=/tmp/file.csv [dest=.]
	@[ -n "$(src)" ] || { echo ""; echo "  \033[31mError: src= is required. Usage: make extract src=/tmp/file.csv [dest=.]\033[0m"; echo ""; exit 1; }
	docker compose $(COMPOSE_FILES) cp db:$(src) $(if $(dest),$(dest),.)

ps: check-env ## Show container status
	docker compose $(COMPOSE_FILES) ps

pgadmin: check-env check-ports ## Start pgAdmin4 at http://localhost:5050
	@echo ""
	@echo "  Waiting for pgAdmin to be ready..."
	@docker compose $(COMPOSE_FILES) --profile pgadmin up -d --wait \
		&& echo "  \033[32m✓ pgAdmin is ready → http://localhost:$${PGADMIN_PORT:-5050}\033[0m" \
		|| true
	@echo ""

agent: check-env check-worktrees check-agent-image check-claude-md ## Start the AI agent and open a Claude Code session
	docker compose $(COMPOSE_FILES) $(AGENT_COMPOSE_EXTRA) run --rm agent

reset: check-env check-worktrees ## Reset the database: drop, recreate, and install base module. Usage: make reset [demo=true]
	@echo ""
	@echo "  \033[33mWARNING\033[0m: This will drop and recreate the database '$(ODOO_DB_NAME)'."
	@echo ""
	@read -rp "  Are you sure? [y/N] " confirm; \
	[ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ] || { echo "  Aborted."; exit 1; }
	@echo ""
	@docker compose $(COMPOSE_FILES) stop web > /dev/null 2>&1; true
	@echo "  Starting database service..."
	@docker compose $(COMPOSE_FILES) up -d --wait db
	@echo "  Dropping existing database ($(ODOO_DB_NAME))..."
	@docker compose $(COMPOSE_FILES) exec db dropdb -U odoo --if-exists $(ODOO_DB_NAME) > /dev/null 2>&1
	@echo "  Creating fresh database ($(ODOO_DB_NAME))..."
	@docker compose $(COMPOSE_FILES) exec db createdb -U odoo $(ODOO_DB_NAME) > /dev/null 2>&1
	@_log=$$(mktemp /tmp/odoo-init.XXXXXX); \
	docker compose $(COMPOSE_FILES) run --rm --no-deps -T web \
		python3 $(ODOO_BIN) --config $(ODOO_CONF) \
		-d $(ODOO_DB_NAME) -i base $(_DEMO_FLAG) --stop-after-init \
		> "$$_log" 2>&1 & \
	_pid=$$!; _i=0; \
	while kill -0 "$$_pid" 2>/dev/null; do \
		case $$((_i % 4)) in \
			0) printf '\r  | Installing base module...' ;; \
			1) printf '\r  / Installing base module...' ;; \
			2) printf '\r  - Installing base module...' ;; \
			*) printf '\r  + Installing base module...' ;; \
		esac; \
		sleep 0.15; \
		_i=$$((_i + 1)); \
	done; \
	wait "$$_pid"; _code=$$?; \
	printf '\r%-60s\r' ''; \
	if [ "$$_code" -ne 0 ]; then \
		printf '  \033[31mError during base module installation.\033[0m\n\n'; \
		cat "$$_log"; \
		rm -f "$$_log"; \
		exit $$_code; \
	fi; \
	rm -f "$$_log"; \
	echo "  Installing base module... done"
	@echo ""
	@echo "  \033[32m✓ Database initialized. Run 'make start' to launch Odoo.\033[0m"
	@echo ""

restore: check-running ## Restore a database. Usage: make restore dump=backup.zip [db=other_name]
	@[ -n "$(dump)" ] || { echo ""; echo "  \033[31mError: dump= is required. Usage: make restore dump=backup.zip [db=other_name]\033[0m"; echo ""; exit 1; }
	./restore.sh dumps/$(dump) $(db)

restore-external: check-running ## Restore a database with data on an external disk. Usage: make restore-external dump=backup.zip [db=other_name]
	@[ -n "$(EXTERNAL_DISK_PATH)" ] || { echo ""; echo "  \033[31mError: EXTERNAL_DISK_PATH is not set in .env.\033[0m"; echo "  Set it to the mount point of your external disk — see .env.example."; echo ""; exit 1; }
	@[ -d "$(EXTERNAL_DISK_PATH)" ] && [ -w "$(EXTERNAL_DISK_PATH)" ] || { echo ""; echo "  \033[31mError: EXTERNAL_DISK_PATH ($(EXTERNAL_DISK_PATH)) does not exist or is not writable.\033[0m"; echo "  Make sure the external disk is connected and mounted."; echo ""; exit 1; }
	@[ -n "$(dump)" ] || { echo ""; echo "  \033[31mError: dump= is required. Usage: make restore-external dump=backup.zip [db=other_name]\033[0m"; echo ""; exit 1; }
	@echo ""
	@echo "  \033[32m✓ Restoring to external disk: $(EXTERNAL_DISK_PATH)\033[0m"
	@echo ""
	./restore.sh dumps/$(dump) $(db)

clean-filestore: check-env ## Remove a database's data dir (filestore + sessions) from disk. Usage: make clean-filestore [db=other_name]
	@_db=$(if $(db),$(db),$(ODOO_DB_NAME)); \
	_root=$(if $(strip $(EXTERNAL_DISK_PATH)),$(EXTERNAL_DISK_PATH)/.data,$(HOME)/Odoo/.data); \
	_target="$$_root/$$_db"; \
	if [ ! -d "$$_target" ]; then \
		echo ""; \
		echo "  Nothing to clean — $$_target does not exist."; \
		echo ""; \
		exit 0; \
	fi; \
	echo ""; \
	echo "  \033[33mWARNING\033[0m: This will delete the data directory for '$$_db':"; \
	echo "  $$_target"; \
	echo "  This includes the filestore (attachments, reports) and session data."; \
	echo "  This action is irreversible."; \
	echo ""; \
	read -rp "  Are you sure? [y/N] " confirm; \
	[ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ] || { echo "  Aborted."; exit 1; }; \
	docker compose $(COMPOSE_FILES) stop web > /dev/null 2>&1; true; \
	rm -rf "$$_target"; \
	echo ""; \
	echo "  \033[32m✓ Removed $$_target\033[0m"; \
	echo ""

update: check-running check-worktrees ## Update Odoo modules. Usage: make update modules=mod1,mod2 [db=other_name] [flags="--i18n-overwrite"]
	@[ -n "$(modules)" ] || { echo ""; echo "  \033[31mError: modules= is required. Usage: make update modules=mod1,mod2\033[0m"; echo ""; exit 1; }
	docker compose $(COMPOSE_FILES) exec web python $(ODOO_BIN) \
		-c $(ODOO_CONF) \
		-d $(if $(db),$(db),$(ODOO_DB_NAME)) \
		-u $(modules) \
		--http-port $(ODOO_AUX_HTTP_PORT) \
		--stop-after-init \
		$(flags)

test: check-running check-worktrees ## Run tests for modules. Usage: make test modules=sale,account [demo=true] [db=other_name] [flags="--i18n-overwrite"]
	@[ -n "$(modules)" ] || { echo ""; echo "  \033[31mError: modules= is required. Usage: make test modules=mod1,mod2\033[0m"; echo ""; exit 1; }
	docker compose $(COMPOSE_FILES) exec web python $(ODOO_BIN) \
		-c $(ODOO_CONF) \
		-d $(if $(db),$(db),$(ODOO_DB_NAME)) \
		-u $(modules) \
		--test-enable \
		--http-port $(ODOO_AUX_HTTP_PORT) \
		$(_DEMO_FLAG) \
		--stop-after-init \
		$(flags)

test-tags: check-running check-worktrees ## Run tests by tag. Usage: make test-tags tags=/module:Class.method [demo=true] [db=other_name] [flags="--i18n-overwrite"]
	@[ -n "$(tags)" ] || { echo ""; echo "  \033[31mError: tags= is required. Usage: make test-tags tags=/module:Class.method\033[0m"; echo ""; exit 1; }
	docker compose $(COMPOSE_FILES) exec web python $(ODOO_BIN) \
		-c $(ODOO_CONF) \
		-d $(if $(db),$(db),$(ODOO_DB_NAME)) \
		--test-tags $(tags) \
		--http-port $(ODOO_AUX_HTTP_PORT) \
		$(_DEMO_FLAG) \
		--stop-after-init \
		$(flags)

test-file: check-running check-worktrees ## Run tests from a file. Usage: make test-file file=/mnt/extra-addons/module/tests/test_x.py [demo=true] [db=other_name]
	@[ -n "$(file)" ] || { echo ""; echo "  \033[31mError: file= is required. Usage: make test-file file=/mnt/extra-addons/module/tests/test_x.py\033[0m"; echo ""; exit 1; }
	docker compose $(COMPOSE_FILES) exec web python $(ODOO_BIN) \
		-c $(ODOO_CONF) \
		-d $(if $(db),$(db),$(ODOO_DB_NAME)) \
		--test-file $(file) \
		--http-port $(ODOO_AUX_HTTP_PORT) \
		$(_DEMO_FLAG) \
		--stop-after-init

destroy: check-env ## Remove all containers, networks and volumes (deletes the database)
	@echo ""
	@echo "  \033[33mWARNING\033[0m: This will remove all containers, networks, and Odoo volumes,"
	@echo "  and the Odoo data directory for '$(ODOO_DB_NAME)'."
	@echo "  The AI agent volume (skills, session) is preserved. Use 'make reset-agent' to clear it."
	@echo "  This action is irreversible."
	@echo ""
	@read -p "  Are you sure? [y/N] " confirm; \
	if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then \
		echo "  Aborted."; \
		exit 0; \
	fi; \
	_log=$$(mktemp /tmp/odoo-destroy.XXXXXX); \
	_dbfile=$$(mktemp /tmp/odoo-destroy-dbs.XXXXXX); \
	( \
		if docker compose $(COMPOSE_FILES) up -d --wait db > "$$_log" 2>&1; then \
			docker compose $(COMPOSE_FILES) exec -T db psql -U odoo -d postgres -Atc \
				"SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres' ORDER BY datname;" \
				> "$$_dbfile" 2>>"$$_log"; \
		else \
			exit 1; \
		fi \
	) & \
	_pid=$$!; _i=0; \
	while kill -0 "$$_pid" 2>/dev/null; do \
		case $$((_i % 4)) in \
			0) printf '\r  | Checking for existing databases...' ;; \
			1) printf '\r  / Checking for existing databases...' ;; \
			2) printf '\r  - Checking for existing databases...' ;; \
			*) printf '\r  + Checking for existing databases...' ;; \
		esac; \
		sleep 0.15; \
		_i=$$((_i + 1)); \
	done; \
	wait "$$_pid"; _code=$$?; \
	printf '\r%-60s\r' ''; \
	if [ "$$_code" -eq 0 ]; then \
		_dbs="$$(cat "$$_dbfile") $(ODOO_DB_NAME)"; \
		echo "  Checking for existing databases... done"; \
	else \
		echo "  \033[33mWarning\033[0m: could not reach the database — only removing the filestore for '$(ODOO_DB_NAME)'."; \
		echo "  Filestores for any secondary databases (e.g. restored via 'db=other_name') may be left orphaned on disk."; \
		_dbs="$(ODOO_DB_NAME)"; \
	fi; \
	rm -f "$$_log" "$$_dbfile"; \
	\
	_log=$$(mktemp /tmp/odoo-destroy.XXXXXX); \
	( \
		if [ -n "$(strip $(EXTERNAL_DISK_PATH))" ]; then \
			for _db in $$_dbs; do rm -rf "$(EXTERNAL_DISK_PATH)/.data/$$_db"; done; \
		else \
			for _db in $$_dbs; do rm -rf "$(HOME)/Odoo/.data/$$_db"; done; \
		fi \
	) > "$$_log" 2>&1 & \
	_pid=$$!; _i=0; \
	while kill -0 "$$_pid" 2>/dev/null; do \
		case $$((_i % 4)) in \
			0) printf '\r  | Removing filestore(s)...' ;; \
			1) printf '\r  / Removing filestore(s)...' ;; \
			2) printf '\r  - Removing filestore(s)...' ;; \
			*) printf '\r  + Removing filestore(s)...' ;; \
		esac; \
		sleep 0.15; \
		_i=$$((_i + 1)); \
	done; \
	wait "$$_pid"; _code=$$?; \
	printf '\r%-60s\r' ''; \
	if [ "$$_code" -ne 0 ]; then \
		printf '  \033[31mError removing filestore(s).\033[0m\n\n'; \
		cat "$$_log"; \
		rm -f "$$_log"; \
		exit $$_code; \
	fi; \
	rm -f "$$_log"; \
	echo "  Removing filestore(s)... done"; \
	\
	_log=$$(mktemp /tmp/odoo-destroy.XXXXXX); \
	( docker compose $(COMPOSE_FILES) --profile pgadmin down \
		&& { docker volume rm --force $(COMPOSE_PROJECT_NAME)_odoo-pgadmin-data 2>/dev/null || true; } \
	) > "$$_log" 2>&1 & \
	_pid=$$!; _i=0; \
	while kill -0 "$$_pid" 2>/dev/null; do \
		case $$((_i % 4)) in \
			0) printf '\r  | Stopping and removing containers...' ;; \
			1) printf '\r  / Stopping and removing containers...' ;; \
			2) printf '\r  - Stopping and removing containers...' ;; \
			*) printf '\r  + Stopping and removing containers...' ;; \
		esac; \
		sleep 0.15; \
		_i=$$((_i + 1)); \
	done; \
	wait "$$_pid"; _code=$$?; \
	printf '\r%-60s\r' ''; \
	if [ "$$_code" -ne 0 ]; then \
		printf '  \033[31mError stopping/removing containers.\033[0m\n\n'; \
		cat "$$_log"; \
		rm -f "$$_log"; \
		exit $$_code; \
	fi; \
	rm -f "$$_log"; \
	echo "  Stopping and removing containers... done"; \
	\
	_log=$$(mktemp /tmp/odoo-destroy.XXXXXX); \
	( \
		if [ -n "$(strip $(EXTERNAL_DISK_PATH))" ]; then \
			rm -rf "$(EXTERNAL_DISK_PATH)/pgdata/$(ODOO_DB_NAME)"; \
		else \
			docker volume rm --force $(COMPOSE_PROJECT_NAME)_odoo-db-data 2>/dev/null || true; \
		fi \
	) > "$$_log" 2>&1 & \
	_pid=$$!; _i=0; \
	while kill -0 "$$_pid" 2>/dev/null; do \
		case $$((_i % 4)) in \
			0) printf '\r  | Removing database files...' ;; \
			1) printf '\r  / Removing database files...' ;; \
			2) printf '\r  - Removing database files...' ;; \
			*) printf '\r  + Removing database files...' ;; \
		esac; \
		sleep 0.15; \
		_i=$$((_i + 1)); \
	done; \
	wait "$$_pid"; _code=$$?; \
	printf '\r%-60s\r' ''; \
	if [ "$$_code" -ne 0 ]; then \
		printf '  \033[31mError removing database files.\033[0m\n\n'; \
		cat "$$_log"; \
		rm -f "$$_log"; \
		exit $$_code; \
	fi; \
	rm -f "$$_log"; \
	echo "  Removing database files... done"; \
	echo ""; \
	echo "  \033[32m✓ Environment destroyed.\033[0m"
	@echo ""

reset-agent: ## Remove the agent state directory (clears session, skills, and memory across all projects)
	@echo ""
	@echo "  \033[33mWARNING\033[0m: This will remove ~/.odoo-agent and ~/.odoo-agent.json — you will need to"
	@echo "  re-authenticate with claude.ai on the next 'make agent' run."
	@echo "  This affects ALL client projects on this machine."
	@echo ""
	@read -p "  Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ] \
		&& rm -rf $(HOME)/.odoo-agent $(HOME)/.odoo-agent.json \
		&& echo "" \
		&& echo "  \033[32m✓ Agent state removed.\033[0m" \
		|| echo "Aborted."
	@echo ""

workspace: check-env
	@cp workspace/$(ODOO_MODE).json odoo-dev.code-workspace
	@echo ""
	@echo "  \033[32m✓ odoo-dev.code-workspace updated (mode: $(ODOO_MODE))\033[0m"
	@echo ""

worktree: ## Open the interactive worktree manager (add or remove)
	@bash worktree.sh

worktree-add: ## Add a worktree — usage: make worktree-add VERSION=19.0
	@bash worktree.sh add $(VERSION)

worktree-remove: ## Remove a worktree — usage: make worktree-remove VERSION=17.0
	@bash worktree.sh remove $(VERSION)


pull-all: ## Update all worktrees to the latest commit on their origin branch
	@bash pull-all.sh

build: check-env ## Build the Docker image for the active version
	docker build \
		-t odoo-dev:$(BUILD_VERSION) \
		$(ODOO_WORKTREE_PATH)/$(BUILD_VERSION)

build-agent: ## Build the AI agent Docker image
	docker build -f dockerfiles/agent.Dockerfile -t odoo-agent:latest .

list: check-env ## List all client environments and their running status
	@_base="$(CUSTOMERS_PATH)"; \
	echo ""; \
	if [ ! -d "$$_base" ]; then \
		echo "  \033[31mDirectory not found: $$_base\033[0m"; \
		echo "  Create it or set CUSTOMERS_PATH in your .env."; \
		echo ""; \
		exit 0; \
	fi; \
	echo "  Clients in $$_base:"; \
	echo ""; \
	found=0; \
	for dir in "$$_base"/*/; do \
		[ -d "$$dir" ] || continue; \
		found=1; \
		name=$$(basename "$$dir"); \
		_dir_clean="$${dir%/}"; \
		running=$$(docker ps -q --filter "label=com.docker.compose.project.working_dir=$$_dir_clean" 2>/dev/null); \
		if [ -n "$$running" ]; then \
			printf "  \033[32m● %-20s\033[0m  running\n" "$$name"; \
		else \
			printf "  \033[90m○ %-20s\033[0m\n" "$$name"; \
		fi; \
	done; \
	[ "$$found" = "1" ] || echo "  No clients found."; \
	echo ""

list-db: check-env ## List all databases in this client's Postgres container
	@if ! docker info > /dev/null 2>&1; then \
		echo ""; \
		echo "  \033[31mError: Docker is not running.\033[0m"; \
		echo "  Start Docker Desktop and try again."; \
		echo ""; \
		exit 1; \
	fi
	@if [ -z "$$(docker compose $(COMPOSE_FILES) ps -q --status running db 2>/dev/null)" ]; then \
		echo ""; \
		echo "  \033[31mError: The database container is not running.\033[0m"; \
		echo "  Start it first with: make start"; \
		echo ""; \
		exit 1; \
	fi
	@echo ""
	@echo "  Databases in this client's Postgres:"
	@echo ""
	@_dbs=$$(docker compose $(COMPOSE_FILES) exec -T db psql -U odoo -d postgres -Atc \
		"SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres' ORDER BY datname;" 2>/dev/null); \
	if [ -z "$$_dbs" ]; then \
		echo "  \033[33mNo databases found.\033[0m"; \
	else \
		echo "$$_dbs" | while read -r _db; do \
			if [ "$$_db" = "$(ODOO_DB_NAME)" ]; then \
				printf "  \033[32m● %s\033[0m  (active)\n" "$$_db"; \
			else \
				printf "  \033[90m○ %s\033[0m\n" "$$_db"; \
			fi; \
		done; \
	fi
	@echo ""

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
			if [ "$(ODOO_MODE)" = "upgrade" ]; then \
				if [ "$$version" = "$(ODOO_TARGET_VERSION)" ]; then \
					echo "  \033[32m● $$version\033[0m  (target)"; \
				elif [ "$$version" = "$(ODOO_SOURCE_VERSION)" ]; then \
					echo "  \033[36m● $$version\033[0m  (source)"; \
				else \
					echo "  \033[90m○ $$version\033[0m"; \
				fi; \
			else \
				if [ "$$version" = "$(ODOO_VERSION)" ]; then \
					echo "  \033[32m● $$version\033[0m  (active)"; \
				else \
					echo "  \033[90m○ $$version\033[0m"; \
				fi; \
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
	@echo "  make restore dump=client_prod.dump db=cliente_17_prod"
	@echo "  make clean-filestore db=cliente_17_prod"
	@echo "  make update modules=sale,account"
	@echo "  make test modules=sale,account"
	@echo "  make test-tags tags=/sale:TestSale.test_method"
	@echo "  make worktree-add VERSION=18.0"
	@echo "  make build"
	@echo ""
