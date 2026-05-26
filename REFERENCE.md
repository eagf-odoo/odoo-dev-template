# Reference

Complete reference for all commands and features of the Odoo Dev Environment Template.

For practical step-by-step scenarios (upgrade loop, two clients simultaneously, etc.)
see [WORKFLOWS.md](WORKFLOWS.md).

> Throughout this document, `acme` is used as a placeholder company name in examples.
> Replace it with the actual client name in every command.

> **Note on wkhtmltopdf:** Odoo's Docker images ship wkhtmltopdf pre-configured at
> the exact version each release requires. On macOS natively, the common workaround
> is to render reports via Odoo's `/report/html/` route, which produces inconsistent
> results. Inside the container, wkhtmltopdf runs natively on Linux and renders PDFs
> directly — matching the behavior of a production server.

---

## Available commands

```
make start                                          Start the environment
make stop                                           Stop the environment (including pgAdmin if running)
make restart                                        Restart the Odoo server (keeps the database running)
make restart-all                                    Restart the entire stack (Odoo + database)
make logs                                           Stream Odoo server logs
make shell [script=path/to/script.py]               Open an Odoo ORM shell, or run a script non-interactively
make psql [db=other_name]                           Open a psql shell (default: active database)
make extract src=<path> [dest=.]                    Extract a file from the db container to the host
make ps                                             Show container status
make build                                          Build the Docker image for ODOO_VERSION
make build-agent                                    Build the AI agent Docker image
make reset [demo=true]                              Reset the database: drop, recreate, and install base module
make restore dump=<file> [db=<name>]                Restore a database from ~/Odoo/Dumps/ (.zip, .dump, or .sql)
make update modules=mod1,mod2                       Update Odoo modules
make test modules=mod1,mod2 [demo=true]             Update modules and run Odoo test suite.
make test-tags tags=/mod:Class.method [demo=true]   Run tests matching a tag, class or method
make test-file file=/path/to/test.py [demo=true]    Run tests from a specific file
make pgadmin                                        Start pgAdmin4 at http://localhost:${PGADMIN_PORT:-5050}
make agent                                          Start the AI agent and open a Claude Code session
make list                                           List all client environments and their running status
make list-worktrees                                 List available worktrees (active one highlighted)
make worktree                                       Open the interactive worktree manager
make worktree-add VERSION=19.0                      Add a worktree for the given version
make worktree-remove VERSION=17.0                   Remove a worktree for the given version
make pull-all                                       Update all worktrees to the latest commit on their origin branch
make destroy                                        Remove all containers, networks and volumes (deletes the database)
```

---

## Initial setup

Run `setup.sh` once per machine to create the directory structure, clone the vault
repositories, and create the initial worktrees.

```bash
./setup.sh
```

The script is safe to re-run — existing directories and repos are skipped.

### Using local donors to speed up vault cloning

Cloning bare repos from GitHub can take a long time (~13 GB for `odoo` alone).
If you already have a regular clone of a repo on your machine, you can use it as
a **donor** — `setup.sh` will create the bare repo locally using hardlinks (instant,
no network) and then only fetch the delta from GitHub.

When the script reaches the vault cloning step, answer `y` to the donor prompt and
provide the path to each existing clone. Leave a field empty to download that repo
from GitHub normally.

**What happens under the hood:**

```bash
# 1. Clone bare from donor using hardlinks (instant)
git clone --bare --local ~/odoo-donor ~/Odoo/.vault/odoo.git

# 2. Point the remote to GitHub
git -C ~/Odoo/.vault/odoo.git remote set-url origin git@github.com:odoo/odoo.git

# 3. Set the correct bare-repo fetch refspec
git -C ~/Odoo/.vault/odoo.git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"

# 4. Fetch only what's missing
git -C ~/Odoo/.vault/odoo.git fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune
```

> **Disk space:** The donor approach has the same final footprint as a direct
> `--bare` clone from GitHub. Donors can be safely deleted once `setup.sh` finishes —
> the script will offer to do this automatically.

> **Common mistake:** Do not configure the fetch refspec as
> `+refs/heads/*:refs/heads/*`. When a branch is checked out in a worktree (e.g.
> `18.0`), Git refuses to fetch into it — even when you are creating a completely
> different version. Always use `refs/remotes/origin/*` as the destination so fetched
> refs never conflict with checked-out worktrees.

---

## Managing worktrees

Use `make worktree-add` / `make worktree-remove` to add or remove Odoo source
worktrees after the initial setup. This is the recommended way to add new versions —
including `saas-*` branches — without re-running `setup.sh`.

```bash
make worktree-add VERSION=19.0
make worktree-add VERSION=saas-18.4
make worktree-remove VERSION=17.0
make worktree                        # interactive menu
```

The script fetches the latest refs from the vault before creating a worktree, copies
the appropriate Dockerfile based on the major version number (`legacy` / Python 3.10
for < 18.0, including `saas-16.*` and `saas-17.*`; `modern` / Python 3.12 for ≥ 18.0
and `saas-18.*` and above), and registers the worktree removal cleanly with git when
deleting.

> **Important:** The `.vault/` directory must always be located at `~/Odoo/.vault`.
> This path is mounted into the container at its exact host location so that git worktree
> pointers resolve correctly inside the container — required for GitLens to show
> blame and history on Odoo source files.

---

## Debugging

The environment runs `debugpy` on port `5678`. To attach the debugger:

**1. Open the project folder in VS Code**

```bash
code ~/Odoo/Customers/acme
```

**2. Reopen in container**

When prompted by the Dev Containers extension, click **Reopen in Container**.
If the prompt does not appear, open the Command Palette (`Cmd+Shift+P`) and run:
`Dev Containers: Reopen in Container`

This connects VS Code to the running Odoo container. All workspace paths
(`/mnt/reference`, `/mnt/extra-addons`) resolve from inside the container —
the workspace file will not work without this step.

**3. Open the workspace file**

Once inside the container, open `odoo-dev.code-workspace` to load all folders.
Then use the **Docker: Odoo Debug** launch configuration to attach the debugger.

> **Debugger not working on first try?**
> VS Code needs a moment to finish activating extensions after attaching to the
> container. Wait until the status bar stops spinning and the Python interpreter
> is shown in the bottom-right corner, then try the debugger again.

> **Running multiple clients simultaneously?**
> Change `ODOO_PORT`, `ODOO_DEBUG_PORT`, and `PGADMIN_PORT` in each client's
> `.env` to avoid port conflicts (e.g. `8069`/`5678`/`5050` for one,
> `8070`/`5679`/`5051` for another).
> Each VS Code window connects to its own container independently.

---

## Hot reload

To enable hot reload during development, add `--dev=all` to `ODOO_EXTRA_ARGS` in your `.env`:

```
ODOO_EXTRA_ARGS=--dev=all
```

---

## Testing

Three commands are available depending on the level of granularity needed:

| Command          | Flag                          | When to use                             |
| ---------------- | ----------------------------- | --------------------------------------- |
| `make test`      | `--test-enable`               | Upgrade a module and run all tests      |
| `make test-tags` | `--test-tags` (self-enabling) | Target a specific tag, class or method  |
| `make test-file` | `--test-file`                 | Run all tests in a specific Python file |

All three commands accept an optional `demo=true` parameter to load demo data
during the test run. By default demo data is disabled (consistent across Odoo
17, 18, and 19 — see note below).

**Examples**

```bash
# Upgrade and run all tests for a module
make test modules=acme_sale

# Same, but with demo data loaded
make test modules=acme_sale demo=true

# Run a specific test class
make test-tags tags=/acme_sale:TestSaleOrder

# Run a single test method
make test-tags tags=/acme_sale:TestSaleOrder.test_create

# Run all tests in a file
make test-file file=/mnt/extra-addons/acme_sale/tests/test_sale_order.py
```

> `--test-file` is available from Odoo 15 onwards.

> **Demo data and Odoo versions**: Odoo 17 and 18 load demo data by default;
> Odoo 19 changed the default to off. The `demo=true` parameter abstracts this
> difference — it passes `--with-demo` on Odoo 19 and omits the flag on 17/18
> where demo is already the default. Omitting `demo=true` always results in no
> demo data regardless of version.

---

## ORM Shell / psql

Two ways to interact directly with the running environment without a GUI.

### `make shell` — Odoo ORM shell

Opens a Python REPL with the Odoo `env` variable pre-loaded and connected to
the active database. Changes run inside a transaction that is rolled back on
exit — use `env.cr.commit()` to persist them.

```bash
# Interactive REPL
make shell

# Run a script non-interactively and exit
make shell script=fix_mega_menu.py
```

When `script=` is provided, the file is piped to the shell process via stdin
(equivalent to `odoo-bin shell -d <db> < script.py`). The script runs in the
same environment as the interactive shell — `env`, `self`, and `env.cr` are
all available.

```python
# Example: add an exclamation mark to all partner names
records = env["res.partner"].search([])
for partner in records:
    partner.name = "%s !" % partner.name
env.cr.commit()
```

### `make psql` — PostgreSQL shell

Opens a `psql` session directly against the active database. Useful for raw
SQL queries, schema inspection, or debugging without launching pgAdmin.

```bash
# Connect to the active database (ODOO_DB_NAME)
make psql

# Connect to a specific database — e.g. a secondary restore
make psql db=acme_17_prod
```

```sql
-- Example: check the number of partners
SELECT COUNT(*) FROM res_partner;
```

The optional `db=` parameter connects to any database in the same PostgreSQL
instance without changing `.env`. From inside a psql session you can also
switch with `\c <dbname>`.

### `make extract` — extract files from the db container

The `db` container has no writable bind mounts to the host. Use `make extract`
to copy files generated inside the container — via `\o` or `COPY TO FILE` —
to your machine.

```bash
# Extract to current directory
make extract src=/tmp/output.txt

# Extract to a specific path
make extract src=/tmp/partners.csv dest=~/Odoo/Dumps
```

**Common workflow:**

```sql
-- Inside psql: export query results to CSV
COPY (SELECT * FROM res_partner WHERE active = true)
TO '/tmp/partners.csv' WITH CSV HEADER;

-- Or redirect output of any query
\o /tmp/output.txt
SELECT id, name, email FROM res_partner LIMIT 100;
\o
```

```bash
-- Then extract to your machine
make extract src=/tmp/partners.csv dest=~/Odoo/Dumps
```

---

## pgAdmin4

pgAdmin4 is included as an optional service for database inspection. It is not
started by default — only when explicitly requested.

```bash
make pgadmin
# → http://localhost:${PGADMIN_PORT:-5050}  (admin@admin.com / admin)
```

### When to use it during an upgrade

**Comparing schemas between versions**

- Before and after an upgrade, inspect the real database schema — column types,
  constraints, indexes — and verify that the migration scripts transformed the
  data correctly.

**Debugging SQL errors**

- When a migration fails with a PostgreSQL error, pgAdmin lets you run raw SQL
  queries against the database to reproduce and diagnose the problem without
  restarting the full upgrade process.

**Analyzing performance issues**

- If Odoo is slow after an upgrade, use the query analysis tools to identify
  missing indexes or inefficient queries introduced by the new version.

**Inspecting data after a restore**

- After `make restore`, quickly verify that the dump was restored correctly —
  row counts, field values, related records — before starting the upgrade iteration.

---

## Operating mode

The environment supports two modes, controlled by `ODOO_MODE` in your `.env`:

### `development` (default)

Single Odoo version mounted read-only at `/mnt/reference`. Use this for custom
module development, new module creation, and bugfixes on a running production version.

Required `.env` variables: `ODOO_VERSION`

### `upgrade`

Two versions mounted simultaneously. Use this when migrating custom modules
between Odoo versions.

- **Target** (`/opt/odoo-src`) — the version being upgraded to (runs Odoo)
- **Source** (`/mnt/reference`) — the version being upgraded from, read-only

Required `.env` variables: `ODOO_SOURCE_VERSION`, `ODOO_TARGET_VERSION`

### Switching modes

Change `ODOO_MODE` in your `.env` and restart:

```bash
# In .env
ODOO_MODE=upgrade

make restart-all
```

## Database reset

Use `make reset` to reset the database. This drops any existing database,
creates a new one, and installs the `base` module with `--stop-after-init`.
Run `make start` afterwards to launch Odoo normally.

```bash
# Reset without demo data (default)
make reset

# Reset with demo data
make reset demo=true
```

Use `make restore dump=backup.zip` to restore from an existing dump instead.
Do not put `-i base` in `ODOO_EXTRA_ARGS` — it would reinstall the base module
on every startup. `ODOO_EXTRA_ARGS` is reserved for arguments that apply on
every run (e.g. `--dev=all`).

---

## Troubleshooting

### `make start` says the image does not exist but it does

`make start` looks for an image named exactly `odoo-dev:<version>`. Two things can cause this error even when the image appears to be present.

**The image has a different name or tag**

The Makefile only accepts `odoo-dev:<version>`. If you built or pulled the image under a different name, tag it:

```bash
docker tag <your-image> odoo-dev:19.0
```

**The image was built under a different Docker context**

Docker Desktop on Mac runs two contexts (`default` and `desktop-linux`) backed by different Unix sockets. An image built in one context may not be visible to the other due to a known Docker Desktop inconsistency with `docker image inspect`.

`make start` now detects this automatically. If the image exists in another context, the error message will tell you exactly which one and offer two options:

```
Found in context 'default' but active context is 'desktop-linux'.
Option 1: switch context →  docker context use default
Option 2: rebuild here   →  make build
```

Option 1 is instant. Option 2 rebuilds the image in the current context (preferred if you want to stay on `desktop-linux`).

---

## AI Agent

An optional Claude Code container that can see the Odoo source code read-only and assist with
development and upgrade tasks, without access to the database, customer data, or internal network.

### Prerequisites

1. Build the agent image (once per machine):

```bash
make build-agent
```

2. Add your Anthropic API key to `.env`:

```bash
ANTHROPIC_API_KEY=sk-ant-...
```

### Starting a session

```bash
make agent
```

This starts the agent container (if not already running) and opens a Claude Code session directly
in your terminal. When you exit Claude, the container keeps running in the background.

### What the agent can see

| Path in container | Contents | Mode |
|---|---|---|
| `/mnt/reference/odoo` | Odoo community source | development |
| `/mnt/reference/enterprise` | Odoo enterprise source | development |
| `/mnt/reference/design-themes` | Odoo design-themes source | development |
| `/mnt/reference/source/{odoo,enterprise,design-themes}` | Source version (FROM) | upgrade |
| `/mnt/reference/target/{odoo,enterprise,design-themes}` | Target version (TO) | upgrade |
| `/mnt/customer` | Customer modules | only if AGENT_CUSTOMER_ACCESS=true |

The agent has **no network route** to `web` (Odoo) or `db` (PostgreSQL). It can only reach
`api.anthropic.com` to process requests.

### Upgrade mode

In `ODOO_MODE=upgrade`, `make agent` automatically mounts both the source and target versions
of Odoo so the agent can compare APIs, models, and views across versions:

```
"How did account.move change between 17.0 and 18.0?"
"What's the equivalent of this deprecated API in the target version?"
"Help me write the migration script for this field."
```

### Customer code access (opt-in)

By default, the customer's module code is not mounted. To enable it, the client must contractually
approve the use of AI on their code (since it will be sent to Anthropic's API). Then set in `.env`:

```bash
AGENT_CUSTOMER_ACCESS=true
```

### Agent state persistence

The agent's skills, memory, and MCP configuration are stored in the `odoo-agent-data` Docker volume.
This volume is isolated from `~/.claude/` on the host — the agent starts fresh on a new machine and
persists its state between sessions on the same machine.

---

## Migrating from a previous version

### Orphaned `odoo-web-data` volume

Earlier versions of this template stored Odoo's data (filestore, sessions) in a
named Docker volume called `odoo-web-data`. That volume has been replaced by a
bind mount at `~/Odoo/.data/<ODOO_DB_NAME>`.

If you set up the template before this change, the old volume is still present on
your machine but is no longer used. It will not be removed automatically by
`make destroy`. To clean it up:

```bash
# Find the volume (prefix matches your COMPOSE_PROJECT_NAME)
docker volume ls | grep odoo-web-data

# Remove it
docker volume rm <project>_odoo-web-data
```

Your data is not lost — it is still inside that volume. If you need to recover
anything from it, mount it temporarily to inspect it before deleting.
