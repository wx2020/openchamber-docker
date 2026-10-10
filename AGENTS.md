# AGENTS.md

## Project Overview
- 面向 Docker 的 [OpenChamber](https://github.com/openchamber/openchamber) 发行包装仓库：从上游拉取指定版本构建镜像，经 GitHub Actions 发布到 GHCR（`ghcr.io/wx2020/openchamber-docker`），仅 linux/amd64。
- 不是上游的 fork；上游代码在构建时通过 `OPENCHAMBER_REF` clone，本仓库只管 Dockerfile、Compose 和发布工作流。

## Tech Stack
- 多阶段 `Dockerfile`（alpine source → bun deps/builder → debian runtimes → oven/bun runtime），构建时编译 Python/Go/Rust/JDK/Android/.NET 等工具链。
- Docker Compose v2（`docker-compose.yml`，端口 3000，六个宿主机挂载目录见 README）。
- GitHub Actions：`ci.yml`（PR/tag 校验 + 烟测）、`release.yml`（可复用，构建推送 GHCR + GitHub Release）、`manual-release.yml`、`sync-upstream.yml`（每日 UTC 05:17 同步上游稳定版到 `official-stable` 分支）。
- `VERSION` 文件为单一版本源；`main` 与 `official-stable` 分支的 VERSION 可能不同，发布从 `official-stable` 出。

## Directory Structure
```
Dockerfile                 # 多阶段构建，构建时 clone 上游
docker-compose.yml         # 运行时定义，OPENCHAMBER_UI_PASSWORD 必填
docker-compose.override.example.yml  # 可选：改连宿主机 OpenCode / tunnel / OH_MY_OPENCODE
.env.example               # 环境变量模板（.env 被 gitignore）
VERSION                    # 当前发行版本（semver，CI 强校验）
.github/workflows/         # ci / release / manual-release / sync-upstream
data/ workspaces/          # 运行时宿主机挂载点（不入 Git）
```

## Common Commands
- 本地构建：`docker buildx build --platform linux/amd64 --build-arg OPENCHAMBER_REF=v<ver> --build-arg OPENCHAMBER_VERSION=<ver> --tag ghcr.io/wx2020/openchamber-docker:local --load .`
- 启动：`cp .env.example .env`（设 `OPENCHAMBER_UI_PASSWORD`）→ `docker compose pull && docker compose up -d`
- Compose 校验：`OPENCHAMBER_UI_PASSWORD=x docker compose -f docker-compose.yml config --quiet`

## Code Conventions
- **OpenCode CLI 的 npm 包名由 OpenChamber 主版本决定**：2.x 用 `@opencode/cli`（上游 pin 与 `@opencode/client`/`@opencode/schema` 联动），1.x 用旧包 `opencode-ai`。Dockerfile 的 `OPENCODE_PACKAGE` build-arg 默认 `auto`，按 `OPENCHAMBER_VERSION` 主版本推导；CI/Release 工作流会显式传入解析结果。
- **版本解析**：`Resolve OpenCode CLI package and version` 步骤优先取上游同 ref 的 Dockerfile 里 `@opencode/cli@x.y.z` pin，无 pin 才回退 `npm show <pkg> version`。
- **守卫**：OpenChamber >= 2 时断言 CLI 主版本为 2 且 >= 2.0.20（上游 `compatibility.js` 的 `MINIMUM_OPENCODE_VERSION`），否则 fail fast。
- **镜像的运行时准备必须在 `USER openchamber` 之后执行**（与上游 Dockerfile 一致）：以root 创建 `~/.npm-global`、`~/.local`、`~/.config` 会让这些目录不可写，CLI 启动时 `mkdir /home/openchamber/.local/share` 报 EACCES 并失败。
- **OpenCode CLI 包是"占位 bin + postinstall 链接真实平台二进制"的结构**（`bin/opencode.exe` 在 postinstall 未执行时只是报错脚本）。npm 12 起 install scripts 默认 opt-in，必须用 `npm install -g --allow-scripts=<pkg>` 放行，否则装出的是占位脚本。
- **验证 CLI 用退出码，不要解析 `--version` 的输出**：该二进制在容器里可能不向 stdout 写版本（占位脚本退出非零，真实二进制退出 0），与包自身 postinstall 的 `verifyBinary` 一致——只判断 `opencode --version` 是否 exit 0。
- 工作流中版本必须是纯 semver（`X.Y.Z`），tag 必须是 `vX.Y.Z` 且与 VERSION 一致；镜像只推 GHCR，不推 Docker Hub。

## Notes
- `opencode-ai` 与 `@opencode/cli` 是同一上游项目的两个 npm 分发渠道：2.x 只发布在 `@opencode/cli`，`opencode-ai` 永远停在 1.x 线 —— 不要用 `npm show opencode-ai version` 为 OpenChamber 2.x 选版本。
- 上游 OpenChamber 2026-09 起（PR #3837）只支持 OpenCode 2.x，1.x 代码路径已删除。
- 镜像内进程 UID/GID 1000:1000；Linux 宿主机写权限问题用 `sudo chown -R 1000:1000 data workspaces`。
- 发布链路：`main` 上改功能/工作流 → 合入 `official-stable`（由 sync 或 Manual stable release 工作流执行）→ 从该分支触发 `release.yml`。
- **推送 official-stable 的隐含前提**：main 与 official-stable 的 `.github/workflows/` 内容必须一致。把 main 合入 official-stable 时若 workflow 文件有变化，默认 `GITHUB_TOKEN` 会因缺少 `workflow` scope 被拒（`permissions` 里没有 `workflows` 这个可用权限项）。改完 workflow 后，用带 `workflow` scope 的 token（本机 `gh` 即可）手动推一次 official-stable，两分支一致后日常同步即恢复正常。

## Maintenance
- 每次改完代码或完成新的分析后，必须调用 `sync-agents` skill 检查并更新本文件。
- 发现本文件与代码不符时，以代码为准同步修正。
