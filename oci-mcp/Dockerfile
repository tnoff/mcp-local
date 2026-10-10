# Upstream (github.com/jopsis/mcp-server-oci) ships no Dockerfile or
# published image and cuts no releases, so this builds it from source at a
# pinned commit -- same shape as backstage-mcp-server/Dockerfile, tracked by
# the same kind of git-refs customManager in renovate.json.
#
# --no-deps on the package itself, deliberately: its pyproject pulls
# `mcp @ git+main` unpinned, and that isn't just occasionally stale, it can
# be flatly unresolvable -- verified 2026-09-21, pip couldn't find a
# distribution for the dev snapshot it demanded. requirements.txt pins every
# real dependency (mcp included) to a version confirmed to work, so the
# build never depends on what upstream's git HEAD currently resolves to.
FROM python:3.14-slim
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
ARG MCP_SERVER_OCI_REF=3d4dbfd78f1e6a8061ae7e20d061832eb46f3cc5
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir --no-deps "git+https://github.com/jopsis/mcp-server-oci.git@${MCP_SERVER_OCI_REF}"
# Upstream still imports mcp.server.fastmcp, which mcp 2.x renamed to
# mcp.server.mcpserver (MCPServer, same Context/tool/run API for what it uses).
# Patch the one import line so we can track current mcp. The grep fails the
# build if upstream changes that line, so the patch can't silently no-op.
RUN f=/usr/local/lib/python3.14/site-packages/mcp_server_oci/mcp_server.py \
    && sed -i 's/^from mcp\.server\.fastmcp import FastMCP, Context$/from mcp.server.mcpserver import MCPServer as FastMCP, Context/' "$f" \
    && grep -q "mcp.server.mcpserver" "$f"
ENTRYPOINT ["mcp-server-oci"]
