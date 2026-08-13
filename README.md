# OpenChamber Docker

[![CI](https://github.com/wx2020/openchamber-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/wx2020/openchamber-docker/actions/workflows/ci.yml)
[![GHCR](https://img.shields.io/badge/GHCR-available-2496ED?logo=docker&logoColor=white)](https://github.com/wx2020/openchamber-docker/pkgs/container/openchamber-docker)
[![Upstream](https://img.shields.io/badge/upstream-openchamber-66800B)](https://github.com/openchamber/openchamber)

一个面向 Docker 的 [OpenChamber](https://github.com/openchamber/openchamber) 发布包装仓库。镜像构建时从上游 OpenChamber 仓库拉取指定版本，经过 GitHub Actions 构建后只发布到 GitHub Container Registry（GHCR）。

> 本项目不是 OpenChamber 上游代码的分叉。OpenChamber 的功能、许可证和运行行为由上游项目决定；本仓库负责 Docker 镜像、Compose 配置和 GHCR 发布流程。

## 当前支持范围

| 项目 | 当前值 |
| --- | --- |
| 镜像 | ghcr.io/wx2020/openchamber-docker |
| 当前 OpenChamber 版本 | 1.18.1 |
| 发布架构 | linux/amd64（x86_64） |
| 服务端口 | 3000 |
| 默认镜像标签 | latest |
| 运行方式 | Docker Engine + Docker Compose v2 |

当前没有发布 arm64 或其他架构的镜像。ARM 设备即使配置了 QEMU 模拟，也不属于本项目当前承诺的支持范围。

## 快速开始

### 1. 准备目录和配置

~~~bash
git clone https://github.com/wx2020/openchamber-docker.git
cd openchamber-docker
cp .env.example .env
~~~

编辑 .env，至少设置一个足够长且唯一的 UI 密码：

~~~dotenv
OPENCHAMBER_UI_PASSWORD=请替换成高强度随机密码
~~~

Linux/macOS 可以直接生成密码：

~~~bash
openssl rand -base64 32
~~~

PowerShell 可以使用：

~~~powershell
[Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Maximum 256 }))
~~~

.env 只用于本机配置，已被 .gitignore 忽略；不要把密码或 Cloudflare token 提交到 Git。

### 2. 拉取并启动

~~~bash
docker compose pull
docker compose up -d
docker compose logs -f openchamber
~~~

浏览器打开 http://127.0.0.1:3000，使用 .env 中的密码登录。

停止服务但保留数据：

~~~bash
docker compose down
~~~

### 3. Windows PowerShell

~~~powershell
git clone https://github.com/wx2020/openchamber-docker.git
Set-Location openchamber-docker
Copy-Item .env.example .env
notepad .env
docker compose pull
docker compose up -d
~~~

Docker Desktop 需要启用 Linux containers。首次启动前请确认 Docker Desktop 分配了足够的 CPU、内存和磁盘空间，因为 OpenChamber 镜像包含 Bun、Node.js、OpenCode CLI 以及 Web 构建产物。

## 版本和镜像标签

每个上游版本对应一个本仓库版本。当前版本由根目录的 VERSION 文件声明，为 1.18.1。发布 v1.18.1 时，Actions 会生成以下 GHCR 标签：

~~~text
ghcr.io/wx2020/openchamber-docker:1.18.1
ghcr.io/wx2020/openchamber-docker:1.18
ghcr.io/wx2020/openchamber-docker:1
ghcr.io/wx2020/openchamber-docker:latest
~~~

生产环境建议固定完整版本，而不是使用会随发布变化的 latest：

~~~dotenv
OPENCHAMBER_IMAGE=ghcr.io/wx2020/openchamber-docker:1.18.1
~~~

更新版本时，修改 .env 后执行：

~~~bash
docker compose pull
docker compose up -d
~~~

配置和工作区都在宿主机挂载目录中，更新镜像不会删除这些数据。升级前仍建议备份 data/。

## 数据目录和权限

Compose 会把以下目录挂载到容器。不要把这些目录加入 Git：

| 宿主机目录 | 容器目录 | 内容 |
| --- | --- | --- |
| data/openchamber | /home/openchamber/.config/openchamber | OpenChamber 配置、登录和应用状态 |
| data/opencode/share | /home/openchamber/.local/share/opencode | OpenCode 持久化数据 |
| data/opencode/state | /home/openchamber/.local/state/opencode | OpenCode 运行状态 |
| data/opencode/config | /home/openchamber/.config/opencode | OpenCode 配置和 provider 设置 |
| data/ssh | /home/openchamber/.ssh | SSH 密钥和 known_hosts |
| workspaces | /home/openchamber/workspaces | 供 OpenChamber 使用的项目目录 |

镜像中的进程使用 UID/GID 1000:1000。Linux 主机如果遇到写入权限错误，可以先执行：

~~~bash
mkdir -p data/openchamber data/opencode/{share,state,config} data/ssh workspaces
sudo chown -R 1000:1000 data workspaces
~~~

只把确实需要使用的项目放入 workspaces。挂载 SSH 目录前请确认宿主机上的密钥权限符合 SSH 要求，并注意容器内的 OpenChamber 将可以使用这些凭据。

## 可选配置

### 连接宿主机上的 OpenCode 服务

复制 docker-compose.override.example.yml：

~~~bash
cp docker-compose.override.example.yml docker-compose.override.yml
~~~

示例会让 OpenChamber 使用宿主机上的 http://host.docker.internal:4096，并跳过容器内 OpenCode 的启动。也可以直接在 override 文件里修改地址。

### Cloudflare Tunnel

上游支持 quick、managed-remote 和 managed-local 三种 Cloudflare tunnel 模式。请根据上游文档配置 OPENCHAMBER_TUNNEL_PROVIDER、OPENCHAMBER_TUNNEL_MODE 等变量；managed-remote 模式还需要 hostname 和 token。

不要把 tunnel token 放进公开仓库。建议仅保存在本机 .env 或部署平台的 secret 中。将服务暴露到公网时，必须保留 OPENCHAMBER_UI_PASSWORD，并额外配置 HTTPS、访问控制和备份策略。

### 启用 oh-my-opencode

在 docker-compose.override.yml 中加入：

~~~yaml
services:
  openchamber:
    environment:
      OH_MY_OPENCODE: "true"
~~~

上游环境变量的完整说明请以 [OpenChamber 上游文档](https://github.com/openchamber/openchamber) 为准。

## 从源码构建

正常使用不需要本地构建。需要验证某个上游分支或提交时，可以使用 Docker Buildx；构建目标必须明确为 linux/amd64：

~~~bash
docker buildx build \
  --platform linux/amd64 \
  --build-arg OPENCHAMBER_REF=v1.18.1 \
  --build-arg OPENCHAMBER_VERSION=1.18.1 \
  --tag ghcr.io/wx2020/openchamber-docker:local \
  --load .
~~~

OPENCHAMBER_REF 可以是上游 Git tag 或分支名。正式发布使用与 VERSION 相同的上游版本 tag，以保证发布版本可复现。构建过程中会下载上游源代码和依赖，首次构建可能需要较长时间。

## GitHub Actions 发布流程

工作流位于 .github/workflows：

1. Pull request、v* tag 或手动执行 CI 时运行 test。
2. test 校验版本文件、Compose 配置，并构建 linux/amd64 镜像进行基础烟测。
3. v* tag 触发且 test 成功后进入可复用的 Release workflow；上游自动同步则通过 workflow_dispatch 启动同一发布流程。
4. Release workflow 再次验证 tag 与 VERSION 一致，构建并推送 GHCR 镜像，然后创建 GitHub Release。
5. 镜像只推送到 ghcr.io/wx2020/openchamber-docker，不会发布到 Docker Hub。

上游稳定版本同步工作流每天 UTC 05:17 检查 OpenChamber 最新稳定 Release。发现比 `official-stable` 分支中的 VERSION 更新的三段式版本时，工作流会以最新 `main` 为基础重建 `official-stable`，写入新的 VERSION，再以该分支启动 Release workflow 构建并推送 GHCR 镜像；不会直接写入受保护的 `main`。因此 Dockerfile、Compose 和工作流修复会随下一次上游版本同步进入发布分支。没有新版本时不会产生提交或构建。也可以在 Actions 中手动运行 Sync upstream release。

发布新版本的维护者流程：

~~~bash
# 先把 VERSION 改成已验证的上游版本，例如 1.18.2
git add VERSION
git commit -m "chore: release OpenChamber 1.18.2"
git tag -a v1.18.2 -m "Release v1.18.2"
git push origin main
git push origin v1.18.2
~~~

仓库保护规则应要求通过 Pull Request 合并功能和工作流修改；版本 tag 只应指向 main 上已经测试通过的提交。

## 常见问题

### OPENCHAMBER_UI_PASSWORD 未设置

Compose 会故意拒绝在没有密码时启动，因为 Docker 会把服务绑定到可映射的 0.0.0.0。确认当前目录存在 .env，且其中包含非空的 OPENCHAMBER_UI_PASSWORD。

### no matching manifest for linux/arm64

这是预期结果：当前 GHCR 只提供 linux/amd64。请在 amd64/x86_64 主机上运行，或等待本项目明确发布 ARM64 支持。

### 容器启动后无法写入工作区

确认宿主机目录存在，并检查其所有者是否允许 UID/GID 1000:1000 写入：

~~~bash
sudo chown -R 1000:1000 data workspaces
~~~

### GHCR 拉取权限错误

公开包可以直接拉取；私有包需要先登录：

~~~bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u YOUR_GITHUB_USER --password-stdin
~~~

不要在 shell 历史、日志或仓库文件中暴露 token。

## 上游、许可证和责任范围

- 上游项目：[openchamber/openchamber](https://github.com/openchamber/openchamber)
- 上游 Compose 参考：[docker-compose.yml](https://github.com/openchamber/openchamber/blob/main/docker-compose.yml)
- 上游许可证：MIT；请以其仓库中的许可证为准。
- 本包装仓库许可证：见 LICENSE。

本仓库不改变 OpenChamber 的账号、provider、SSH 或工作区安全边界。部署者需要自行负责密码、token、SSH 密钥、网络暴露、数据备份和运行环境安全。
