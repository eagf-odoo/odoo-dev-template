# AI Agent

An optional Claude Code container that can see the Odoo source code read-only and assist with
development and upgrade tasks, without access to the database, customer data, or internal network.

## Prerequisites

A [claude.ai](https://claude.ai) account with a **Pro or Max** subscription is required.
No Anthropic API key is needed — authentication is handled via OAuth login.

## Starting a session

```bash
make agent
```

On the first run the agent image is built automatically and you will be prompted to log in
with your claude.ai account. Subsequent runs start in seconds.

When you exit Claude (`/exit`), the container is removed automatically.

## What the agent can see

| Path in container | Contents | Mode |
|---|---|---|
| `/mnt/reference/odoo` | Odoo community source | development |
| `/mnt/reference/enterprise` | Odoo enterprise source | development |
| `/mnt/reference/design-themes` | Odoo design-themes source | development |
| `/mnt/reference/source/{odoo,enterprise,design-themes}` | Source version (FROM) | upgrade |
| `/mnt/reference/target/{odoo,enterprise,design-themes}` | Target version (TO) | upgrade |
| `/mnt/customer` | Customer modules | only if AGENT_CUSTOMER_ACCESS=true |
| `/workspace/output` | Writable staging area for generated code | both |

The agent has **no network route** to `web` (Odoo) or `db` (PostgreSQL). It can only reach
`api.anthropic.com` to process requests.

## Upgrade mode

In `ODOO_MODE=upgrade`, `make agent` automatically mounts both the source and target versions
of Odoo so the agent can compare APIs, models, and views across versions:

```
"How did account.move change between 17.0 and 18.0?"
"What's the equivalent of this deprecated API in the target version?"
"Help me write the migration script for this field."
```

## Customer code access (opt-in)

By default, the customer's module code is not mounted. To enable it, the client must contractually
approve the use of AI on their code (since it will be sent to Anthropic's API). Then set in `.env`:

```bash
AGENT_CUSTOMER_ACCESS=true
```

## Agent state persistence

The agent's claude.ai session and Claude Code state are stored in `~/.odoo-agent/` on the host.
This directory is shared across all client projects on the same machine — authentication carries
over automatically, so you only log in once per machine.

**What persists between sessions:** authentication, installed skills, Claude Code configuration.

**What does not persist:** conversation context. Each `make agent` invocation starts a fresh
conversation. To resume a previous one, use `/resume` inside Claude Code after starting.

The state directory is intentionally separate from `~/.claude/` to avoid interfering with
other Claude Code sessions on the host.

To reset the agent state completely (forces re-authentication on next run):

```bash
make reset-agent
```

## Custom CLAUDE.md location

By default the agent loads the system prompt from `~/Odoo/.claude-md/CLAUDE.md`.
If your `psmx-claude-md` clone lives elsewhere, set `CLAUDE_PATH` in `.env`:

```bash
CLAUDE_PATH=~/path/to/your/CLAUDE.md
```

## Rebuilding the agent image

If you modify `dockerfiles/agent.Dockerfile`, rebuild manually:

```bash
make build-agent
```
