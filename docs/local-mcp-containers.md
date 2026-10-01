# Local MCP containers

How the five locally-run MCP servers (`grafana`, `kubernetes`, `github`,
`backstage`, `oci`) are wired up and which of them reach the cluster. The
[README](https://github.com/tnoff/mcp-local/blob/main/README.md) covers the
contents of the repo, the sync/register scripts and each MCP's credential files;
this page is the reference for the design and the gotchas.

## Shape

- Each MCP is a `docker run -i --rm` stdio entry in `~/.claude.json`. Claude Code
  owns the container lifecycle (spawned per session, `--rm` on exit): no compose,
  no ports, no long-lived containers. Register them with
  `scripts/register-mcps.sh`, which is the source of truth for the exact
  arguments.
- `grafana`, `kubernetes` and `backstage` target in-cluster endpoints, so they run
  `--network host` and reach them over loopback port-forwards.
- `github` and `oci` go outbound to public APIs (`api.github.com`, OCI's API) and
  need no cluster access and no `--network host`.
- Every server is read-only: `github` with `GITHUB_READ_ONLY=1`, `kubernetes`
  with `--read-only`, `grafana` with `-disable-write`, `oci` through a
  read-only IAM user.

Running these on the laptop rather than in the cluster is deliberate: the
observability and Kubernetes tooling survives a sick cluster, and credentials live
on the laptop instead of in cluster Secrets.

## Cluster connectivity

The cluster API is private. The [oci-bastion-keepalive](https://github.com/tnoff/oci-bastion-keepalive)
daemon holds `127.0.0.1:6443` open to it (see its TechDocs, "Local cluster
access") and can hold extra port-forwards to in-cluster services, declared as
`PORT_FORWARD_<n>=<namespace>/<kind>/<name>:<local>:<remote>` entries in its
`rotate_session.env`. What each MCP needs:

| Local port | Target | Consumed by |
|---|---|---|
| `6443` | OKE API server (the relay itself) | `kubernetes` MCP, `kubectl` |
| `3000` | `monitoring/svc/grafana:3000` | `grafana` MCP (Loki, Mimir, dashboards, alerts via Grafana's datasource proxy) |
| `3200` | `monitoring/svc/tempo:3200` | `grafana` MCP, Tempo streaming search only |
| `7007` | `backstage/svc/backstage:7007` | `backstage` MCP |

Loki (`3100`) and Mimir (`9009`) forwards are not needed: the Grafana proxy
reaches them server-side. The Backstage forward can be a managed
`PORT_FORWARD_<n>` entry like the others (the keepalive supports it); a one-off
`kubectl port-forward` also works but does not survive a keepalive restart or
pod restart. After editing the env file, `systemctl --user restart rotate-session`
and confirm the ports with `ss -ltn | grep 127.0.0.1`. A malformed
`PORT_FORWARD_<n>` value crashes the daemon, which takes `6443` and the
`kubernetes` MCP down with it.

## Per-MCP notes

**grafana.** Image pinned in `images.json`. Basic auth as the Grafana admin
(password from `grafana-admin-creds`), registered with `-t stdio -disable-write`.
Admin credentials would otherwise expose the write tools. The flag is
`-disable-write`; `mcp-grafana` has no `--read-only`.

**kubernetes.** The upstream image ships only the Go server binary and cannot
run the OCI exec-plugin, so `kubernetes-mcp-oci/Dockerfile` lays the `oci` CLI in
beside it. The kubeconfig under `~/.mcp-local/kubernetes/` points at
`https://127.0.0.1:6443` and authenticates through an `exec` block:

```yaml
users:
- name: oke
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: oci
      args: [ce, cluster, generate-token, --cluster-id, <cluster-ocid>, --region, <region>]
```

The container runs `--read-only`, mounts the kubeconfig directory read-only at
`/kube` (`KUBECONFIG=/kube/kubeconfig`) and `~/.oci` read-only with `HOME` set to
the host home so the exec-plugin finds the `DEFAULT` profile. A fresh OKE token is
minted per connection, so there is nothing to refresh. The tunnel provides
reachability, the exec-plugin provides auth.

*Load-bearing credential:* the exec-plugin uses the operator's `DEFAULT` OCI
profile, the same identity the keepalive uses. It maps to cluster-admin, so
`--read-only` is the real guard. When rotating that key, rotate it rather than
prune it: deleting it kills the tunnel and all cluster access. `~/.oci` is mounted
read-only, so a rotation flows in on the next container run. The container runs as
root, which reads the `600` files regardless; do not `chmod 644` them to avoid it.

**github.** Official image pinned in `images.json`, PAT in an `--env-file` (read
by the docker daemon as you, so mode `600` works with no `--user`).

**backstage.** Built from source in this repo. Needs `--network host` because
`BACKSTAGE_BASE_URL`'s `localhost:7007` would otherwise resolve to the container
itself. The token must be accepted by the instance's `backend.auth.externalAccess`
config; the fleet's Backstage uses a static token from `terraform-admin`.

**oci.** See [oci-mcp.md](oci-mcp.md). The one MCP with a scoped credential copy:
mounting all of `~/.oci` would also hand the less-audited third-party package the
`DEFAULT` profile.

## Gotchas

- **`--network host` for any loopback-forwarded endpoint.** A bridged container's
  own `localhost` is not the host's, so it cannot see a `127.0.0.1:<port>`
  forward whatever is on the other end.
- **Tempo streaming dials the datasource FQDN directly.** The Grafana Tempo
  datasource has `streamingEnabled.search: true` and url
  `http://tempo.monitoring.svc.cluster.local:3200`, so mcp-grafana's trace search
  bypasses the Grafana proxy. Forwarding `:3200` is not enough: the container
  must also resolve that hostname to `127.0.0.1`. Add
  `--add-host tempo.monitoring.svc.cluster.local:127.0.0.1` to the grafana args,
  or (if host networking ignores `--add-host` on your Docker version) a
  `127.0.0.1 tempo.monitoring.svc.cluster.local` line in `/etc/hosts`. Loki, Mimir
  and dashboards go through the `:3000` proxy and need none of this.
- **`$HOME` inside the image.** The `oci` and `kubernetes` images run as root
  whose default `$HOME` is `/root`; the OCI SDK looks under `$HOME/.oci/config`,
  so both are registered with `-e HOME=$HOME` and mount at that path.
- **`~/.claude.json` is rewritten live by Claude Code.** Edits (and
  `claude mcp add`/`remove`) only take effect on a full restart, and are safest
  with the app closed.
- **Do not paste tokens into chats or transcripts.** Write straight to the `600`
  file; each operator sets up their own credentials.
