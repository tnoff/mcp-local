#!/usr/bin/env bash
#
# Pull every locally-run MCP's current image. Run by hand, whenever --
# nothing in this repo triggers it automatically.
#
# The five images split into two groups that need different treatment:
#
#   kubernetes-mcp-oci, backstage-mcp-server, oci-mcp -- built by
#   build-push.yml and pushed to OCIR under a single moving :latest tag.
#   ~/.claude.json already points at a stable LOCAL tag (<name>:local), so
#   pulling + retagging here is the whole story -- nothing in Claude Code's
#   config ever needs to change for these three.
#
#   github, grafana -- pulled as-is from their public upstream registries,
#   version-PINNED (not :latest) in images.json. Re-pulling the same pin
#   gets you nothing; it's immutable. The only way anything newer shows up
#   is a Renovate PR bumping the pin, merging, and THIS script being run
#   again -- and even then, ~/.claude.json's args still name the OLD tag
#   until you re-run the printed `claude mcp add` command yourself.
#
# This script never touches ~/.claude.json. Same reasoning as every MCP
# wire-up in this repo (README.md): that file is rewritten live by a
# running Claude Code, so edits belong in a plain terminal with the app
# closed, not inside a script that might be running underneath it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OCI_REGISTRY="iad.ocir.io"
OCI_NAMESPACE="tnoff"

echo "== Built locally: kubernetes-mcp-oci, backstage-mcp-server, oci-mcp =="
for pair in \
  "kubernetes-mcp-oci=mcp-local-kubernetes-mcp-oci" \
  "backstage-mcp-server=mcp-local-backstage-mcp-server" \
  "oci-mcp=mcp-local-oci-mcp"; do
  local_name="${pair%%=*}"
  ocir_repo="${pair##*=}"
  ref="${OCI_REGISTRY}/${OCI_NAMESPACE}/${ocir_repo}:latest"
  echo
  echo "-- ${local_name} --"
  docker pull "${ref}"
  docker tag "${ref}" "${local_name}:local"
  echo "   tagged ${local_name}:local"
done

echo
echo "== Pulled as-is: github, grafana =="
echo "   (version-pinned in images.json -- re-run this after a Renovate PR"
echo "   bumping it merges, not on a schedule; there's nothing new otherwise)"

# The claude mcp add commands below duplicate README.md's -- keep both in
# sync by hand if either changes. Not derived from images.json's ref
# automatically because the per-server docker run flags (--network host,
# -t stdio, which .env file) aren't data this file has any business storing.
python3 - "${REPO_ROOT}/images.json" <<'PY'
import json
import subprocess
import sys

with open(sys.argv[1]) as f:
    images = {k: v for k, v in json.load(f).items() if not k.startswith("_")}

for name, ref in images.items():
    print(f"\n-- {name} --", flush=True)
    subprocess.run(["docker", "pull", ref], check=True)
    if name == "github":
        print("   To point Claude Code at this pull, close it and run:")
        print("     claude mcp remove github")
        print("     claude mcp add --scope user github -- docker run -i --rm \\")
        print("       --env-file /home/tnorth/.mcp-local/github/.env \\")
        print(f"       {ref}")
    elif name == "grafana":
        print("   To point Claude Code at this pull, close it and run:")
        print("     claude mcp remove grafana")
        print("     claude mcp add --scope user grafana -- docker run -i --rm --network host \\")
        print("       --env-file /home/tnorth/.mcp-local/grafana/.env \\")
        print(f"       {ref} -t stdio")
    else:
        print(f"   No claude mcp add recipe wired up for '{name}' in this script yet.")
PY

echo
echo "Done. Restart Claude Code to pick up anything that changed."
