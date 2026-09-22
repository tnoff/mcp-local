# Upstream (github.com/Coderrob/backstage-mcp-server) ships no Dockerfile or
# published image, so this builds it from source. The pin below is tracked by
# the git-refs customManager in renovate.json -- same shape as the
# terraform-modules pin the infra fleet already uses -- so Renovate opens a
# PR when upstream main moves, rather than this silently going stale.
FROM node:24-slim AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ARG BACKSTAGE_MCP_SERVER_REF=5c4b4a80ca0212d08779325ef40da0ddb879cff2
RUN git clone https://github.com/Coderrob/backstage-mcp-server.git . \
    && git checkout "${BACKSTAGE_MCP_SERVER_REF}"
RUN corepack enable && corepack yarn install --immutable
RUN corepack yarn build

# Dependencies stay external to the rollup bundle (see rollup.config.js
# upstream), so the runtime stage needs node_modules, not just dist/.
FROM node:24-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
ENTRYPOINT ["node", "dist/cli.cjs"]
