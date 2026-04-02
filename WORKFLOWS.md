# Workflow Examples

Practical reference for the most common scenarios when working with this template.

---

## 1. Single client — full setup from scratch

```bash
# 1. Clone the template (maintenance branch)
git clone --branch maintenance git@github.com:eagf-odoo/odoo-dev-template.git ~/Odoo/Customers/acme
cd ~/Odoo/Customers/acme

# 2. Clone the client's module repository
git clone git@github.com:acme/acme-addons.git ~/Odoo/Repos/acme-addons

# 3. Configure the environment
cp .env.example .env
# Edit .env — set ODOO_VERSION, CUSTOMER_REPO, ODOO_DB_NAME, etc.

# 4. Get the Docker image (see section 5 or 6)

# 5. Place the database dump
cp ~/Downloads/acme_prod.dump ~/Odoo/Dumps/

# 6. Restore the database
make restore dump=acme_prod.dump

# Or initialize a fresh database instead:
# make init

# 7. Start the environment
make start
# → waits until Odoo is ready, then prints the URL

# 8. Open VS Code, reopen in container, then open the workspace
code .
# → Command Palette: "Dev Containers: Reopen in Container"
# → Open odoo-dev.code-workspace

# Odoo running at http://localhost:8069 — credentials: admin/admin
```

---

## 2. Two clients simultaneously

Each client needs its own clone of the template with different ports to avoid conflicts.

```bash
# --- Client A: Acme (ports 8069 / 5678) ---
git clone git@github.com:eagf-odoo/odoo-dev-template.git ~/Odoo/Customers/acme
cd ~/Odoo/Customers/acme
cp .env.example .env
# .env — set ODOO_PORT=8069, ODOO_DEBUG_PORT=5678
make start

# --- Client B: Globex (ports 8070 / 5679) ---
git clone git@github.com:eagf-odoo/odoo-dev-template.git ~/Odoo/Customers/globex
cd ~/Odoo/Customers/globex
cp .env.example .env
# .env — set ODOO_PORT=8070, ODOO_DEBUG_PORT=5679
make start
```

Open a separate VS Code window for each client:

```bash
code ~/Odoo/Customers/acme    # → Reopen in Container → workspace
code ~/Odoo/Customers/globex  # → Reopen in Container → workspace
```

Each window connects to its own container independently.

| Client | Odoo | Debugpy |
|--------|------|---------|
| Acme   | http://localhost:8069 | port 5678 |
| Globex | http://localhost:8070 | port 5679 |

---

## 3. Upgrading a module

Typical iteration loop during an upgrade — restore a clean database,
run the upgrade, inspect the result, repeat.

```bash
cd ~/Odoo/Customers/acme

# Restore a clean database before each attempt
make restore dump=acme_pre_upgrade.dump

# Upgrade one or more modules
make upgrade modules=acme_sale

# Upgrade multiple modules at once
make upgrade modules=acme_sale,acme_account,acme_stock

# Watch the logs while the upgrade runs
make logs

# If you need to inspect the database
make pgadmin
# → http://localhost:5050
```

To enable hot reload while fixing Python code between upgrades:

```bash
# In .env
ODOO_EXTRA_ARGS=--dev=all

make restart
```

---

## 4. Building the Docker image locally

Use this when the image is not available on DockerHub or you need to
test changes to the Dockerfile.

```bash
cd ~/Odoo/Customers/acme

# Builds odoo-dev:<ODOO_VERSION> from the worktree Dockerfile
make build
```

The image is built from `~/Odoo/Worktrees/<ODOO_VERSION>/Dockerfile`
and tagged as `odoo-dev:<version>` (e.g. `odoo-dev:17.0`).

To build for a specific version without changing your .env:

```bash
ODOO_VERSION=17.0 make build
```

---

## 5. Using a pre-built image from DockerHub

If the images are already published, skip `make build` entirely.

```bash
# Pull the image for the version you need
docker pull your-dockerhub-user/odoo-dev:18.0

# Tag it with the name the template expects
docker tag your-dockerhub-user/odoo-dev:18.0 odoo-dev:18.0

# Start the environment normally
make start
```


---

## Quick reference

| Scenario | Key .env values to set |
|---|---|
| Single client | Default ports (`8069`, `5678`) |
| Two clients | Different `ODOO_PORT` and `ODOO_DEBUG_PORT` per client |
| Maintenance / bugfix | `ODOO_VERSION` (this branch) |
| Hot reload | `ODOO_EXTRA_ARGS=--dev=all` |
| No debugger overhead | `ODOO_DEBUG=false` |
| Fresh database | `make init` then `make start` |
| Restore from dump | `make restore dump=file.dump` then `make start` |
