# Local MCP containers

How every locally-run MCP server is wired up. All five run as Docker
containers as of 2026-09-24 — even `oci`, which converted from a pip venv
that day, see [oci-mcp.md](oci-mcp.md). This doc covers which ones reach the cluster
through the OCI bastion keepalive that backs `kubectl`, and which don't
need the cluster at all.

Companion to [cluster-mcp.md](cluster-mcp.md) (the in-cluster topology `grafana`/`kubernetes`
replaced) and local cluster access (oci-bastion-keepalive TechDocs) (the keepalive they ride on). The
Dockerfiles, `images.json`, and the scripts that build/register all five
live in [`mcp-local`](https://github.com/tnoff/mcp-local), not this repo —
this doc covers the *why* and the cluster-connectivity details that repo's
own README deliberately doesn't duplicate.

## TL;DR

- Each MCP is a `docker run -i --rm` stdio entry in `~/.claude.json` — Claude
  Code owns the container lifecycle (spawns per session, `--rm` on exit). No
  compose, no ports, no long-lived containers. stdio is universal, so the
  images' HTTP-transport support is irrelevant.
- **`gitlab`** needs no cluster access — it hits `gitlab.com` directly. Just
  a token in an `--env-file`.
- **`grafana`** and **`kubernetes`** target in-cluster endpoints, so they run
  `--network host` and reach them over the keepalive's loopback port-forwards
  (`127.0.0.1:3000`, `127.0.0.1:6443`). Their creds come from the laptop, not
  a cluster Secret.
- The keepalive now forwards **more than `6443`**: the LGTM service ports
  (`3000`/`3100`/`3200`/`9009`) are added so the local grafana MCP can reach
  Grafana and — for streaming Tempo — Tempo directly.
- Credentials live under `~/.mcp-local/<mcp>/` at mode `600`. Read-only parity
  with the in-cluster MCPs is preserved (`GITHUB_READ_ONLY=1`,
  `--read-only`, grafana's `-disable-write`).
- **`github`** (added 2026-09-16) is `gitlab`'s old shape exactly — no cluster
  access, a read-only PAT in an `--env-file`, plus `GITHUB_READ_ONLY=1` as a
  second, server-side enforcement layer. Fine-grained PAT, all `tnoff`-owned
  repos, read-only. See [[`projects/github-mcp-local.md`](https://github.com/tnoff/docs/blob/main/projects/github-mcp-local.md)](https://github.com/tnoff/docs/blob/main/projects/github-mcp-local.md) for the full
  decision trail (App-vs-PAT, why it's *not* terraform-tracked).
- **`backstage`** (added 2026-09-21) needs `--network host` like
  `grafana`/`kubernetes`, but reaches Backstage over a one-off `kubectl
  port-forward` to `:7007` the operator runs by hand — **not** a
  `PORT_FORWARD_N` entry in the keepalive. Credentials are a Backstage
  external-access token in `--env-file`, generated against the target
  instance directly (this fleet doesn't mint it).
- **`oci`** (converted from a pip venv 2026-09-24) needs no cluster access
  at all — it hits OCI's public API directly, same as `github` hits
  `api.github.com`. The one MCP with a *scoped* credential copy rather
  than a flat `--env-file`: see [oci-mcp.md](oci-mcp.md).

## Why local, not in-cluster

The in-cluster MCPs ([cluster-mcp.md](cluster-mcp.md)) work, but they observe the very cluster
they run in: if the cluster is unhealthy, the tools you'd use to debug it are
unhealthy too. Running grafana + kubernetes MCPs on the laptop is a
**debug-from-outside** improvement — the observability tooling survives a sick
cluster. `gitlab`/`github`/`backstage`/`oci` moving or starting local is pure
convenience — none of them ever needed the cluster to begin with.

The trade this makes: creds now live on the laptop instead of in a cluster
Secret, and a per-session `docker run` replaces `kubectl exec`. Both are
acceptable for a single-operator setup.

## The keepalive relation

local cluster access (oci-bastion-keepalive TechDocs) covers how `rotate_session.py` holds `127.0.0.1:6443`
open to the private OKE API server. The same daemon also carries the extra
`kubectl port-forward`s the local MCPs need, declared as `PORT_FORWARD_N`
entries in `rotate_session.env`:

| Local port | Forwards to | Consumed by |
|---|---|---|
| `6443` | OKE API server (via the bastion relay) | `kubernetes` MCP, `kubectl` |
| `3000` | `svc/grafana:3000` | `grafana` MCP (proxy path: Loki/Mimir/dashboards/alerts) |
| `3200` | `svc/tempo:3200` | `grafana` MCP — **Tempo streaming search only** |
| `3100` | `svc/loki:3100` | direct Loki (unused today; here if ever needed) |
| `9009` | `svc/mimir:9009` | direct Mimir (unused today; here if ever needed) |

```ini
# rotate_session.env  — entries use namespace/svc/name:localPort:remotePort
PORT_FORWARD_1=monitoring/svc/grafana:3000:3000
PORT_FORWARD_2=monitoring/svc/mimir:9009:9009
PORT_FORWARD_3=monitoring/svc/tempo:3200:3200
PORT_FORWARD_4=monitoring/svc/loki:3100:3100
```

After editing, `systemctl --user restart rotate-session` and confirm every
port is live before expecting an MCP to work:

```bash
ss -ltn | grep -E '127.0.0.1:(3000|3100|3200|6443|9009)'   # expect all five
```

Most grafana MCP traffic never touches `3100`/`3200`/`9009`: Loki, Mimir,
dashboards and alerts go through Grafana's **server-side datasource proxy**
(`GRAFANA_URL` → in-cluster Grafana → in-cluster datasource). Only Tempo's
streaming search dials a datasource directly — see Gotchas.

## Per-MCP setup

All credential files live under `~/.mcp-local/<mcp>/`, mode `600`. Pre-pull
each image so the first session doesn't stall on a registry fetch.

### gitlab — RETIRED 2026-09-15

> **Status — RETIRED.** Superseded by a first-party GitLab MCP connector
> available directly in-session — the local `docker run` container and its
> hand-minted `~/.mcp-local/gitlab/.env` PAT are redundant. Remove the
> `gitlab` entry from `~/.claude.json` and revoke the `glpat-...` token in
> GitLab (operator action, not terraform-tracked — see
> [`projects/secret-age-tracker-github-reader.md`](https://github.com/tnoff/docs/blob/main/projects/secret-age-tracker-github-reader.md)'s PAT inventory). Section
> kept as historical record; do not stand this container back up.

```
~/.mcp-local/gitlab/.env
  GITLAB_API_URL=https://gitlab.com/api/v4
  GITLAB_READ_ONLY_MODE=true
  GITLAB_PERSONAL_ACCESS_TOKEN=glpat-...     # read_api PAT
```

Image `docker.io/zereight050/gitlab-mcp:2.1.29` (public). No `--network host`
— the default bridge reaches `gitlab.com` fine. The token is read by the
docker **daemon** from `--env-file` (as you), so `600` is not a problem.

### grafana — `--network host`, over the `3000` forward

```
~/.mcp-local/grafana/.env
  GRAFANA_URL=http://localhost:3000
  GRAFANA_USERNAME=admin
  GRAFANA_PASSWORD=...                       # grafana-admin-creds password
```

Image `docker.io/grafana/mcp-grafana:1.6.0` (public, pinned in `images.json`). `--network host` is
required so the container's `localhost:3000` is the host's — i.e. the
keepalive forward. Auth is basic auth as the Grafana admin; the password is the one in the
terraform-managed `grafana-admin-creds` Secret (`monitoring` namespace). Registered with
`-disable-write` to keep the MCP read-only (admin credentials would otherwise
expose the write tools). An earlier setup used a Viewer-scoped
`GRAFANA_SERVICE_ACCOUNT_TOKEN` instead.

### kubernetes — `--network host` + OCI exec-plugin, over the `6443` forward

Two files under `~/.mcp-local/kubernetes/` — a kubeconfig and a Dockerfile;
**no token file** (the exec-plugin mints one per connection):

```yaml
# kubeconfig  — a copy of ~/.kube/config; the exec-plugin, not a static
# token, provides auth
apiVersion: v1
kind: Config
clusters:
- name: oke
  cluster:
    server: https://127.0.0.1:6443
    certificate-authority-data: <copied from the working kubeconfig>
contexts: [{name: oke, context: {cluster: oke, user: oke}}]
current-context: oke
users:
- name: oke
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: oci
      args: [ce, cluster, generate-token, --cluster-id, <cluster-ocid>, --region, <region>]
```

```dockerfile
# Dockerfile  — the upstream image ships only the Go server binary and
# can't run the OCI exec-plugin, so lay `oci` in alongside it
FROM ghcr.io/containers/kubernetes-mcp-server:latest AS mcp
FROM ghcr.io/oracle/oci-cli:latest
COPY --from=mcp /app/kubernetes-mcp-server /usr/local/bin/kubernetes-mcp-server
ENTRYPOINT ["/usr/local/bin/kubernetes-mcp-server"]
```

The Dockerfile itself now lives in
[`mcp-local`](https://github.com/tnoff/mcp-local); both bases stay pinned to
`:latest` there too (neither upstream publishes releases Renovate can track
a bump against), so "rebuild after an upstream bump" is still a manual call
— `scripts/sync-images.sh` (`git pull` + `docker build`, tagged
`kubernetes-mcp-oci:local` either way — ~924 MB, mostly the oci-cli base).
The container runs `--read-only`, bind-mounts the dir read-only at `/kube`
(`KUBECONFIG=/kube/kubeconfig`) **and** `~/.oci` read-only, with
`HOME=/home/tnorth` so the exec-plugin finds the `DEFAULT` profile's config
+ signing key. Per connection, `client-go` runs the `exec` block →
`oci ce cluster generate-token` mints a fresh OKE token.

**Load-bearing credential.** The exec-plugin authenticates with the
`DEFAULT` (`san-jose`) `~/.oci` profile — the `ty_north@yahoo.com` personal
key (fingerprint `5a:2f:…:45`), the same identity the bastion keepalive
uses. It maps to cluster-admin, so `--read-only` is the real guard. In
secret rotation it must be **rotated, not pruned** — deleting it kills the
tunnel and all cluster access. Because `~/.oci` is mounted read-only, a
rotation flows into the container on its next run.

### github — no cluster access, added 2026-09-16

```
~/.mcp-local/github/.env
  GITHUB_PERSONAL_ACCESS_TOKEN=github_pat_...   # fine-grained, read-only, all tnoff repos
  GITHUB_READ_ONLY=1
```

Image `ghcr.io/github/github-mcp-server:v1.12.2` (public, official). No
`--network host` — default bridge reaches `api.github.com` fine, same as
`gitlab`. The PAT is generated by hand at
https://github.com/settings/personal-access-tokens (resource owner `tnoff`,
**all repositories**, read-only on Contents/Issues/Pull requests/Actions/
Metadata) and manually rotated — same untracked-manual shape as `gitlab`'s
old token, **not** run through terraform-admin's rotation ledger (see
[[`projects/github-mcp-local.md`](https://github.com/tnoff/docs/blob/main/projects/github-mcp-local.md)](https://github.com/tnoff/docs/blob/main/projects/github-mcp-local.md)'s Resolved decisions for why: the
credential is laptop-only with no CI or cluster consumer, so the ledger —
which exists to report on secrets a pipeline or workload actually reads —
has nothing to gain from tracking it).

`GITHUB_READ_ONLY=1` is a real server-side flag, confirmed by the
container's own startup log (`readOnly=true`) — unlike the App-auth path
the three tracked GitHub App keys use elsewhere in the fleet, this server
takes a plain PAT with no JWT/installation-token exchange.

### backstage — `--network host`, added 2026-09-21

```
~/.mcp-local/backstage/.env
  BACKSTAGE_BASE_URL=http://localhost:7007
  BACKSTAGE_TOKEN=<external-access token>
```

Image `backstage-mcp-server:local` — built from source in `mcp-local`
(upstream, [Coderrob/backstage-mcp-server](https://github.com/Coderrob/backstage-mcp-server),
ships no image). `--network host` is required, same reasoning as
`grafana`/`kubernetes`: `BACKSTAGE_BASE_URL`'s `localhost:7007` targets a
`kubectl port-forward` the operator runs by hand for this one MCP
specifically — **not** a `PORT_FORWARD_N` entry in `rotate_session.env`,
so it doesn't survive a keepalive restart the way `grafana`'s/`kubernetes`'
do. Caught missing from the registered entry 2026-09-25, present since this
MCP's first setup — see `mcp-local`'s README for the fix.

The token has to be accepted by the target instance's
`backend.auth.externalAccess` config (a static token, or a JWT off a
configured JWKS entry); this fleet doesn't mint it centrally.

### oci — no cluster access, converted from a pip venv 2026-09-24

Two files under `~/.mcp-local/oci-mcp/` — `config` and
`mcp_readonly_api_key.pem` — not a single `.env`, and not a mount of the
operator's whole `~/.oci` either. Full reasoning and setup:
[oci-mcp.md](oci-mcp.md) and `mcp-local`'s README. Short version: this MCP hits OCI's
public API directly (no cluster access, no keepalive), but unlike
`grafana`/`github`/`backstage`'s flat token files, its credential is a
*scoped copy* of just the `MCP_READONLY` profile — mounting all of
`~/.oci` would also hand a less-audited third-party package
(`jopsis/mcp-server-oci`) the `DEFAULT` profile this doc's `kubernetes`
section calls load-bearing.

## Claude Code wire-up

Registered with `claude mcp add` — or `mcp-local/scripts/register-mcps.sh`
for all five active ones at once, idempotent, safe to re-run — not by
hand-editing `~/.claude.json`. Run either from a plain terminal with Claude
Code closed (see Gotchas for why). Everything after `--` is passed through
verbatim, so it's a direct translation of the `command`/`args` pair each
entry used to be written as. Every entry is `--scope user`, i.e. the
top-level `mcpServers` block, not scoped to a single project checkout.

```bash
# gitlab — RETIRED, do not run this; kept for the historical record only
claude mcp add --scope user gitlab -- docker run -i --rm \
  --env-file /home/tnorth/.mcp-local/gitlab/.env \
  docker.io/zereight050/gitlab-mcp:2.1.29

claude mcp add --scope user grafana -- docker run -i --rm --network host \
  --env-file /home/tnorth/.mcp-local/grafana/.env \
  docker.io/grafana/mcp-grafana:1.6.0 -t stdio -disable-write

claude mcp add --scope user kubernetes -- docker run -i --rm --network host \
  -e HOME=/home/tnorth -e KUBECONFIG=/kube/kubeconfig \
  -v /home/tnorth/.oci:/home/tnorth/.oci:ro \
  -v /home/tnorth/.mcp-local/kubernetes:/kube:ro \
  kubernetes-mcp-oci:local --read-only

claude mcp add --scope user oci -- docker run -i --rm \
  -e HOME=/home/tnorth \
  -v /home/tnorth/.mcp-local/oci-mcp:/home/tnorth/.oci:ro \
  oci-mcp:local --profile MCP_READONLY

claude mcp add --scope user github -- docker run -i --rm \
  --env-file /home/tnorth/.mcp-local/github/.env \
  ghcr.io/github/github-mcp-server:v1.12.2

claude mcp add --scope user backstage -- docker run -i --rm --network host \
  --env-file /home/tnorth/.mcp-local/backstage/.env \
  backstage-mcp-server:local
```

`claude mcp remove <name>` is the inverse — use it for `gitlab` if it's
still registered from before the retirement above.

MCP config is read **only at startup** — fully restart Claude Code after
running any of these, then `/mcp` should show the server connected.

## Token refresh (kubernetes)

Nothing to refresh. The kubeconfig's `exec` block mints a fresh OKE token
per connection via the in-container `oci` CLI, so auth is always current —
no static token file, no `systemd --user` timer. The tunnel provides
*reachability* (`127.0.0.1:6443`); the exec-plugin provides *auth*.

This replaced an earlier design that froze one `generate-token` snapshot
into a `tokenFile:` and refreshed it from a timer. OKE tokens are
short-lived, so a missed refresh expired the token and every tool call
`401`'d (the server still *connects* — client init is lazy). Baking `oci`
into the image so the exec-plugin runs where `client-go` expects it removed
that whole moving part (2026-07-14).

## Gotchas worth knowing

- **`--network host` for any loopback-forwarded endpoint, keepalive or
  not.** A bridged container's own `localhost` is not the host's, so it
  can't see a `127.0.0.1:<port>` forward regardless of what's on the other
  end. `grafana` (`:3000`) and `kubernetes` (`:6443`) forward through the
  keepalive; `backstage` (`:7007`) forwards through a one-off
  `kubectl port-forward` the operator runs by hand — all three still need
  `--network host` for the same underlying reason. Missing from
  `backstage`'s registered entry from its first setup until caught
  2026-09-25. `gitlab`/`github`/`oci` don't need it — they go outbound to a
  public endpoint, not a loopback forward.
- **gitlab/grafana read creds via `--env-file`; `kubernetes` bind-mounts
  them and runs as root.** `--env-file` is read by the docker daemon *as
  you*, so gitlab/grafana's `600` `.env` files work with no `--user`.
  `kubernetes` bind-mounts `~/.mcp-local/kubernetes` + `~/.oci` read-only and
  runs as **root** (no `--user`): root reads the `600` files regardless, and
  the in-container `oci` exec-plugin gets a writable `$HOME`. The earlier
  static-token design used `--user 1000:1000` to read a `600` token file as
  its owner; the exec-plugin design dropped it — an ephemeral `--rm` laptop
  container as root is fine. (`chmod 644` to avoid `--user` would world-expose
  the creds — don't.)
- **Tempo streaming dials the datasource FQDN directly.** The Tempo datasource
  has `streamingEnabled.search: true`, so mcp-grafana's trace search bypasses
  the Grafana proxy and connects to the datasource `url`
  (`http://tempo.monitoring.svc.cluster.local:3200`). Forwarding `:3200` isn't
  enough — the container must also **resolve that cluster hostname to
  `127.0.0.1`**: add `--add-host tempo.monitoring.svc.cluster.local:127.0.0.1`
  to the grafana args, or (if host-networking ignores `--add-host` on your
  Docker version) a `127.0.0.1 tempo.monitoring.svc.cluster.local` line in
  `/etc/hosts`. Loki/Mimir/dashboards go through the `:3000` proxy and need
  none of this — which is why only Tempo timed out.
- **`PORT_FORWARD_N` format is load-bearing.** Entries must be
  `namespace/svc/name:localPort:remotePort`. A DNS-form value
  (`tempo.monitoring.svc:3200:3200`) crashes `rotate_session.py` on parse,
  which takes down the **whole** keepalive — including `6443`, so `kubectl`
  and the k8s MCP die too. After any edit, `ss -ltn` to confirm all ports are
  actually listening; a crash-looped `rotate-session` shows
  `activating (auto-restart)` in `systemctl --user status`.
- **`~/.claude.json` is rewritten live by Claude Code.** It's a large file the
  running app persists on its own; the `mcpServers` block survives those
  rewrites, but your edits only take effect on a full restart. Prefer `claude
  mcp add`/`remove` when the app is closed for a clean write.
- **Secrets on disk.** `.env` and `token` files are `chmod 600`. Pasting a
  token into a chat/transcript is the real leak vector — write straight to the
  file. These are laptop-local; each operator sets up their own (no shared
  cluster-side equivalent, same as [oci-mcp.md](oci-mcp.md)).

---

## Verified against

| Component | Version / ref | Date |
|---|---|---|
| `docker.io/grafana/mcp-grafana` | `0.17.0` | 2026-07-09 |
| `ghcr.io/containers/kubernetes-mcp-server` | `:latest`, wrapped in local `kubernetes-mcp-oci` image (+ `ghcr.io/oracle/oci-cli`) | 2026-07-14 |
| `docker.io/zereight050/gitlab-mcp` | `2.1.29` | 2026-07-09 |
| `oci-bastion-keepalive` | `53f44a9` | 2026-07-14 |
| `ghcr.io/github/github-mcp-server` | `v1.12.1` | 2026-09-16 |
| `mcp-local` (`backstage-mcp-server`, `oci-mcp` Dockerfiles; the `--network host` fix) | `main` | 2026-09-25 |

*Related: [cluster-mcp.md](cluster-mcp.md) (the in-cluster MCP topology `grafana`/`kubernetes`
replaced), local cluster access (oci-bastion-keepalive TechDocs) (the keepalive + port-forwards these ride
on), [oci-mcp.md](oci-mcp.md) (the OCI credential-provisioning chain this doc doesn't
duplicate), and [`mcp-local`](https://github.com/tnoff/mcp-local) (every
Dockerfile, `images.json`, and the build/register scripts).*
