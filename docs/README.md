# mcp-local

Registry of every MCP server Claude Code runs locally on the laptop, all
five as `docker run -i --rm` stdio containers: Dockerfiles for the ones with
no upstream image, pinned image refs (`images.json`) for the ones pulled
as-is, and the scripts that build/pull and register them.

Nothing here is built or deployed by CI; a Renovate bump is the trigger to
rebuild by hand and restart Claude Code.

The repository [README](https://github.com/tnoff/mcp-local/blob/main/README.md)
covers contents, the sync/register scripts and per-MCP credentials. These
pages cover the wider picture:

- [Local MCP containers](local-mcp-containers.md) -- `~/.claude.json`
  wiring, the keepalive port-forwards, per-MCP setup and gotchas.
- [OCI MCP](oci-mcp.md) -- how `terraform-admin` provisions the read-only
  credential behind the `oci` MCP.
- [In-cluster MCPs (decommissioned)](cluster-mcp.md) -- historical record
  of the topology the local containers replaced.
