#!/usr/bin/env bash
#
# Stop the MCP containers belonging to Claude Code sessions that are gone or
# suspended. Dry run by default; pass --kill to actually stop them.
#
# Each Claude Code session launches its own `docker run -i --rm ...` per MCP
# server (see docs/local-mcp-containers.md). The docker CLI client for each
# one is a child of that session's `claude` process, so a container is stale
# when its client's parent is:
#
#   - suspended (state T, e.g. Ctrl-Z and forgotten) -- the session is alive
#     but idle, and its five containers keep running; or
#   - not a `claude` process any more (client got reparented to init).
#
# Stopping works by sending SIGTERM to the docker client, which proxies it to
# the container; --rm then removes the container. A suspended client can't
# receive signals, so it gets SIGCONT first.
#
# Killing a suspended session's containers leaves that session without its
# MCP servers if you later `fg` it -- restart it instead.
set -euo pipefail

KILL=0
[[ "${1:-}" == "--kill" ]] && KILL=1

# Matches the five servers registered by README.md.
IMAGE_RE='kubernetes-mcp-oci|oci-mcp:local|github-mcp-server|backstage-mcp-server|mcp-grafana'

found=0
while read -r pid ppid _ args; do
  [[ "${args}" =~ ^docker\ run\ -i\ --rm ]] || continue
  [[ "${args}" =~ ${IMAGE_RE} ]] || continue

  parent_comm="$(ps -o comm= -p "${ppid}" 2>/dev/null || true)"
  parent_stat="$(ps -o stat= -p "${ppid}" 2>/dev/null || true)"

  if [[ "${parent_comm}" != "claude" ]]; then
    reason="parent is '${parent_comm:-gone}', not claude"
  elif [[ "${parent_stat}" == T* ]]; then
    reason="session ${ppid} is suspended"
  else
    continue
  fi

  found=1
  image="$(grep -oE "${IMAGE_RE}" <<<"${args}" | head -1)"
  if (( KILL )); then
    echo "stopping ${image} (client pid ${pid}): ${reason}"
    kill -CONT "${pid}" 2>/dev/null || true
    kill -TERM "${pid}" 2>/dev/null || true
  else
    echo "would stop ${image} (client pid ${pid}): ${reason}"
  fi
done < <(ps -eo pid=,ppid=,stat=,args=)

if (( ! found )); then
  echo "No containers belonging to closed or suspended sessions."
elif (( ! KILL )); then
  echo
  echo "Dry run. Re-run with --kill to stop them."
fi
