# mcp-local

Registry of every MCP server Claude Code runs locally on the laptop, all
five as `docker run -i --rm` stdio containers. Companion to
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
| `oci-mcp/Dockerfile` | `oci-mcp:local` — builds [jopsis/mcp-server-oci](https://github.com/jopsis/mcp-server-oci) from source at a pinned commit (no upstream image, no releases). Replaces the `~/.envs/oci-mcp/` venv install `oci-mcp.md` documents — same underlying package, containerized so there's no laptop-wide pip install to maintain. `requirements.txt` pins every real runtime dependency explicitly: the package's own `mcp @ git+main` pin is not just occasionally stale but can be flatly unresolvable (hit this 2026-09-21 building the image — pip couldn't find a distribution for the dev snapshot upstream's HEAD demanded), so the Dockerfile installs the package with `--no-deps` and lets nothing depend on what upstream's git tip currently resolves to. |

## Staying up to date after a Renovate PR merges

Nothing here is built or deployed by CI, and nothing on the laptop picks up
a merge automatically — a merge just changes what's checked into `main`.
Run [`scripts/sync-images.sh`](scripts/sync-images.sh) by hand to catch up:

```bash
scripts/sync-images.sh
```

It `git pull`s this checkout first, then `docker build`s `kubernetes-mcp-oci`,
`backstage-mcp-server` and `oci-mcp` straight from the (now current)
Dockerfiles and tags them `<name>:local` — exactly what `~/.claude.json`
already references, so nothing about Claude Code's config ever needs to
change for those three. A registry briefly sat in this loop (build in CI,
push to a public OCIR repo, pull here) and was removed —
`docs/projects/mcp-local-registry.md` has the reasoning, short version: these
build in well under a minute, this laptop is the only consumer, and a
registry doesn't reduce the "remember to run this script" step either way,
it only relocates where the build happens.

For `images.json`'s two pulled-as-is images (`github`, `grafana`) the script
pulls whatever's currently pinned and prints the `claude mcp add` command to
run (with Claude Code closed) if that's newer than what's registered — same
"don't touch `~/.claude.json` itself" reasoning as every wire-up in this doc.

Either way, fully restart Claude Code afterward — MCP config and images are
only picked up at startup.

## oci-mcp credentials

Unlike `kubernetes-mcp-oci` (which needs the operator's own `DEFAULT`
profile for its exec-plugin, and so mounts all of `~/.oci` read-only),
`oci-mcp` only ever needs the narrower `MCP_READONLY` profile
`oci-mcp.md` describes. Don't mount all of `~/.oci` into this one — that
hands the container the `DEFAULT` profile's key too, for no reason.
Instead, keep a copy scoped to just this MCP, matching every other local
MCP's `~/.mcp-local/<mcp>/` convention:

```bash
mkdir -p ~/.mcp-local/oci-mcp
cp <wherever mcp_readonly_api_key.pem currently lives> ~/.mcp-local/oci-mcp/
chmod 600 ~/.mcp-local/oci-mcp/mcp_readonly_api_key.pem
```

`~/.mcp-local/oci-mcp/config` — a config file containing *only* the
`[MCP_READONLY]` profile, `key_file` pointing at the in-container path
below (not wherever the original PEM lives on the laptop):

```ini
[MCP_READONLY]
user=<same as the MCP_READONLY profile in ~/.oci/config today>
fingerprint=<same>
tenancy=<same>
region=<same>
key_file=/home/tnorth/.oci/mcp_readonly_api_key.pem
```

Register it with `claude mcp add`, not by hand-editing `~/.claude.json` —
run this from a plain terminal with Claude Code closed, since the running
app rewrites that file live and only reads `mcpServers` back in at
startup:

```bash
claude mcp add --scope user oci -- docker run -i --rm \
  -e HOME=/home/tnorth \
  -v /home/tnorth/.mcp-local/oci-mcp:/home/tnorth/.oci:ro \
  oci-mcp:local --profile MCP_READONLY
```

`-e HOME=/home/tnorth` is load-bearing: the image runs as root, whose
default `$HOME` is `/root`, and `oci.config.from_file()` looks under
`$HOME/.oci/config`. Verified 2026-09-21 that the image itself starts and
reaches `oci.config.from_file()` correctly (it fails loudly on a missing
config when run with no mount, which is the expected failure absent
credentials) — not yet verified end-to-end against a real
`MCP_READONLY` profile, since I can't read `~/.oci/config` to confirm
where its `key_file` currently points.
