# The upstream kubernetes-mcp-server image ships only the Go server binary
# and can't run the OCI exec-plugin the kubeconfig needs for auth, so lay
# `oci` in alongside it. See docs/interactions/local-mcp-containers.md for
# the full kubeconfig + Claude Code wiring this image is built for.
#
# Both bases are pinned to `:latest` deliberately, not an oversight --
# neither upstream publishes semver releases Renovate's dockerfile manager
# can track. If that ever changes, or if digest pinning
# (dockerfile.pinDigests) gets turned on here, update this comment.
FROM ghcr.io/containers/kubernetes-mcp-server:latest AS mcp
FROM ghcr.io/oracle/oci-cli:latest
COPY --from=mcp /app/kubernetes-mcp-server /usr/local/bin/kubernetes-mcp-server
ENTRYPOINT ["/usr/local/bin/kubernetes-mcp-server"]
