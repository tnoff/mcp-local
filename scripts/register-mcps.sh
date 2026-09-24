#!/usr/bin/env bash
#
# Register every locally-run MCP with Claude Code via `claude mcp add`.
# Run by hand -- first-time setup on a new laptop, or any time you want
# every entry re-pointed at what's actually built/pulled right now.
# Idempotent: each entry is removed then re-added, safe to re-run.
#
# MUST run with Claude Code closed. It writes ~/.claude.json (via the
# `claude` CLI, not directly) -- the running app rewrites that file live and
# only reads it back in at startup, same reasoning as every wire-up in this
# repo (README.md).
#
# gitlab is deliberately absent -- retired, see README.md, do not register it.
#
# Credential files under ~/.mcp-local/<mcp>/ are NOT created here -- same as
# everywhere else in this repo, that's a manual, user-run step (an agent or
# script proposing a credential is not how any of these got set up). An MCP
# whose credential file doesn't exist yet is skipped, not registered broken.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_LOCAL_DIR="/home/tnorth/.mcp-local"

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI not found on PATH." >&2
  exit 1
fi

echo "== Ensuring images are built/current =="
"${REPO_ROOT}/scripts/sync-images.sh"

register() {
  local name="$1"
  shift
  echo
  echo "-- ${name} --"
  claude mcp remove "${name}" >/dev/null 2>&1 || true
  claude mcp add --scope user "${name}" -- "$@"
  echo "   registered"
}

skip() {
  local name="$1" reason="$2"
  echo
  echo "-- ${name} --"
  echo "   SKIPPED: ${reason}"
}

echo
echo "== Registering =="

if [ -f "${MCP_LOCAL_DIR}/grafana/.env" ]; then
  GRAFANA_REF="$(python3 -c "import json; print(json.load(open('${REPO_ROOT}/images.json'))['grafana'])")"
  register grafana docker run -i --rm --network host \
    --env-file "${MCP_LOCAL_DIR}/grafana/.env" \
    "${GRAFANA_REF}" -t stdio
else
  skip grafana "no ${MCP_LOCAL_DIR}/grafana/.env -- see README.md's Credentials for each MCP section"
fi

if [ -f "${MCP_LOCAL_DIR}/kubernetes/kubeconfig" ]; then
  register kubernetes docker run -i --rm --network host \
    -e HOME=/home/tnorth -e KUBECONFIG=/kube/kubeconfig \
    -v /home/tnorth/.oci:/home/tnorth/.oci:ro \
    -v "${MCP_LOCAL_DIR}/kubernetes:/kube:ro" \
    kubernetes-mcp-oci:local --read-only
else
  skip kubernetes "no ${MCP_LOCAL_DIR}/kubernetes/kubeconfig -- see README.md's Credentials for each MCP section"
fi

if [ -f "${MCP_LOCAL_DIR}/oci-mcp/config" ] && [ -f "${MCP_LOCAL_DIR}/oci-mcp/mcp_readonly_api_key.pem" ]; then
  register oci docker run -i --rm \
    -e HOME=/home/tnorth \
    -v "${MCP_LOCAL_DIR}/oci-mcp:/home/tnorth/.oci:ro" \
    oci-mcp:local --profile MCP_READONLY
else
  skip oci "no ${MCP_LOCAL_DIR}/oci-mcp/{config,mcp_readonly_api_key.pem} -- see README.md's Credentials for each MCP section"
fi

if [ -f "${MCP_LOCAL_DIR}/github/.env" ]; then
  GITHUB_REF="$(python3 -c "import json; print(json.load(open('${REPO_ROOT}/images.json'))['github'])")"
  register github docker run -i --rm \
    --env-file "${MCP_LOCAL_DIR}/github/.env" \
    "${GITHUB_REF}"
else
  skip github "no ${MCP_LOCAL_DIR}/github/.env -- see README.md's Credentials for each MCP section"
fi

if [ -f "${MCP_LOCAL_DIR}/backstage/.env" ]; then
  register backstage docker run -i --rm \
    --env-file "${MCP_LOCAL_DIR}/backstage/.env" \
    backstage-mcp-server:local
else
  skip backstage "no ${MCP_LOCAL_DIR}/backstage/.env -- see README.md's Credentials for each MCP section"
fi

echo
echo "Done. Restart Claude Code, then check /mcp for what connected."
