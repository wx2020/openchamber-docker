# syntax=docker/dockerfile:1.7

ARG OPENCHAMBER_REPOSITORY=https://github.com/openchamber/openchamber.git
ARG OPENCHAMBER_REF=main
ARG OPENCHAMBER_VERSION=unknown
ARG OPENCODE_VERSION=unknown

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

# ============================================
# Runtimes Stage - 下载所有 SDK
# ============================================
FROM debian:bookworm-slim AS runtimes
ARG NODE_VERSION=24.19.0
ARG PYTHON_VERSION=3.13.15
ARG GO_VERSION=1.25.14
ARG RUST_VERSION=1.98.0
ARG JAVA_VERSION=17
ARG GH_VERSION=2.98.0
ARG TEA_VERSION=0.14.2
ARG ANDROID_CMDLINE_VERSION=15859902
ARG ANDROID_BUILD_TOOLS_VERSION=36
ARG ANDROID_PLATFORM_VERSION=36
ARG GRADLE_VERSION=8.11.1

WORKDIR /opt

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates build-essential zlib1g-dev libffi-dev libssl-dev unzip xz-utils \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ---- Node.js ----
RUN curl -fsSL https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz | tar -xJC /usr/local --strip-components=1

# ---- Python ----
RUN curl -fsSL https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz | tar -xzC /opt \
    && cd /opt/Python-${PYTHON_VERSION} \
    && ./configure --enable-optimizations --prefix=/usr/local \
    && make -j$(nproc) \
    && make install \
    && cd / && rm -rf /opt/Python-${PYTHON_VERSION} \
    && ln -s /usr/local/bin/python3 /usr/local/bin/python

# ---- Go ----
RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz | tar -xzC /usr/local

# ---- Rust ----
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --default-toolchain ${RUST_VERSION} -y --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

# ---- Java JDK ----
RUN curl -fsSL https://github.com/adoptium/temurin${JAVA_VERSION}-binaries/releases/download/jdk-${JAVA_VERSION}.0.352%2B8/OpenJDK17U-jdk_x64_linux_hotspot_${JAVA_VERSION}.0.352_8.tar.gz | tar -xzC /opt/java
ENV JAVA_HOME=/opt/java/jdk-${JAVA_VERSION}.0.352+8
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# ---- Android SDK ----
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"
RUN mkdir -p ${ANDROID_HOME}/cmdline-tools \
    && curl -fsSL https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_VERSION}_latest.zip -o /tmp/cmdline-tools.zip \
    && unzip -q /tmp/cmdline-tools.zip -d ${ANDROID_HOME}/cmdline-tools \
    && mv ${ANDROID_HOME}/cmdline-tools/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest \
    && rm /tmp/cmdline-tools.zip \
    && yes | sdkmanager --licenses > /dev/null 2>&1 \
    && sdkmanager "build-tools;${ANDROID_BUILD_TOOLS_VERSION}" "platforms;android-${ANDROID_PLATFORM_VERSION}"

# ---- Gradle ----
RUN curl -fsSL https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip -o /tmp/gradle.zip \
    && unzip -q /tmp/gradle.zip -d /opt \
    && mv /opt/gradle-${GRADLE_VERSION} /opt/gradle \
    && rm /tmp/gradle.zip
ENV PATH="/opt/gradle/bin:${PATH}"

# ============================================
# Final Runtime Image
# ============================================
FROM oven/bun:1.3.14 AS runtime
ARG OPENCHAMBER_VERSION
ARG OPENCHAMBER_REF
ARG OPENCODE_VERSION=unknown
ARG GH_VERSION=2.98.0
ARG TEA_VERSION=0.14.2
WORKDIR /home/openchamber

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    less \
    openssh-client \
    wget \
    yq \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz | tar -xz -C /tmp \
    && mv /tmp/gh_${GH_VERSION}_linux_amd64/bin/gh /usr/local/bin/gh \
    && rm -rf /tmp/gh_${GH_VERSION}_linux_amd64 \
    && curl -fsSL https://dl.gitea.com/tea/${TEA_VERSION}/tea-${TEA_VERSION}-linux-amd64 -o /usr/local/bin/tea \
    && chmod +x /usr/local/bin/tea

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
    && if [ "${OPENCODE_VERSION}" != "unknown" ]; then \
         npm install -g opencode-ai@${OPENCODE_VERSION}; \
       else \
         npm install -g opencode-ai; \
       fi

COPY --from=cloudflare/cloudflared@sha256:6d91c121b803126f7a5344005d17a9324788fc09d305b6e2560ec6040a7ae283 /usr/local/bin/cloudflared /usr/local/bin/cloudflared

# 复制所有运行时
COPY --from=runtimes /usr/local/bin/node /usr/local/bin/node
COPY --from=runtimes /usr/local/bin/npm /usr/local/bin/npm
COPY --from=runtimes /usr/local/bin/python /usr/local/bin/python
COPY --from=runtimes /usr/local/bin/python3 /usr/local/bin/python3
COPY --from=runtimes /usr/local/lib/python3.13 /usr/local/lib/python3.13
COPY --from=runtimes /usr/local/go /usr/local/go
COPY --from=runtimes /root/.cargo /home/openchamber/.cargo
COPY --from=runtimes /opt/java /opt/java
COPY --from=runtimes /opt/android-sdk /opt/android-sdk
COPY --from=runtimes /opt/gradle /opt/gradle

# 设置环境变量
ENV JAVA_HOME=/opt/java/jdk-17.0.352+8
ENV PATH="${JAVA_HOME}/bin:/opt/gradle/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/usr/local/go/bin:/home/openchamber/.cargo/bin:${PATH}"
ENV GOPATH=/home/openchamber/go
ENV ANDROID_HOME=/opt/android-sdk

ENV NODE_ENV=production
ENV OPENCHAMBER_IMAGE_VERSION=${OPENCHAMBER_VERSION}
ENV OPENCODE_IMAGE_VERSION=${OPENCODE_VERSION}
LABEL org.opencontainers.image.title="OpenChamber" \
      org.opencontainers.image.description="OpenChamber web interface for OpenCode" \
      org.opencontainers.image.source="https://github.com/wx2020/openchamber-docker" \
      org.opencontainers.image.url="https://github.com/openchamber/openchamber" \
      org.opencontainers.image.version="${OPENCHAMBER_VERSION}" \
      org.opencontainers.image.revision="${OPENCHAMBER_REF}" \
      org.opencontainers.image.licenses="MIT" \
      org.openchamber.opencode.version="${OPENCODE_VERSION}"

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
