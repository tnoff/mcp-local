# Local OCI MCP server

How `terraform-admin` provisions the tenancy-wide read-only credentials
that back the local OCI MCP server (`jopsis/mcp-server-oci`), and how
those credentials get wired into Claude Code. The credential-provisioning
half of this doc is still the source of truth; the client-side half
(how the server itself runs, how it's registered) moved to
[`mcp-local`](https://github.com/tnoff/mcp-local) on 2026-09-24 — see
below.

## TL;DR

- **terraform-admin** provisions an OCI IAM user (`mcp-readonly-bot`)
  with `read all-resources in tenancy`, generates a 2048-bit RSA
  signing key, and writes both the PEM and a ready-to-paste
  `~/.oci/config` fragment under `generated-output/`.
- **`mcp-local`'s `oci-mcp/Dockerfile`** builds `jopsis/mcp-server-oci`
  from a pinned commit — no more laptop-wide pip venv. Every real
  runtime dependency is pinned in `requirements.txt`, installed
  `--no-deps` from the package itself; see Gotchas for why that matters
  more than it sounds.
- **Credentials are a scoped copy**, not the operator's whole `~/.oci/`:
  `~/.mcp-local/oci-mcp/{config,mcp_readonly_api_key.pem}` holds only the
  `MCP_READONLY` profile. `mcp-local`'s README has the full reasoning and
  setup steps (a less-audited third-party package gets the narrower
  credential, not the `DEFAULT` profile the bastion keepalive uses).
- **Claude Code** registers it like the other four local MCPs, via
  `claude mcp add` (or `mcp-local/scripts/register-mcps.sh` for all five
  at once) — see [local-mcp-containers.md](local-mcp-containers.md).

## Why local

All five MCPs now run locally as Docker containers — see
[local-mcp-containers.md](local-mcp-containers.md). The OCI MCP was local from the start because:

- It auths via the operator's own `~/.oci/config` (the same file
  `terraform-admin` itself uses), so there's nothing the cluster has
  that the laptop doesn't.
- Putting it in-cluster would require yet another IAM user + secret
  + ServiceAccount, with no operational win.

## What `terraform-admin` provisions

Hand-rolled in `terraform-admin/main.tf` (no `iam-user` module — admin's
house style is raw resources). Defaults from `variables.tf`:

- `oci_identity_user.mcp_readonly` — name `mcp-readonly-bot`
- `oci_identity_group.mcp_readonly` — name `mcp-readonly-bot`
- `oci_identity_user_group_membership.mcp_readonly`
- `oci_identity_policy.mcp_readonly` — single statement,
  `Allow group mcp-readonly-bot to read all-resources in tenancy`
- `tls_private_key.mcp_readonly` — 2048-bit RSA
- `oci_identity_api_key.mcp_readonly` — public half registered as the
  user's API signing key
- `local_sensitive_file.mcp_readonly_private_key` — private half written
  to `generated-output/mcp_readonly_api_key.pem` (mode 0600)
- `local_sensitive_file.mcp_readonly_oci_config` — pre-formatted
  `~/.oci/config` fragment at `generated-output/mcp_readonly_oci_config`,
  profile name `[MCP_READONLY]`, `key_file` set to the absolute path of
  the PEM above

The fragment uses a named profile (not `DEFAULT`) so it composes with the
operator's existing `~/.oci/config` rather than overwriting it. The MCP
server is told which profile to use via `--profile MCP_READONLY` at
launch.

## Building, credentialing, and wiring it up

All three now live in `mcp-local`, not here:

- **Build**: `docker build -t oci-mcp:local oci-mcp/` (or
  `mcp-local/scripts/sync-images.sh`, which does this for all three
  locally-built images and `git pull`s first). `oci-mcp/Dockerfile` pins
  the upstream commit; Renovate tracks it via a `git-refs` customManager,
  same shape as the fleet's `terraform-modules` pin tracking.
- **Credentials**: copy `generated-output/mcp_readonly_api_key.pem` (from
  the `terraform-admin` apply above) and the `[MCP_READONLY]` fragment
  into `~/.mcp-local/oci-mcp/` — full steps in `mcp-local`'s README under
  "Credentials for each MCP".
- **Register**: `mcp-local/scripts/register-mcps.sh` (all five MCPs at
  once, idempotent) or by hand:

  ```bash
  claude mcp add --scope user oci -- docker run -i --rm \
    -e HOME=/home/tnorth \
    -v /home/tnorth/.mcp-local/oci-mcp:/home/tnorth/.oci:ro \
    oci-mcp:local --profile MCP_READONLY
  ```

  Run this (or the script) from a plain terminal with Claude Code closed
  — the running app rewrites `~/.claude.json` live and only reads
  `mcpServers` back in at startup. `-e HOME=/home/tnorth` is load-bearing:
  the image runs as root, whose default `$HOME` is `/root`, and
  `oci.config.from_file()` looks under `$HOME/.oci/config`.

## Gotchas worth knowing

- **`jopsis/mcp-server-oci` pyproject pulls `mcp @ git+main` unpinned —
  and that's not just occasionally stale, it can be flatly
  unresolvable.** The MCP Python SDK's main branch periodically
  restructures `mcp.server.fastmcp`; the venv-install era hit that as a
  `ModuleNotFoundError` (2026-06-09, `mcp 1.25.1.dev181+6d0c160`) and
  fixed it with a corrective `pip install --force-reinstall --no-deps`.
  Building the Dockerfile version hit a *harder* failure on 2026-09-21:
  pip couldn't even resolve the dependency, because upstream's git HEAD
  demanded an unpublished dev snapshot of a sub-dependency. The
  Dockerfile's fix is structural rather than corrective: install the
  package itself `--no-deps`, and pin every real runtime dependency
  (`mcp` included) in `requirements.txt` to a version confirmed to work,
  so the build never depends on what upstream's git tip currently
  resolves to.
- **Broad read-all scope** — `read all-resources in tenancy` includes
  IAM metadata, audit logs, and vault metadata (not secret contents).
  Scoped down to specific resource families would be tighter but also
  much chattier to maintain; the read-all policy is the deliberate
  trade-off.
- **The `MCP_READONLY` profile is operator-scoped.** Each laptop that
  wants the MCP needs `terraform-admin` re-applied locally. Unlike the
  venv era, the fragment and PEM go into a *scoped copy* at
  `~/.mcp-local/oci-mcp/`, not pasted into the operator's own
  `~/.oci/config` — see `mcp-local`'s README for why (short version: this
  MCP is backed by a less-audited third-party package, and the `DEFAULT`
  profile living in `~/.oci/` is much higher-privilege than
  `MCP_READONLY` needs). There's no shared cluster-side equivalent to
  either form.

---

## Verified against

| Project | SHA | Date |
|---|---|---|
| `terraform-admin` | `63ad554` | 2026-07-14 |
| `terraform-modules` | `f77e71e` | 2026-07-14 |
| `mcp-local` | `oci-mcp/Dockerfile` added 2026-09-21, credentials migrated 2026-09-24 | 2026-09-25 |

*Related: infra bootstrap (terraform-admin TechDocs) (the broader `terraform-admin` →
`terraform` handoff that `mcp-readonly-bot` lives alongside),
[local-mcp-containers.md](local-mcp-containers.md) (all five local MCPs, including this one).*
