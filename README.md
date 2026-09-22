# mcp-local

Registry of every MCP server Claude Code runs locally on the laptop — four
as `docker run -i --rm` stdio containers, one (`oci`) as a Python venv.
Companion to
[`docs/interactions/local-mcp-containers.md`](https://github.com/tnoff/docs/blob/main/interactions/local-mcp-containers.md)
and
[`docs/interactions/oci-mcp.md`](https://github.com/tnoff/docs/blob/main/interactions/oci-mcp.md),
which cover the full picture: `~/.claude.json` wiring, credentials under
`~/.mcp-local/<mcp>/`, the OCI bastion keepalive port-forwards, and the
per-MCP gotchas. This repo exists so version drift across all of them is
tracked in one place by Renovate, instead of living only in those docs'
prose and in `~/.claude.json` comments.

**Nothing here is built or deployed by CI.** Everything runs on the laptop;
a Renovate PR landing a bump is the trigger to rebuild/reinstall by hand and
restart Claude Code, not an automated rollout.

## Contents

| Path | What |
|---|---|
| `kubernetes-mcp-oci/Dockerfile` | `kubernetes-mcp-oci:local` — wraps `kubernetes-mcp-server` with the OCI CLI so its exec-plugin can mint OKE tokens. Both bases pinned to `:latest`; neither upstream publishes releases Renovate can track a tag bump against. |
| `backstage-mcp-server/Dockerfile` | `backstage-mcp-server:local` — builds [Coderrob/backstage-mcp-server](https://github.com/Coderrob/backstage-mcp-server) from source at a pinned commit (no upstream image exists). Renovate tracks the pin via a `git-refs` customManager. |
| `images.json` | Pinned public images with no local build: `github-mcp-server`, `mcp-grafana`. Not `gitlab-mcp` — that MCP is retired (see the docs page), and the entry is deliberately absent so Renovate never proposes reviving it. |
| `oci-mcp/requirements.txt` | Not a Docker image — `~/.envs/oci-mcp/` is a Python venv running [jopsis/mcp-server-oci](https://github.com/jopsis/mcp-server-oci) installed unpinned from git. This tracks the one real pin that setup needs: `mcp`, corrective-installed after, since jopsis's own unpinned `mcp @ git+main` dependency periodically breaks (see `oci-mcp.md`'s Gotchas). |

## Rebuilding after a Renovate PR merges

```bash
# kubernetes-mcp-oci
docker build -t kubernetes-mcp-oci:local kubernetes-mcp-oci/

# backstage-mcp-server
docker build -t backstage-mcp-server:local backstage-mcp-server/

# oci-mcp -- reinstall the mcp SDK pin into the existing venv
~/.envs/oci-mcp/bin/pip install --force-reinstall --no-deps -r oci-mcp/requirements.txt
```

For an `images.json` bump, update the corresponding tag in
`~/.claude.json`'s `mcpServers` entry and `docker pull` the new tag.

Either way, fully restart Claude Code afterward — MCP config, images, and
the venv's installed packages are only picked up at startup.
