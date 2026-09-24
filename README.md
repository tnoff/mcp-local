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

## Registering everything with Claude Code

[`scripts/register-mcps.sh`](scripts/register-mcps.sh) runs `sync-images.sh`
first, then `claude mcp add`s all five — first-time setup on a new laptop, or
any time you want every entry re-pointed at what's actually built/pulled
right now:

```bash
scripts/register-mcps.sh
```

Unlike `sync-images.sh`, this one **does** call `claude mcp add`/`remove`
itself — that's its entire job, not a side effect it's careful to avoid. It
still must run with Claude Code closed, same reasoning as always: the
running app rewrites `~/.claude.json` live.

Credential files under `~/.mcp-local/<mcp>/` are never created by this
script — same as everywhere else in this repo, that's a manual, user-run
step. An MCP whose credential file doesn't exist yet is skipped with a
message pointing at where to set it up, not registered broken. `gitlab` is
never registered — it's retired.

## Credentials for each MCP

The single place to look when `register-mcps.sh` (or anything else) says a
credential is missing. Every credential lives under `~/.mcp-local/<mcp>/`,
mode `600`, laptop-local — none of it is terraform-tracked or shared. Four
of five are a flat `.env` file; `kubernetes` and `oci` are the two
exceptions, for different reasons explained in their own subsections.

### grafana

`~/.mcp-local/grafana/.env`:

```
GRAFANA_URL=http://localhost:3000
GRAFANA_SERVICE_ACCOUNT_TOKEN=glsa_...     # Viewer-scoped SA token
```

The token is the same `glsa_` value the in-cluster `mcp-grafana` Secret
holds — `kubectl -n monitoring get secret mcp-grafana -o
jsonpath='{.data.service-account-token}' | base64 -d`. It's
terraform-managed and on the secret-age tracker, so re-pull it after a
rotation. `GRAFANA_URL` assumes the OCI bastion keepalive's `:3000`
port-forward is up — see `docs/interactions/cluster-access.md`.

### github

`~/.mcp-local/github/.env`:

```
GITHUB_PERSONAL_ACCESS_TOKEN=github_pat_...   # fine-grained, read-only, all tnoff repos
GITHUB_READ_ONLY=1
```

The PAT is generated by hand at
[github.com/settings/personal-access-tokens](https://github.com/settings/personal-access-tokens)
(resource owner `tnoff`, **all repositories**, read-only on
Contents/Issues/Pull requests/Actions/Metadata) and manually rotated — not
terraform-tracked, see `docs/projects/github-mcp-local.md`'s Resolved
decisions for why. `GITHUB_READ_ONLY=1` is a real server-side flag, a second
enforcement layer stacked on top of the PAT's own read-only scopes.

### backstage

`~/.mcp-local/backstage/.env`:

```
BACKSTAGE_BASE_URL=http://localhost:7007
BACKSTAGE_TOKEN=<external-access token>
```

`BACKSTAGE_URL` assumes a `kubectl port-forward` to the in-cluster Backstage
service on `:7007`. The token has to be accepted by the target Backstage
deployment's `backend.auth.externalAccess` config (a static token, or a JWT
off a configured JWKS entry) — this repository doesn't mint it, generate one
against your own instance.

### kubernetes

Two files under `~/.mcp-local/kubernetes/` — `kubeconfig` and the
`Dockerfile` this repo already tracks — **no token file**. The kubeconfig's
`exec` block runs `oci ce cluster generate-token` inside the container on
every connection, so there's nothing to rotate; auth is always current. That
means this is also the one MCP that mounts all of `~/.oci` read-only
(`-v /home/tnorth/.oci:/home/tnorth/.oci:ro`, `-e HOME=/home/tnorth`) rather
than a scoped copy — the exec-plugin authenticates as the operator's own
`DEFAULT` profile, the same identity the bastion keepalive uses, and there's
no narrower credential for that identity to scope down to. Full kubeconfig
shape and the load-bearing-credential gotcha:
`docs/interactions/local-mcp-containers.md`.

### oci

Two files under `~/.mcp-local/oci-mcp/` — `config` and
`mcp_readonly_api_key.pem`. Unlike `kubernetes`, this one uses a **scoped
copy**, not a mount of all of `~/.oci`: `oci-mcp` only ever needs the
narrower `MCP_READONLY` profile, and mounting the whole directory would also
hand a less-audited third-party package (`jopsis/mcp-server-oci`) the
`DEFAULT` profile's broader credential for no reason.

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

`terraform-admin` provisions the underlying `mcp-readonly-bot` IAM user and
key (`read all-resources in tenancy`) and writes the PEM plus a
ready-to-paste `~/.oci/config` fragment to `generated-output/` — see
`docs/interactions/oci-mcp.md` for the full provisioning chain and Gotchas
(notably: the PEM's original path isn't necessarily under `~/.oci/` at all,
so "just mount `~/.oci`" may not even include it).

### Wiring any of these into Claude Code

[`scripts/register-mcps.sh`](scripts/register-mcps.sh) does this for all
five at once (see above) — safe to re-run any time a credential file
changes. To wire up one by hand instead, `claude mcp add` from a plain
terminal with Claude Code closed:

```bash
claude mcp add --scope user oci -- docker run -i --rm \
  -e HOME=/home/tnorth \
  -v /home/tnorth/.mcp-local/oci-mcp:/home/tnorth/.oci:ro \
  oci-mcp:local --profile MCP_READONLY
```

`-e HOME=/home/tnorth` is load-bearing there: the image runs as root, whose
default `$HOME` is `/root`, and `oci.config.from_file()` looks under
`$HOME/.oci/config`. Verified 2026-09-21 that the image itself starts and
reaches `oci.config.from_file()` correctly (it fails loudly on a missing
config when run with no mount, which is the expected failure absent
credentials) — not yet verified end-to-end against a real `MCP_READONLY`
profile, since I can't read `~/.oci/config` to confirm where its `key_file`
currently points. The other four's exact commands are in
`scripts/register-mcps.sh` and `docs/interactions/local-mcp-containers.md`.
