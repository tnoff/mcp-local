# Local OCI MCP server

How `terraform-admin` provisions the tenancy-wide read-only credential behind the
local OCI MCP (`jopsis/mcp-server-oci`). Build, credential layout and
registration are in the [README](https://github.com/tnoff/mcp-local/blob/main/README.md)
("Credentials for each MCP" and `scripts/register-mcps.sh`); how it fits with the
other MCPs is in [local-mcp-containers.md](local-mcp-containers.md).

The MCP needs no cluster access: it authenticates with an OCI API key straight
against OCI's public API, so there is no keepalive dependency.

## What `terraform-admin` provisions

Hand-rolled in `terraform-admin/main.tf` (verified against its `main`). Names come
from `variables.tf`:

- `oci_identity_user.mcp_readonly` and `oci_identity_group.mcp_readonly`, both
  named `mcp-readonly-bot`, plus `oci_identity_user_group_membership.mcp_readonly`
- `oci_identity_policy.mcp_readonly` (`mcp-readonly-policy`), a single statement:
  `Allow group mcp-readonly-bot to read all-resources in tenancy`
- `tls_private_key.mcp_readonly` (2048-bit RSA) and `oci_identity_api_key.mcp_readonly`
  (public half registered as the user's API signing key)
- `local_sensitive_file.mcp_readonly_private_key`: the private key at
  `generated-output/mcp_readonly_api_key.pem` (mode `0600`)
- `local_sensitive_file.mcp_readonly_oci_config`: an `~/.oci/config` fragment at
  `generated-output/mcp_readonly_oci_config`, profile `[MCP_READONLY]`, `key_file`
  set to the absolute path of the PEM above

The fragment uses a named profile (not `DEFAULT`) so it composes with an existing
`~/.oci/config`. The server is told which profile to use with
`--profile MCP_READONLY`. Rotation is
`terraform apply -replace=tls_private_key.mcp_readonly` (see the terraform-admin
secret-rotation page).

## Gotchas

- **Upstream's `mcp @ git+main` dependency can be unresolvable.** The package's
  pyproject pulls the MCP Python SDK from git `main` unpinned. That has broken in
  two ways: the SDK restructuring `mcp.server.fastmcp` (a `ModuleNotFoundError`),
  and upstream's HEAD demanding an unpublished dev snapshot of a sub-dependency so
  that pip could not resolve at all. The Dockerfile therefore installs the package
  `--no-deps` from a pinned commit and pins every real runtime dependency (`mcp`
  included) in `oci-mcp/requirements.txt`, so the build never depends on what
  upstream's git tip resolves to. Renovate tracks the commit pin through a
  `git-refs` customManager.
- **Broad read scope.** `read all-resources in tenancy` includes IAM metadata,
  audit logs and vault metadata (not secret contents). Narrower per-family
  policies would be tighter but much chattier to maintain; read-all is the
  deliberate trade-off.
- **Operator-scoped credential.** Each laptop needs the PEM and fragment from a
  local `terraform-admin` apply, copied into `~/.mcp-local/oci-mcp/` (a scoped
  copy, not pasted into the operator's own `~/.oci/config`). There is no shared
  cluster-side equivalent.
- **The PEM's original path may not be under `~/.oci/` at all** (it is wherever
  `mcp_readonly_private_key_path` pointed), so mounting `~/.oci` would not
  necessarily include it. Hence the scoped copy.
