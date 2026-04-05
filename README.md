# Odoo Dev Environment Template

Dockerized development environment for Odoo. Designed for custom module development, upgrades between versions, and client maintenance.

---

## Prerequisites

- Docker Desktop
- Git
- SSH access to GitHub configured
- Directory structure created by `setup.sh` (see below)

---

## First-time machine setup

Run `setup.sh` once on a new machine. It creates the `~/Odoo/` directory structure,
clones Odoo source repos as bare repositories, creates worktrees for the versions
you choose, and installs upgrade tools.

```bash
git clone git@github.com:eagf-odoo/odoo-dev-template.git template
cd template
setup.sh
```

The script is interactive and safe to re-run — it skips anything that already exists.

---

## Setup

**1. Clone this template for your client**

```bash
git clone git@github.com:eagf-odoo/odoo-dev-template.git ~/Odoo/Customers/acme
cd ~/Odoo/Customers/acme
```

**2. Configure the environment**

```bash
cp .env.example .env
```

Edit `.env` with the values for your client. Set `ODOO_MODE` to `maintenance`
or `upgrade`, fill in the corresponding version variables, and configure paths
and database name.

> **`ODOO_VAULT_PATH` must be an absolute path.** Use `$HOME/Odoo/.vault` or the
> equivalent — do not use `~`. Docker Compose expands tilde in the source (host)
> path but not in the target (container) path, so `source` and `target` would
> diverge and git worktree pointers would not resolve.

**3. Build the Docker image**

```bash
make build
```

**4. Initialize or restore a database**

For a fresh database:

```bash
make init
```

To restore from a dump file:

```bash
make restore dump=acme_prod.dump
```

**5. Start the environment**

```bash
make start
```

`make start` waits for Odoo to finish loading and prints a ready notice with the URL.
Odoo will be available at http://localhost:8069

---

## Further reading

- [REFERENCE.md](REFERENCE.md) — all commands, debugging, testing, worktree management, pgAdmin4
- [WORKFLOWS.md](WORKFLOWS.md) — practical step-by-step scenarios
