#!/bin/bash

# Load environment variables from .env
if [ -f .env ]; then
  export $(cat .env | grep -v '#' | awk '/=/ {print $1}')
else
  echo "Error: .env file not found"
  exit 1
fi

FILE=$1

if [ -z "$FILE" ]; then
  echo "Usage: ./restore.sh dumps/<filename>.dump|.sql"
  exit 1
fi

echo "1. Stopping Odoo web service..."
docker compose stop web >/dev/null 2>&1

echo "2. Starting database service..."
docker compose up -d --wait db >/dev/null 2>&1

echo "3. Dropping existing database ($ODOO_DB_NAME)..."
docker compose exec db dropdb -U odoo --if-exists $ODOO_DB_NAME >/dev/null 2>&1

echo "4. Creating fresh database ($ODOO_DB_NAME)..."
docker compose exec db createdb -U odoo $ODOO_DB_NAME >/dev/null 2>&1

echo "5. Restoring $FILE..."

# Run restore in the background to show a progress spinner
if [[ $FILE == *.dump ]]; then
  docker compose exec db pg_restore -U odoo -d $ODOO_DB_NAME -1 /$FILE >/dev/null 2>&1 &
elif [[ $FILE == *.sql ]]; then
  docker compose exec db psql -U odoo -d $ODOO_DB_NAME -f /$FILE -q >/dev/null 2>&1 &
else
  echo "Error: unsupported format. Use a .dump or .sql file."
  exit 1
fi

# Spinner while restore runs
PID=$!
spin='-\|/'
i=0
while kill -0 $PID 2>/dev/null; do
  i=$(((i + 1) % 4))
  printf "\r   Restoring database... [${spin:$i:1}] "
  sleep 0.1
done

# Check restore exit code
wait $PID
if [ $? -ne 0 ]; then
  printf "\r   Restore failed. Please check the dump file.        \n"
  exit 1
fi

printf "\r   Database restored successfully.                    \n"

echo "6. Resetting admin credentials (login: admin / password: admin)..."
SQL_QUERY="WITH admin_info AS(SELECT res_id AS id FROM ir_model_data WHERE name = 'user_admin' AND module = 'base') UPDATE res_users ru SET password='admin', login='admin' FROM admin_info i WHERE ru.id=i.id;"
docker compose exec db psql -U odoo -d $ODOO_DB_NAME -c "$SQL_QUERY" -q >/dev/null 2>&1

echo "7. Starting Odoo..."
docker compose start web >/dev/null 2>&1

echo "Done. Database is ready — log in at http://localhost:${ODOO_PORT:-8069}"
