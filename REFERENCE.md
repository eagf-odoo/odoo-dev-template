# Reference

Complete reference for all commands and features of the Odoo Dev Environment Template.

For practical step-by-step scenarios (upgrade loop, two clients simultaneously, etc.)
see [WORKFLOWS.md](WORKFLOWS.md).

---

## Available commands

```
make start                               Start the environment and wait until Odoo is ready
make stop                                Stop the environment (including pgAdmin if running)
make restart                             Restart the Odoo server (keeps the database running)
make restart-all                         Restart the entire stack (Odoo + database)
make logs                                Stream Odoo server logs
make shell                               Open a shell inside the Odoo container
make ps                                  Show container status
make build                               Build the Docker image for ODOO_VERSION
make init                                Initialize a fresh database with the base module
make restore dump=file.dump              Restore a database from ~/Odoo/Dumps/
make upgrade modules=mod1,mod2           Upgrade Odoo modules
make test modules=mod1,mod2              Upgrade modules and run their tests
make test-tags tags=/mod:Class.method    Run tests matching a tag, class or method
make test-file file=/path/to/test.py     Run tests from a specific file
make pgadmin                             Start pgAdmin4 at http://localhost:5050
make list-worktrees                      List available worktrees (active one highlighted)
make fetch-all                           Fetch latest refs for all vault repos
make destroy                             Remove all containers, networks and volumes (deletes the database)
```

---

## Initial setup

Run `setup.sh` once per machine to create the directory structure, clone the vault
repositories, and create the initial worktrees.

```bash
bash setup.sh
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
git -C ~/Odoo/.vault/odoo.git config remote.origin.fetch "+refs/heads/*:refs/heads/*"

# 4. Fetch only what's missing
git -C ~/Odoo/.vault/odoo.git fetch --all --prune
```

> **Disk space:** The donor approach has the same final footprint as a direct
> `--bare` clone from GitHub. Donors can be safely deleted once `setup.sh` finishes —
> the script will offer to do this automatically.

> **Common mistake:** Do not configure the fetch refspec as
> `+refs/heads/*:refs/remotes/origin/*` (the non-bare convention). This creates two
> conflicting sets of refs — branches from the donor land in `refs/heads/*` while
> GitHub fetches land in `refs/remotes/origin/*`, causing worktrees to silently use
> stale data.

---

## Managing worktrees

Use `worktree.sh` to add or remove Odoo source worktrees after the initial setup.
This is the recommended way to add new versions — including `saas-*` branches —
without re-running the full `setup.sh`.

**Interactive mode**

```bash
bash worktree.sh
```

Presents a menu to add or remove a worktree.

**Non-interactive mode**

```bash
bash worktree.sh add 18.0
bash worktree.sh add saas-18.4
bash worktree.sh remove 17.0
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

> **Debugger not working? `Cannot activate 'Python Debugger'` error?**
> Open the Command Palette (`Cmd+Shift+P`) and run `Developer: Reload Window`.
> This reinitializes the extension host and resolves the activation order issue
> between the Python and Debugpy extensions.

> **Running multiple clients simultaneously?**
> Change `ODOO_PORT` and `ODOO_DEBUG_PORT` in each client's `.env` to avoid
> port conflicts (e.g. `8069`/`5678` for one, `8070`/`5679` for another).
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

| Command | Flag | When to use |
|---|---|---|
| `make test` | `--test-enable` | Upgrade a module and run all its tests |
| `make test-tags` | `--test-tags` (self-enabling) | Target a specific tag, class or method |
| `make test-file` | `--test-file` | Run all tests in a specific Python file |

**Examples**

```bash
# Upgrade and run all tests for a module
make test modules=acme_sale

# Run a specific test class
make test-tags tags=/acme_sale:TestSaleOrder

# Run a single test method
make test-tags tags=/acme_sale:TestSaleOrder.test_create

# Run all tests in a file
make test-file file=/mnt/extra-addons/acme_sale/tests/test_sale_order.py
```

> `--test-file` is available from Odoo 15 onwards.

---

## pgAdmin4

pgAdmin4 is included as an optional service for database inspection. It is not
started by default — only when explicitly requested.

```bash
make pgadmin
# → http://localhost:5050  (admin@admin.com / admin)
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

### `maintenance` (default)

Single Odoo version mounted read-only at `/mnt/reference`. Use this for custom
module development and bugfixes on a running production version.

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

## Database initialization

Use `make init` to create a fresh database. This drops any existing database,
creates a new one, and installs the `base` module with `--stop-after-init`.
Run `make start` afterwards to launch Odoo normally.

Use `make restore dump=file.dump` to restore from an existing dump instead.
Do not put `-i base` in `ODOO_EXTRA_ARGS` — it would reinstall the base module
on every startup. `ODOO_EXTRA_ARGS` is reserved for arguments that apply on
every run (e.g. `--dev=all`).
