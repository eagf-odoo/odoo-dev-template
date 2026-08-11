#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"

ODOO_MODE="${ODOO_MODE:-development}"
COMPOSE_FILES=(-f docker-compose.yml -f "docker-compose.${ODOO_MODE}.yml")
[ -n "${EXTERNAL_DISK_PATH:-}" ] && COMPOSE_FILES+=(-f docker-compose.external.yml)

# --- Validate arguments ------------------------------------------------------
FILE="${1:-}"
TARGET_DB="${2:-${ODOO_DB_NAME}}"
SECONDARY_RESTORE=false
[ "$TARGET_DB" != "$ODOO_DB_NAME" ] && SECONDARY_RESTORE=true

if [ -z "$FILE" ]; then
    print_error "Usage: make restore dump=<filename>.zip|.dump|.sql [db=<dbname>]"
    exit 1
fi

if [[ "$FILE" != *.dump ]] && [[ "$FILE" != *.sql ]] && [[ "$FILE" != *.zip ]]; then
    print_error "Unsupported format '${FILE}'. Use a .dump, .sql, or .zip file."
    exit 1
fi

# --- Validate dump file (before touching the database) -----------------------
DUMPS_PATH="${DUMPS_PATH:-$HOME/Odoo/Dumps}"
HOST_FILE="$DUMPS_PATH/$(basename "$FILE")"

if [ ! -f "$HOST_FILE" ] || [ ! -r "$HOST_FILE" ]; then
    print_error "Dump file not found or not readable: ${HOST_FILE}"
    exit 1
fi

if [[ "$FILE" == *.zip ]]; then
    # Fail fast if zip doesn't contain dump.sql
    # Run in subshell with pipefail off — grep -q exits early causing SIGPIPE to unzip
    (set +o pipefail; unzip -l "$HOST_FILE" 2>/dev/null | grep -q "dump.sql") \
        || { print_error "No dump.sql found inside ${FILE}. Is it a valid Odoo backup?"; exit 1; }
fi

# --- Restore -----------------------------------------------------------------
if [ "$SECONDARY_RESTORE" = "false" ]; then
    run_with_spinner "Stopping Odoo web service..." \
        docker compose "${COMPOSE_FILES[@]}" stop web
fi

run_with_spinner "Starting database service..." \
    docker compose "${COMPOSE_FILES[@]}" up -d --wait db

run_with_spinner "Dropping existing database ($TARGET_DB)..." \
    docker compose "${COMPOSE_FILES[@]}" exec db dropdb -U odoo --if-exists --force "$TARGET_DB"

run_with_spinner "Creating fresh database ($TARGET_DB)..." \
    docker compose "${COMPOSE_FILES[@]}" exec db createdb -U odoo "$TARGET_DB"

if [[ "$FILE" == *.zip ]]; then
    WORK_DIR=$(mktemp -d "${EXTERNAL_DISK_PATH:-/tmp}/odoo-restore.XXXXXX")
    trap 'rm -rf "$WORK_DIR"' EXIT

    # Stream dump.sql directly into psql — no intermediate files on disk
    run_with_spinner "Restoring ${FILE}..." \
        bash -c "set -o pipefail; unzip -p \"$HOST_FILE\" dump.sql | \
            docker compose ${COMPOSE_FILES[*]} exec -T db \
                psql -U odoo -d \"$TARGET_DB\" -q" \
        || { print_error "Restore failed — check the dump file."; exit 1; }

    # Extract filestore only if present — dump.sql never hits disk
    FILESTORE_IN_ZIP=$(unzip -l "$HOST_FILE" | grep -c "filestore/" || true)
    if [ "$FILESTORE_IN_ZIP" -gt 0 ]; then
        run_with_spinner "Extracting filestore..." \
            unzip -q "$HOST_FILE" "filestore/*" -d "$WORK_DIR" 2>/dev/null || true
        FILESTORE_SRC="$WORK_DIR/filestore"
        if [ -d "$FILESTORE_SRC" ] && [ -n "$(ls -A "$FILESTORE_SRC" 2>/dev/null)" ]; then
            DATA_ROOT="${EXTERNAL_DISK_PATH:+${EXTERNAL_DISK_PATH}/.data}"
            DATA_ROOT="${DATA_ROOT:-$HOME/Odoo/.data}"
            TARGET="$DATA_ROOT/$TARGET_DB/filestore/$TARGET_DB"
            run_with_spinner "Installing filestore..." \
                bash -c "rm -rf \"$TARGET\" && mkdir -p \"$(dirname "$TARGET")\" && mv \"$FILESTORE_SRC\" \"$TARGET\""
            print_ok "Filestore installed."
        fi
    fi
elif [[ "$FILE" == *.dump ]]; then
    run_with_spinner "Restoring ${FILE}..." \
        docker compose "${COMPOSE_FILES[@]}" exec -T db \
            pg_restore -U odoo -d "$TARGET_DB" -1 "/$FILE" \
        || { print_error "Restore failed — check the dump file."; exit 1; }
else
    run_with_spinner "Restoring ${FILE}..." \
        docker compose "${COMPOSE_FILES[@]}" exec -T db \
            psql -U odoo -d "$TARGET_DB" -f "/$FILE" -q \
        || { print_error "Restore failed — check the dump file."; exit 1; }
fi

print_info "Resetting admin credentials (login: admin / password: admin)..."
SQL="WITH admin_candidates AS (
    SELECT id, 1 AS priority
    FROM res_users
    WHERE id IN (
        SELECT res_id FROM ir_model_data
        WHERE model = 'res.users' AND (module, name) = ('base', 'user_admin')
    )
    AND active = TRUE

    UNION

    SELECT id, 2 AS priority
    FROM res_users
    WHERE login = 'admin' AND active = TRUE

    UNION

    SELECT id, 3 AS priority
    FROM res_users
    WHERE id IN (
        SELECT uid FROM res_groups_users_rel
        WHERE gid IN (
            SELECT res_id FROM ir_model_data
            WHERE model = 'res.groups' AND (module, name) = ('base', 'group_system')
        )
    )
    AND active = TRUE
)
UPDATE res_users
SET login = 'admin', password = 'admin'
WHERE id = (
    SELECT id FROM admin_candidates
    ORDER BY priority ASC, id ASC
    LIMIT 1
);"
docker compose "${COMPOSE_FILES[@]}" exec -T db psql -U odoo -d "$TARGET_DB" -c "$SQL" -q >/dev/null

print_info "Disabling cron jobs/mail server and extending expiration date for local dev..."
DEV_SQL="UPDATE ir_cron SET active='f';
UPDATE ir_mail_server SET active='f';
UPDATE ir_config_parameter SET value = '2040-01-01 00:00:00' WHERE key = 'database.expiration_date';"
docker compose "${COMPOSE_FILES[@]}" exec -T db psql -U odoo -d "$TARGET_DB" -c "$DEV_SQL" -q >/dev/null

echo ""
if [ "$SECONDARY_RESTORE" = "false" ]; then
    print_info "Starting Odoo..."
    docker compose "${COMPOSE_FILES[@]}" start web >/dev/null 2>&1
    print_ok "Database restored — log in at http://localhost:${ODOO_PORT:-8069}"
else
    print_ok "Database '$TARGET_DB' restored — access via: make psql db=$TARGET_DB"
fi
echo ""
