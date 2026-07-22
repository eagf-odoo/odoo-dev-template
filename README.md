# Odoo Dev Environment Template

Dockerized development environment for Odoo. Designed for custom module development, upgrades between versions, and client maintenance.

> Throughout this document, `acme` is used as a placeholder company name in examples.
> Replace it with the actual client name in every command.

---

## Prerequisites

- Docker Desktop
- Git
- SSH access to GitHub configured
- Directory structure created by `setup.sh` (see below)

### Docker Desktop resource settings (Mac)

Go to Settings → Resources and apply:
- Memory: 10 GB
- CPUs: 4
- Swap: 2 GB

---

## First-time machine setup

Run `setup.sh` once on a new machine. It creates the `~/Odoo/` directory structure,
clones Odoo source repos as bare repositories, creates worktrees for the versions
you choose, and installs upgrade tools.

```bash
git clone git@github.com:eagf-odoo/odoo-dev-template.git template
cd template
./setup.sh
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

Edit `.env` with the values for your client. Set `ODOO_MODE` to `development`
or `upgrade`, fill in the corresponding version variables, and configure paths
and database name.

> **Finish editing before starting.** If `make start` runs while `ODOO_DB_NAME`
> is still the literal placeholder from `.env.example`, Odoo will auto-create
> a database and filestore with that placeholder name instead of your
> client's. Make sure `.env` is fully filled in before step 5.

**3. Build the Docker image**

```bash
make build
```

> Skip this step if `odoo-dev:<version>` was already built on this machine
> (e.g. another client uses the same Odoo version).

**4. Restore a database** *(optional)*

```bash
make restore dump=acme_prod.zip
```

> Accepts `.zip` (Odoo backup with filestore), `.dump`, or `.sql`.
> Skip this step to start with a fresh empty database — Odoo creates it
> automatically on first `make start`.

**5. Start the environment**

```bash
make start
```

`make start` launches the stack in the background and prints the URL once the containers
are up. Run `make logs` in a separate terminal to follow the Odoo startup.
Odoo will be available at <http://localhost:8069>

---

## Further reading

- [REFERENCE.md](REFERENCE.md) — all commands, debugging, testing, worktree management, pgAdmin4
- [WORKFLOWS.md](WORKFLOWS.md) — practical step-by-step scenarios
