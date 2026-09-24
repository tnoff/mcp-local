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
ARG MCP_SERVER_OCI_REF=1b5e055ad30882838c7923e1be17019fd3355e3e
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir --no-deps "git+https://github.com/jopsis/mcp-server-oci.git@${MCP_SERVER_OCI_REF}"
ENTRYPOINT ["mcp-server-oci"]
