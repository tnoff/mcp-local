# mcp-local

Registry of every MCP server Claude Code runs locally on the laptop, all five as
`docker run -i --rm` stdio containers. This repo exists so version drift across
them is tracked in one place by Renovate. Wiring details, the cluster
port-forwards and per-MCP gotchas are in
[docs/local-mcp-containers.md](docs/local-mcp-containers.md); the OCI MCP's
credential provisioning is in [docs/oci-mcp.md](docs/oci-mcp.md).

**Nothing here is built or deployed by CI.** A Renovate PR landing a bump is the
trigger to rebuild by hand and restart Claude Code, not an automated rollout.
The one exception is a PR check: `ci.yml` builds each changed Dockerfile
(`linux/amd64`, matching the laptop) without pushing and runs TruffleHog on the
image. The images actually run are still the ones `sync-images.sh` builds on the
laptop, so that scan covers the Dockerfiles, not the running artifact.

## Contents

| Path | What |
|---|---|
| `kubernetes-mcp-oci/Dockerfile` | `kubernetes-mcp-oci:local`: wraps `kubernetes-mcp-server` with the OCI CLI so its exec-plugin can mint OKE tokens. Both bases are pinned to `:latest` (neither upstream publishes releases Renovate can track). |
| `backstage-mcp-server/Dockerfile` | `backstage-mcp-server:local`: builds [Coderrob/backstage-mcp-server](https://github.com/Coderrob/backstage-mcp-server) from source at a pinned commit (no upstream image). Renovate tracks the pin via a `git-refs` customManager. |
| `oci-mcp/Dockerfile` | `oci-mcp:local`: builds [jopsis/mcp-server-oci](https://github.com/jopsis/mcp-server-oci) from a pinned commit; `requirements.txt` pins its runtime dependencies (see [oci-mcp.md](docs/oci-mcp.md)). |
| `images.json` | Pinned public images with no local build: `github-mcp-server`, `mcp-grafana`. |
| `scripts/sync-images.sh` | `git pull`, rebuild the three local images, pull the two pinned ones, then reap stale containers and remove old images. |
| `scripts/reap-mcp-containers.sh` | Stop MCP containers left by closed or suspended Claude Code sessions (dry run unless `--kill`). |
| `scripts/register-mcps.sh` | Run `sync-images.sh`, then `claude mcp add` all five. |

## Staying up to date

A merged Renovate PR only changes `main`; nothing on the laptop picks it up.
Run [`scripts/sync-images.sh`](scripts/sync-images.sh) by hand. It builds the
three local images as `<name>:local` (exactly what `~/.claude.json` already
references, so Claude Code's config does not change) and pulls the two images
pinned in `images.json`. For those two it prints the `claude mcp add` command to
run if the pin is newer than what is registered; it never touches
`~/.claude.json`. Fully restart Claude Code afterward, since MCP config and
images are read only at startup. Each Claude Code session runs its own set of
the five containers, so the script also reaps containers from closed or
suspended sessions and then removes superseded image tags; see
[Stale containers](docs/local-mcp-containers.md#stale-containers).

## Registering with Claude Code

[`scripts/register-mcps.sh`](scripts/register-mcps.sh) is the source of truth
for each MCP's exact `docker run` arguments. Run it from a plain terminal **with
Claude Code closed** (the running app rewrites `~/.claude.json` live) for
first-time setup or to re-point every entry at what is built right now. It is
idempotent (remove then add, `--scope user`). It never creates credential files;
an MCP whose credentials are missing is skipped with a pointer to the section
below.

## Credentials for each MCP

Everything lives under `~/.mcp-local/<mcp>/`, mode `600`, laptop-local and not
terraform-tracked (except where noted). Four are a flat `.env`; `kubernetes` and
`oci` are directories.

| MCP | Files | Notes |
|---|---|---|
| `grafana` | `grafana/.env`: `GRAFANA_URL=http://localhost:3000`, `GRAFANA_USERNAME=admin`, `GRAFANA_PASSWORD=...` | Password is the `grafana-admin-creds` Secret in `monitoring`. Registered with `-disable-write` to stay read-only; do not drop it. Alternative: `GRAFANA_SERVICE_ACCOUNT_TOKEN=glsa_...` from the `mcp-grafana` Secret in `monitoring` (minted by the `grafana-sa-bootstrap` CronJob). |
| `github` | `github/.env`: `GITHUB_PERSONAL_ACCESS_TOKEN=github_pat_...`, `GITHUB_READ_ONLY=1` | Fine-grained PAT, resource owner `tnoff`, all repositories, read-only on Contents/Issues/Pull requests/Actions/Metadata, created and rotated by hand. `GITHUB_READ_ONLY=1` is a server-side second layer. |
| `backstage` | `backstage/.env`: `BACKSTAGE_BASE_URL=http://localhost:7007`, `BACKSTAGE_TOKEN=...` | Token is the `backstage_mcp_token` variable in `terraform-admin`, surfaced in-cluster as Secret `backstage-mcp-token` (key `MCP_TOKEN`, namespace `backstage`). |
| `kubernetes` | `kubernetes/kubeconfig` | No token file: the kubeconfig's `exec` block runs `oci ce cluster generate-token` per connection. Mounts all of `~/.oci` read-only. |
| `oci` | `oci-mcp/config` (only the `[MCP_READONLY]` profile), `oci-mcp/mcp_readonly_api_key.pem` | A scoped copy, deliberately not a mount of `~/.oci`. See below. |

### oci

```bash
mkdir -p ~/.mcp-local/oci-mcp
cp <wherever mcp_readonly_api_key.pem lives> ~/.mcp-local/oci-mcp/
chmod 600 ~/.mcp-local/oci-mcp/mcp_readonly_api_key.pem
```

`~/.mcp-local/oci-mcp/config` holds only the profile, with `key_file` pointing at
the **in-container** path (the directory is mounted at `$HOME/.oci`):

```ini
[MCP_READONLY]
user=<same as the MCP_READONLY profile in ~/.oci/config>
fingerprint=<same>
tenancy=<same>
region=<same>
key_file=<your home dir, e.g. /home/you>/.oci/mcp_readonly_api_key.pem
```

`terraform-admin` writes the PEM and a ready-to-paste fragment to
`generated-output/`; see [oci-mcp.md](docs/oci-mcp.md).
