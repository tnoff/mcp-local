# mcp-local

Registry of every MCP server Claude Code runs locally on the laptop, all five as
`docker run -i --rm` stdio containers: Dockerfiles for the ones with no upstream
image, pinned image refs (`images.json`) for the ones pulled as-is, and the
scripts that build/pull and register them. Nothing here is built or deployed by
CI; a Renovate bump is the trigger to rebuild by hand and restart Claude Code.

The repository [README](https://github.com/tnoff/mcp-local/blob/main/README.md)
is the quick-start: contents, the sync/register scripts and per-MCP credential
files. These pages are the reference:

- [Local MCP containers](local-mcp-containers.md): how the five are wired, the
  keepalive port-forwards they ride on, and per-MCP gotchas.
- [OCI MCP](oci-mcp.md): how `terraform-admin` provisions the read-only
  credential behind the `oci` MCP.
