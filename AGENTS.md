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

## Release Pipeline Incidents

### 2026-10-11 起同步停摆：workflow 文件里的非法 permission scope（已修）

- 现象：`official-stable` 停在 2.2.0，上游已 2.4.0；`sync-upstream.yml` 的每日 schedule **自 2026-10-11 起一次都没跑**（仓库内任何 workflow 在 10-10 09:33 之后都没有运行）。
- 根因：`permissions:` 里写了 `workflows: write`。**GitHub 的 permission 白名单里没有 `workflows`**，这个键会让**整个 workflow 文件无效**，而 GitHub 既不报错也不运行——只是**静默地不再触发它的 schedule**。该键由 #14 引入（想给 `GITHUB_TOKEN` workflow 权限），#15/#16 只改周边 PAT 逻辑、没删掉它，于是残留。
- 指纹：无效 workflow 的 run 会以 **0 个 job** 出现，`gh run view` 提示 "This run likely failed because of a workflow file issue"；`actionlint` 直接报 `unknown permission scope "workflows"`（合法集合只有 actions / artifact-metadata / attestations / checks / contents / deployments / discussions / id-token / issues / models / packages / pages / pull-requests / repository-projects / security-events / statuses）。
- 修复（PR #17）：删掉该键；CI 新增 `Lint workflow files`（actionlint）；`sync` 在 push 前检查 merge 是否改动 `.github/workflows`，若有则以清晰错误退出（`GITHUB_TOKEN` 无法 push workflow 文件）。
- 教训：**workflow 里写错一个键，整条链路会静默消失**——判断同步是否活着要看**最近一次 run 的时间**，不能只看历史 conclusion；本地 `actionlint` 一秒可查。

### 2026-09-24 起镜像停更：deps 阶段硬编码 workspace 列表（已修）

- 上游 v2.0.0 起往 `packages/sdk/examples/*` 新增包，deps 阶段硬编码 COPY 的 `package.json` 缺了它们 → `bun install --frozen-lockfile` 报 `lockfile had changes, but lockfile is frozen` → 镜像构建全部失败，GHCR 停在 1.24.2 共 8 天。
- 修复：deps 阶段改为 `COPY --from=source /src/packages ./packages` 整树拷贝，workspace 集合永远与 `bun.lock` 一致，上游加包自动兼容。
- 教训：对上游 monorepo 别按清单 COPY；`--frozen-lockfile` 报 lockfile 有变化时先怀疑 workspace 集合变化，而不是依赖版本变了。

## 同步看门狗（本机 OpenChamber 定时任务）

- 任务名 `openchamber-docker 同步看门狗`（id `9a02684b-4e36-4526-9ef2-ed42493c2232`），cron `0 */6 * * *`（Asia/Shanghai），模型 `bigmodel-fly97/glm-5.3-flash`，工作目录即本仓库。
- 作用：对比上游 latest 与 `official-stable` 的 VERSION；落后时先 `actionlint` 体检 workflow 文件与两分支一致性，再 `gh workflow run sync-upstream.yml --ref main` 自愈，并报告 run 结果（失败则附日志关键词）。
- 存在的理由：GitHub 的 schedule 静默失效时，仓库内部一切看起来都正常（历史 run 全是 success），只有**外部观察者**能发现。

## 运维事实（本容器）

- 推送本仓库走 HTTPS+PAT：`export GH_TOKEN="$(gh auth token)"`（gh 已登录 wx2020，scopes 含 `repo`/`workflow`）→ `git push "https://x-access-token:${GH_TOKEN}@github.com/wx2020/openchamber-docker.git" <src>:<dst>`；容器出网 22 端口被墙，SSH 到 github.com 不通。
- **`main` 受保护**：只能走 PR，且要求 `test` 检查通过（`enforce_admins=true`、required approvals = 0，自己可合并）；`official-stable` 不受保护，sync / manual-release 可直接推。
- 失败 run 的日志 zip 需认证：`curl -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/repos/<o>/<r>/actions/runs/<id>/logs` → python `zipfile` 解（容器无 unzip）。
- 本机 `actionlint`：`/tmp/opencode/alint/actionlint`（`-shellcheck=` 只做 workflow 校验，避免内联脚本风格问题误伤）。
- **只有 `.github/workflows/*` 必须两分支逐字节一致**（`GITHUB_TOKEN` 推不动 workflow 文件的任何变动）；其它文件**允许**不同。典型例子：`main` 的 `VERSION` 停在 `1.20.0`、其 `Dockerfile` 是 1.x 基线（CI 就是拿 main 的 VERSION 去构建镜像做烟测），而 `official-stable` 的 `Dockerfile` 才带 2.x 所需的 `packages/sdk` 构建与运行时资产。**别把 official-stable 的 Dockerfile 搬到 main**：CI 会用 1.20.0 构建它，`packages/sdk` 在 v1.20.0 里不存在，build 阶段直接崩（2026-10-17 PR #17 首轮 CI 即因此变红，已回退）。
- **升级镜像前必须保留的持久化卷**（compose 映射）：`.config/openchamber`、`.config/opencode`、`.local/state|share/opencode`（`opencode.db` + `auth.json`）、`.ssh`、`.config/gh`、`.config/tea`、`.gitconfig`（文件 bind，宿主源须先 `touch`）、`workspaces`。卷源**不得嵌套**在另一卷源目录树内，否则同一份数据被双挂载（清空父目录会连带删掉子卷）。

## Maintenance
- 每次改完代码或完成新的分析后，必须调用 `sync-agents` skill 检查并更新本文件。
- 发现本文件与代码不符时，以代码为准同步修正。
