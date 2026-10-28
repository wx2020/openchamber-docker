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
- **内置 hcloud（KooCLI），跟随上游 latest 通道**（2026-10-28，PR #18 / 分支 `feat/bundle-hcloud`，commit `404d3d9`→`78b4078`→`818e730`）：Dockerfile 从华为云 OBS 的 `cli/latest` 拉 `huaweicloud-cli-linux-amd64.tar.gz` 装到 `/usr/local/bin/hcloud`。**不锁版本**（上游只提供 `/cli/latest/` 一个公开地址，写死 `7.3.12` 会让上游发新版时构建因断言变红；`/cli/<ver>/` 虽存在但不采用）。版本在构建期从 banner 解析后写入 `/home/openchamber/.hcloud-version`，CI/Release 烟测**从构建出的镜像里回读**该文件，Release notes 声明回读值并注明“跟随 latest 通道”。Android SDK 版本同理由 workflow 读 Dockerfile 的 ARG（原来 notes 里硬编码的 36.0.2/36/36 是错的，实为 `15859902`/`36.0.0`/`35`）。
  - **最大坑：首次运行隐私声明会吃掉 `--help`**。全新区块里 `hcloud --help` 只打印 Privacy Statement 一行、无 TTY 时静默退出（exit 0），根本不打版本 banner ⇒ 本机测不出（`/root/.hcloud` 早有 `agreePrivacy`）。正解 `printf 'y\n' | hcloud --help`（0.35s、无需网络），随后 `rm -rf /root/.hcloud` 防止把“已同意”写进镜像层。`hcloud version`/`--version` 都不可用（`--version` 报参数格式错误），版本只能从 `--help` 首行 banner 取。
  - **排障方法论**：CI 构建失败而本地复现不了时，直接在 Dockerfile 里临时插桩把 `which/id/HOME/stdout字节数/首行` 打到构建日志（本轮即由此定位），确认后立刻删插桩。
  - 用途：云解析 DNS（wx2020.cn 权威托管在华为云）。凭据/profile/zone 见 `homelab-docs/runbooks/huaweicloud-dns-cli.md`；运行镜像 2.5.1 尚不含 hcloud，合入并发布后由镜像提供。

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

## OpenCode 运行时与 AI 基础设施（2026-10-25 自全局记忆迁入）

### 事故取证

- **CommandCode/OpenCode 事故取证（2026-10-14 验证有效）**：会话与 goal 元数据在 `~/.local/share/opencode/opencode.db`，**2.x 用 `session_v2` + `session_message` 两张表**（不是 `message`/`part`；`session_v2.metadata` 里是 `openchamber.goal` 状态机，`session_message.data` 里是消息/错误/usage）；本容器 **python3 无 `_sqlite3`**，用 `bun -e "import {Database} from 'bun:sqlite'; const db=new Database(path,{readonly:true})"` 读；服务端日志 `~/.local/share/opencode/log/opencode.log`（`grep 'AI.Error'` / `message="Failed to drain Session"`，只有 ERROR 行，无请求体）。**判据**：`status:400` + `response.body` = provider 返回原文，`error.type` 形如 `provider.invalid-request`

### 插件体系

- **OpenCode V2 插件 API（`@opencode/plugin`）**：会话钩子名 `prompt/context/compaction/generate/title/model.request/http.request/http.response/retry`（含 `experimental.ws.*`）；`model.request` 可改 `baseURL`/`headers`，**`retry` 钩子可写 `event.decision = {retry:true, delay}` 让运行时重试**（`SessionRetryDecision`）；provider/模型注册走 `ctx.provider.transform` + `settings`。类型可直接从 CDN 取：`https://unpkg.com/@opencode/plugin@<ver>/dist/effect/{session,provider,aisdk,registration}.d.ts`。**判断某版本二进制是否支持某钩子：`grep -a -c '"retry"' <opencode 二进制>`**（本机 2.0.25 全部具备）。注意：opencode 插件**文件**（`~/.config/opencode/plugins/*.ts`）被文件监视器**热重载**，而 `node_modules` 里装好的包**不会**热重载（要重启 OpenChamber）
- **"agent 会话失败自动重试"到底在哪设（2026-10-28 在 openchamber 源码 + 已装二进制定位）**：OpenChamber UI（`packages/ui`、`packages/web/server`）**没有**"请求失败自动重发上一条 prompt"的开关；界面出现的 **`Retrying`/`SessionRetry` 提示**是**引擎（opencode）自己的会话级重试状态**，OpenChamber 只渲染：`session.status.type === 'retry'`（含 `attempt`/`next`，见 `hooks/useAssistantStatus.ts`、`sync/event-pipeline.ts`），文案在 `components/chat/ChatMessage.tsx`（`errorName === 'SessionRetry'`）。重试决策点 = **V2 插件钩子 `ctx.session.hook("retry")`**（写 `event.decision = {retry:true, delay}`；`event.error` 形态 `SessionNextRetryError{message,statusCode,isRetryable,responseHeaders,responseBody}` + `attempt`）⇒ "是否重试/几次/退避多久"由**插件**定义，本机典型即 commandcode 那套：`node_modules/opencode-commandcode/lib/retry.ts`（官方 v1.3.2+）与加载器 `plugins/commandcode.ts` 内联同一判定，环境变量 **`CMD_RETRY`(0 关) / `CMD_RETRY_MAX_ATTEMPTS`(1..5, 默认 3) / `CMD_RETRY_DELAY_MS`(0..10000, 默认 800)**，只对 `status=400 且 body 命中 invalid[ _-]?request` 生效；**429/5xx 等其它错误走引擎内建策略，无用户可配项**。别混的三处同名机制：`hooks/useQueuedMessageAutoSend.ts`（**排队消息**投递失败 2s 起指数退避、上限 60s、无次数上限）、Goal 巡检（`session-goal` 判 `blocked` 后需外部会话 `session.send goal=true` 重新装载才能续跑）
- **查插件是否真的加载：`GET /api/plugin`**（Basic auth `opencode:$OPENCODE_SERVER_PASSWORD`，端口从 opencode `serve` 的 cmdline 读，本机 34809）→ 返回全部 builtin + `source.type=local` 插件及 `state.status`。**新增一个 `plugins/*.ts` 文件也会被文件监视器接住，写完数秒内即 `active`、无需重启**（2026-10-23 验证）。`/api/plugins`、`/api/config/plugins` 均为 404，只有 `/api/plugin`
- **非 npm 源的插件（自建 Gitea 仓库）装法**：clone 到 **`~/.config/opencode/vendor/<repo>`**（在持久化卷 `.config/opencode` 内，升级不丢），再写加载器 `plugins/<name>.ts`＝`import plugin from "file:///home/openchamber/.config/opencode/vendor/<repo>/dist/index.js"` + `export default plugin`；仓库若提交了 `dist/` 就无需 `bun build`（`opencode plugin add file:...` 不被接受，`github:` spec 也不认 Gitea）。**验证插件逻辑不必等 provider 有 key**：`bun -e 'await import("./plugins/x.ts")'` 后直接调导出的纯函数（如 `keep()`），并用假 `ctx.model.transform` 记录 `remove` 调用
- **已装 OpenRouter 免费模型过滤器（2026-10-23）**：`git@git.wx2020.cn:wx2020/opencode-openrouter-free-filter.git` v1.1.0（`~/.config/opencode/vendor/`，加载器 `plugins/openrouter-free-filter.ts`，`/api/plugin` = active）。规则：保留「各档 input 全 0 + 支持 tools + context ≥256k」，另 `PINNED` 白名单保留付费 `deepseek/deepseek-v4.1-flash(-1017)`，`DENYLIST` 优先排除。**生效前提是 openrouter provider 有凭据**：本环境 `/api/integration` 里 `openrouter.connections=[]`、无 `OPENROUTER_API_KEY`、`/api/model` 无 openrouter 模型 ⇒ 现有安装处于"已加载但无模型可过滤"状态，配 key（UI 或 `POST /api/credential`）后 371→8

### 定时任务与 Goal

- **OpenChamber 定时任务可"复用已有会话"**（运行版 2.2.0 支持）：`schedule.create` 传 `targetSessionId` 后每次触发只往该会话 `enqueue` 一条 prompt（不新建会话、不刷屏），无 `model` 时 `execution.useDefaults=true`；被复用会话必须在同项目目录内。**Goal 运行时语义**（`server/lib/session-goal/runtime.js`）：`active|paused|blocked|budgetLimited|complete`，审计模型给 `continue|complete|blocked`，`blocked` 需连续 3 次；自动续跑上限 **20 turns（`MAX_AUTO_TURNS`）**；**assistant turn 报错即判 `blocked` 且不会自愈**（再发普通 prompt 不会重启 goal）；要"重新启动"必须 `session.send` 且带 `goal=true`（会**装载一个新 goal**，objective=该 prompt 文本）
- **创建 Goal 会话 / 自报身份（2026-10-18 验证）**：`openchamber` 工具 `session.create` 支持 `agent`/`model`/`goal`/`goalTokenBudget`/`prompt`，传 `agent:"build"` 即用 build agent（缺省也是 build）；**当前会话是谁**：环境变量 `OPENCODE_SESSION_ID` = 本会话 id，`session.list`（带 directory）逐条返回 `agent`/`model`/`status`/`title`，可据此核对"当前 agent"

### 配置发现与凭据

- **OpenCode 2.x 配置发现与运行时 API（2026-10-18 实测，v2.0.25）**：主配置发现（二进制内 `ConfigDiscovery`，`n$=["opencode.json","opencode.jsonc"]`）候选名**只有 `opencode.json`/`opencode.jsonc`** ⇒ 磁盘上遗留的 V1 版 `~/.config/opencode/config.json`（provider 单数键）**已不生效**：其 `bigmodel-fly97`/`cpa-mimo` 不在运行时（`GET /api/provider/<id>` 404），仅 auth.json 里 key 还在。生效 provider = `opencode.json` 的 `providers` 段（复数；V2 字段 `package`/`modelID`/`capabilities`/`variants`/`compatibility`）+ 插件注入 + 内置 integration。`disabled_providers:["x"]` 运行时被归一化为 `experimental.policies:[{action:"provider.use",resource:"x",effect:"deny"}]`（`GET /api/config` 可见）。**V2 运行时端点**（V1 的 `GET /config`、`/config/providers` 现返回 SPA HTML）：`GET /api/config`（已加载配置文档清单 + 归一化 info）、`GET /api/provider`（provider 列表：id/name/activation/package/settings）、`GET /api/provider/<id>`、`GET /api/model`；Basic auth `opencode:$OPENCODE_SERVER_PASSWORD`（从 `/proc/<opencode-pid>/environ` 读），serve 端口从 `/proc/<pid>/cmdline` 读（本次 127.0.0.1:34809）。**配置名/能力核对技巧**：把 opencode.exe 当文本，python 找 marker（如 `b'["config.json","opencode.json","opencode.jsonc"]'`）取前后 ±2KB decode 读内嵌 JS 源码——注意 `["config.json",...]` 那处是 Updater 查 `autoupdate` 用的，别误读为主配置
- **当前 provider 清单（2026-10-18，OpenCode 2.x 运行时实测）**：生效 5 个 = `commandcode`（插件 `github:wx2020/opencode-commandcode` 注入，22 模型，含本会话默认 deepseek-v4.1-flash）、`openai-fly97`（Fly97 Anthropic zcode，opencode.json 手写）、`cpa-gemini`（Google Antigravity，opencode.json 手写）、`xiaomi-token-plan-cn`（activation=auto，内置，mimo-v2.6-pro）、`opencode`（官方内置 Zen，8 个 free 模型）；`opencode-go` 被 deny 策略禁用；`cpa-mimo`/`bigmodel-fly97` 只剩 auth.json 残留（未生效）
- **OpenCode 2.x 凭据与配置热更新（2026-10-18 实测，v2.0.25）**：provider key 真源 = `opencode.db` 的 **`credential` 表**（value 为 JSON `{"type":"key","key":"…"}`；auth.json 已迁移为 legacy）。**别直接改 DB——用运行时 API**：`GET /api/credential`（列表，**返回明文 key**，勿贴出）；更新 = `POST /api/credential` `{integrationID, label:"API key", value:{type:"key",key}, activate:true}` → 新凭据即 active、同 integration 旧条自动转 inactive（`PATCH /api/credential/:id` 只改 label；`POST …/:id/activate`、`DELETE …/:id` 备用）。**opencode.json 改动会被运行时自动热重载**（实测 3s 内 `/api/provider/<id>` 即反映新 baseURL——V1 时代"外部改文件不生效"的结论在 V2 不再成立）；需强制刷新时：`POST /api/location/reload`（重建全部 location，**不中断运行中会话**、下一步边界切新服务）或 `DELETE /api/debug/location?location=<dir>`（驱逐单 location 缓存）。**provider 连通性快测**：`POST /api/experimental/generate` `{prompt, model:{id,modelID,providerID}}` → `{"data":{"text":…}}`（走完整 provider 层、不建会话）。`GET /api/session/:id/message` 的消息结构为 `{id,type,content:[…]}`（type=user/assistant/idle；assistant 内容在 `content` 数组内，无 info/parts 包装）

### Fly97 LLM 网关

- **Fly97 LLM 网关双站事实（2026-10-18 实测）**：旧站 `openai.fly97.fun:8443`（183.128.76.141，Google 证书）现役可用，`/v1/messages`+`/v1/chat/completions` 均 200，key 存于 opencode.db（provider `openai-fly97`）；**新站 `openai.fly97.cn`**（47.98.255.178 阿里云杭州，LiteSSL `*.fly97.cn` 证书 2026-10-05 签发）= Authelia SSO（`sso.fly97.cn`「飞哥的个人随想」浙ICP备2026085501号-1）+ `x-gateway-by: Traefik-Nanorouter`，Anthropic/OpenAI 双协议端点存在但**独立 key 体系**——无凭据 302 跳 SSO，带任意凭据（旧站全部 6 个 key 实测）一律 401；每个入口（openai./bigmodel.）各自独立 key。注意旧站错误 body 是 `{"error":{"message":"unauthorized"}}`、新站是 anthropic 风格 `{"error":{…"type":"authentication_error"},"type":"error"}`。**2026-10-18 已完成切换**：provider `openai-fly97` 的 baseURL 已改 `https://openai.fly97.cn/v1`（opencode.json，热重载生效）、新 key 已经 `POST /api/credential` 激活（旧凭据保留 inactive 可回退；备份 `~/.config/opencode/backups/`），端到端验证通过（`generate` + 会话路径均正常）。新站模型仅 3 个：`zcode`、`zcode/glm-5.3`、`zcode/glm-5.3-flash`（旧站列表更大）。**2026-10-22 实测：新旧两站共享同一个 5 小时用量池**——两入口（各自 key、各自域名）在同一时刻一起返回 429 `rate_limit_error` code `1308`，且**重置时刻完全相同**（新站中文文案「已达到 5 小时的使用上限…2026-10-22 21:47:54 重置」/旧站英文「Usage limit reached for 5 hour…」；时间为 UTC+8）⇒ 换域名或换 key 都拿不到第二份配额，撞限一起挂；此时 OpenCode 会把该模型标记为 `Model unavailable`（`SessionRunnerModel.ModelUnavailableError`），**限额重置后重试即自动恢复，无需改配置**（新站 key 本身有效，`/v1/models` 仍 200）

### 本容器环境事实

- **浏览器面板预览前端/mockup（本环境 `browser.capture` 不可用）**：`browser.capture` 恒失败（`UnknownVizError` 或 20s 超时，对 `example.com` 同样失败），**拿不到截图文件**，只能靠 `browser.open` + `browser.snapshot`（读可见文本/交互元素）验证。`browser.open` **只接受 http/https**（`data:text/html` 被拒），所以预览内嵌 HTML 用 `python3 -c` 起**内存态** `http.server`（HTML 内嵌在 `-c` 字符串里，不落任何文件）；首次 `browser.open` 可能报 `The browser panel is not ready`，**重试一次即成功**。收尾杀后台服务：本机**无 `pkill`/`ps`**，用 python 扫 `/proc/*/cmdline` 匹配后 `os.kill`（须排除自身 pid），且**杀掉后台 job 后当前 shell 会话会卡住/超时**——命令用 `timeout N` 包住并忽略其收尾卡顿
- **opencode 命令模板 `~/.config/opencode/command/*.md` 会把裸 `$1`..`$9` 当位置参数替换掉**（与 `$ARGUMENTS` 同机制）——脚本里**别用 perl `$1` 捕获组**（渲染后变空串、静默失败：磁盘文件看着对、实际执行不对），改用 sed 的 `\1`。2026-09-23 修 `/github-auth`（SSH remote 解析恒为空）验证有效：`sed -nE 's#\.git$##; s#/$##; s#.*github\.com[:/]([^/]+/[^/]+)$#\1#p'`，SSH/https/尾斜杠/proxy 前缀全形式均解析正确

### GitHub Actions 平台坑

- **workflow 文件里写错一个键会让整条工作流"静默消失"**（2026-10-17 本仓库实测）：`permissions:` 里出现不存在的 scope（如 `workflows: write`——GitHub 白名单里根本没有 `workflows`）会使**整个文件无效**，GitHub **不报错、不通知**，只是**不再触发它的 schedule**；无效文件触发的 run 表现为 **0 个 job**，`gh run view` 会提示 "This run likely failed because of a workflow file issue"。判"定时任务是否还活着"要看**最近一次 run 的时间**，不是历史 conclusion；**但 GitHub 的 schedule 有小时级滞后且会漂移**：本仓库 `sync-upstream` 的 cron 是 `17 5 * * *`（05:17 UTC），而实际 schedule run 稳定落在 **09:30–12:30 UTC** 并逐日推后（2026-09-15~10-09 逐条实测）⇒ 修复 workflow 后**当日 cron 点（及随后数小时）没出现 run 不等于修复失败**，判死必须先按该仓库历史落点窗口（`gh run list --workflow=<f> --limit 60 --json createdAt,event`）核对，窗口未到不能定性；本地校验用 `actionlint`（`gh api repos/rhysd/actionlint/releases/latest --jq '.assets[]|select(.name|test("linux_amd64.tar.gz$"))|.browser_download_url'` 取包，`-shellcheck=` 可只做 workflow 校验）

## Maintenance
- 每次改完代码或完成新的分析后，必须调用 `sync-agents` skill 检查并更新本文件。
- 发现本文件与代码不符时，以代码为准同步修正。
