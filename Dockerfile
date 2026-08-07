# syntax=docker/dockerfile:1.7

ARG OPENCHAMBER_REPOSITORY=https://github.com/openchamber/openchamber.git
ARG OPENCHAMBER_REF=main
ARG OPENCHAMBER_VERSION=unknown

# Keep the source outside this repository so the image remains a small,
# reproducible packaging wrapper around the upstream OpenChamber project.
FROM alpine:3.22 AS source
ARG OPENCHAMBER_REPOSITORY
ARG OPENCHAMBER_REF
WORKDIR /src
RUN apk add --no-cache ca-certificates git \
    && git clone --depth 1 --branch "${OPENCHAMBER_REF}" "${OPENCHAMBER_REPOSITORY}" .

FROM oven/bun:1.3.14 AS base
WORKDIR /app

FROM base AS deps
WORKDIR /app
COPY --from=source /src/package.json ./package.json
COPY --from=source /src/bun.lock ./bun.lock
COPY --from=source /src/bun-patches ./bun-patches
COPY --from=source /src/packages/ui/package.json ./packages/ui/
COPY --from=source /src/packages/web/package.json ./packages/web/
COPY --from=source /src/packages/electron/package.json ./packages/electron/
COPY --from=source /src/packages/vscode/package.json ./packages/vscode/
COPY --from=source /src/packages/mobile/package.json ./packages/mobile/
RUN bun install --frozen-lockfile --ignore-scripts

FROM deps AS builder
WORKDIR /app
COPY --from=source /src/ .
RUN bun run build:web

FROM oven/bun:1.3.14 AS runtime
ARG OPENCHAMBER_VERSION
ARG OPENCHAMBER_REF
WORKDIR /home/openchamber

RUN apt-get update && apt-get install -y --no-install-recommends \
  bash \
  ca-certificates \
  git \
  less \
  nodejs \
  npm \
  openssh-client \
  python3 \
  && rm -rf /var/lib/apt/lists/*

# Replace the base image's 'bun' user (UID 1000) so bind-mounted directories
# created by a normal host user are usable by the container process.
RUN userdel bun \
  && groupadd -g 1000 openchamber \
  && useradd -u 1000 -g 1000 -m -s /bin/bash openchamber \
  && chown -R openchamber:openchamber /home/openchamber
USER openchamber

ENV NPM_CONFIG_PREFIX=/home/openchamber/.npm-global
ENV PATH=${NPM_CONFIG_PREFIX}/bin:${PATH}

RUN npm config set prefix /home/openchamber/.npm-global \
  && mkdir -p /home/openchamber/.npm-global \
  && mkdir -p /home/openchamber/.local /home/openchamber/.config /home/openchamber/.ssh \
  && npm install -g opencode-ai

# cloudflared 2026.3.0; keep the upstream digest explicit.
COPY --from=cloudflare/cloudflared@sha256:6d91c121b803126f7a5344005d17a9324788fc09d305b6e2560ec6040a7ae283 /usr/local/bin/cloudflared /usr/local/bin/cloudflared

ENV NODE_ENV=production
ENV OPENCHAMBER_IMAGE_VERSION=${OPENCHAMBER_VERSION}
LABEL org.opencontainers.image.title="OpenChamber" \
      org.opencontainers.image.description="OpenChamber web interface for OpenCode" \
      org.opencontainers.image.source="https://github.com/wx2020/openchamber-docker" \
      org.opencontainers.image.url="https://github.com/openchamber/openchamber" \
      org.opencontainers.image.version="${OPENCHAMBER_VERSION}" \
      org.opencontainers.image.revision="${OPENCHAMBER_REF}" \
      org.opencontainers.image.licenses="MIT"

COPY --from=source /src/scripts/docker-entrypoint.sh /home/openchamber/openchamber-entrypoint.sh
COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/packages/web/node_modules ./packages/web/node_modules
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/packages/web/package.json ./packages/web/package.json
COPY --from=builder /app/packages/web/bin ./packages/web/bin
COPY --from=builder /app/packages/web/server ./packages/web/server
COPY --from=builder /app/packages/web/dist ./packages/web/dist

EXPOSE 3000
ENTRYPOINT ["sh", "/home/openchamber/openchamber-entrypoint.sh"]
