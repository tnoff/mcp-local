# In-cluster MCPs (mcp-grafana, mcp-kubernetes, mcp-gitlab)

How the three `kubectl exec`-stdio MCP servers in the OKE `monitoring`
namespace were deployed, authenticated, and wired into Claude Code.
Companion to [oci-mcp.md](oci-mcp.md) (the fourth MCP, the only one not in-cluster).

> **Status — DECOMMISSIONED (2026-07-09).** The three in-cluster MCP
> Deployments were removed from `docker-apps/monitoring/` in commit
> `ecec641`; `monitoring/mcp-grafana/`, `monitoring/mcp-kubernetes/`, and
> `monitoring/mcp-gitlab/` no longer exist. The same three MCPs now run
> **locally as Docker containers** on the laptop over the bastion
> keepalive — that is the live topology, documented in
> **[local-mcp-containers.md](local-mcp-containers.md)**. This doc is retained as the historical
> record of the in-cluster shape. Credential disposition has since
> changed: the `mcp-gitlab` Secret + its terraform plumbing were removed
> (`terraform!188` + `terraform-admin!24`), and `mcp-grafana` is now
> minted in-cluster by the `grafana-sa-bootstrap` Job (the grafana
> terraform provider was dropped), not by `terraform/apps/`.

## TL;DR

- Three sidecar Deployments in `monitoring`: each holds a long-lived
  `sleep infinity` pod whose image bundles one MCP server. MCP clients
  spawn the server per session via
  `kubectl exec -i ... deploy/<X> -- <binary>`.
- Same shape on all three: no Service, no Ingress, no NetworkPolicy
  allow-rules — access is gated by kubeconfig + RBAC on the caller's
  side (`pods/exec` permission).
- Different auth on each: Grafana SA token from a Secret (terraform-
  managed), in-cluster ServiceAccount token (no Secret), GitLab PAT
  from a Secret (also terraform-managed — a manually-minted `read_api`
  PAT written from `var.mcp_gitlab_token`).
- Tokens are resolved at pod start via `secretKeyRef` and **not**
  refreshed when the Secret is rotated — every rotation needs a
  `kubectl rollout restart`.

## Why in-cluster, not local

The local OCI MCP (see [oci-mcp.md](oci-mcp.md)) runs as a venv on the laptop
because its credentials come from `~/.oci/config` and have nothing
in-cluster. These three are in-cluster because:

- Their targets are in-cluster (`grafana:3000`,
  `kubernetes.default.svc`) or reached from the cluster either way
  (`gitlab.com`).
- Auth either lives in a K8s Secret terraform already writes there
  (`mcp-grafana`) or is a projected SA token the cluster mints for
  free (`mcp-kubernetes`).
- The `kubectl exec -i` stdio path keeps **no MCP endpoint exposed
  through ingress** — RBAC on `pods/exec` is the gate.

## Per-MCP shape

| Deployment | Image | Server binary | Target | Auth |
|---|---|---|---|---|
| `mcp-grafana` | `docker.io/grafana/mcp-grafana:0.17.0` | `/app/mcp-grafana -t stdio` | `http://grafana:3000` | Viewer-role Grafana SA token via `mcp-grafana` Secret (key `service-account-token`) |
| `mcp-kubernetes` | `ghcr.io/containers/kubernetes-mcp-server:v0.0.62` | `/app/kubernetes-mcp-server --read-only` | `kubernetes.default.svc` | Projected SA token at `/var/run/secrets/kubernetes.io/serviceaccount/`; SA `mcp-kubernetes` bound to the built-in `view` ClusterRole via `mcp-kubernetes-view` |
| `mcp-gitlab` | `docker.io/zereight050/gitlab-mcp:2.1.25` | `node build/index.js` | `https://gitlab.com/api/v4` | `read_api` PAT via `mcp-gitlab` Secret (key `personal-access-token`) |

All three:

- `replicas: 1`, `nodeSelector: {node_role: internal}`.
- `command: ["sleep", "infinity"]` so the pod stays alive across MCP
  sessions; each `kubectl exec` spawns a fresh server process.
- Defense-in-depth read-only flags: `GITLAB_READ_ONLY_MODE=true`,
  `--read-only` on the kubernetes server, Viewer-only Grafana SA. RBAC
  / token-scope is the binding constraint regardless of client flags.

## Secret provisioning

| Secret | Provisioned by | Resource |
|---|---|---|
| `mcp-grafana` | terraform `apps/` stack | `grafana_service_account.mcp_grafana` + `grafana_service_account_token.mcp_grafana` + `kubernetes_secret_v1.mcp_grafana` (`terraform/apps/main.tf`) |
| `mcp-gitlab` | terraform `apps/` stack | `kubernetes_secret_v1.mcp_gitlab` fed from `var.mcp_gitlab_token` — a **manually-minted** `read_api` PAT (the token value is hand-created, not a `gitlab_group_access_token`; the PAT is plumbed in via `terraform-admin` → `apps`) |
| `mcp-kubernetes` | — | None needed. The ServiceAccount + ClusterRoleBinding live in `docker-apps/monitoring/mcp-kubernetes/serviceaccount.yaml` |

If either Secret-backed pod's Secret is missing, the pod sits in
`CreateContainerConfigError` until the Secret is reconciled.

### Rotation

`secretKeyRef` resolves once at pod start. Updating the Secret without
restarting the pod leaves the pod holding the old (revoked) token, so
every MCP session returns 401.

```bash
# mcp-grafana — terraform-managed
cd /path/to/terraform/apps
terraform apply -replace=grafana_service_account_token.mcp_grafana
kubectl -n monitoring rollout restart deploy/mcp-grafana

# mcp-gitlab — terraform-managed (PAT value still minted by hand on gitlab.com)
# 1. rotate the read_api PAT on gitlab.com
# 2. update TF_VAR_mcp_gitlab_token in terraform-admin, re-apply admin/
# 3. re-apply terraform apps/ (rewrites the mcp-gitlab Secret)
kubectl -n monitoring rollout restart deploy/mcp-gitlab

# mcp-kubernetes — projected SA tokens are auto-rotated by the kubelet
# (~1h cadence). No action needed.
```

## Claude Code wire-up

In `~/.claude.json`, alongside the local `oci` entry (see
[oci-mcp.md](oci-mcp.md)):

```json
{
  "mcpServers": {
    "grafana": {
      "command": "kubectl",
      "args": ["exec", "-i", "-n", "monitoring", "deploy/mcp-grafana", "--", "/app/mcp-grafana", "-t", "stdio"]
    },
    "kubernetes": {
      "command": "kubectl",
      "args": ["exec", "-i", "-n", "monitoring", "deploy/mcp-kubernetes", "--", "/app/kubernetes-mcp-server", "--read-only"]
    },
    "gitlab": {
      "command": "kubectl",
      "args": ["exec", "-i", "-n", "monitoring", "deploy/mcp-gitlab", "--", "node", "build/index.js"]
    }
  }
}
```

Requires `kubectl` on `PATH` with the cluster context active — the
`venv` for the `oci` exec-plugin and a live bastion session, per the
root `AGENTS.md` cluster-access notes.

## Gotchas worth knowing

- **`secretKeyRef` is not refreshed on Secret update** — applies to
  `mcp-grafana` and `mcp-gitlab`. Always pair the secret rotation with
  `kubectl rollout restart deploy/<X>` or every MCP session 401s. Does
  not apply to `mcp-kubernetes` (projected SA tokens auto-rotate).
- **`mcp-gitlab` Secret is now terraform-managed** (`kubernetes_secret_v1.mcp_gitlab`
  in `terraform/apps/main.tf`, fed from `var.mcp_gitlab_token`). The PAT
  value is still minted by hand on gitlab.com and plumbed in as a tfvar via
  `terraform-admin`; rotation is the tfvar flow above, not a raw
  `kubectl create secret`.
- **`mcp-kubernetes` `view` ClusterRole excludes Secrets, Roles, and
  RoleBindings.** RBAC-shape questions ("does ClusterRole X cover
  namespace Y") aren't answerable through this MCP today (called out
  in the root `AGENTS.md` cross-check section). Widen the SA's read
  access or accept the gap.
- **Default-deny ingress on `monitoring`** — no allow-rule is needed
  for these pods because they accept no inbound traffic. The matching
  allow-rule for Grafana itself to accept `mcp-grafana`'s outbound
  HTTP lives in `monitoring/network-policies.yaml`
  (`allow-grafana-ingress`).
- **Default-CMD divergence on `mcp-kubernetes`** — the upstream
  image's CMD launches an HTTP server on `:8080`. The deployment
  overrides `command: ["sleep", "infinity"]` because we want stdio
  over `kubectl exec`, not an HTTP listener.
- **`mcp-grafana`'s binary is not on `$PATH`** — it lives at
  `/app/mcp-grafana` inside the image, with no symlink onto `$PATH`.
  A bare `kubectl exec ... -- mcp-grafana -t stdio` fails instantly
  with `exec: "mcp-grafana": executable file not found in $PATH`
  (exit 255) — looks like the MCP server never connects, even though
  the pod is `1/1 Running`. Always invoke the full path. Confirmed
  still true as of image `0.17.0`; re-check on future version bumps
  in case upstream adds a PATH symlink.

---

## Verified against

| Project | SHA | Date |
|---|---|---|
| `docker-apps` | `74a42e0` | 2026-07-14 |
| `terraform` | `eaa9770` | 2026-07-14 |

*Related: [local-mcp-containers.md](local-mcp-containers.md) (the live local-container topology that
replaced this in-cluster one — same three MCPs run as `docker run` over the keepalive),
[oci-mcp.md](oci-mcp.md) (the fourth, local MCP),
workload deployment (docker-apps TechDocs) (broader monitoring-namespace context).*
