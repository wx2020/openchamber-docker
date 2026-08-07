# Security policy

请不要在公开 issue、Pull Request、README、Compose 文件或日志中提交以下内容：

- `OPENCHAMBER_UI_PASSWORD`
- Cloudflare tunnel token
- OpenCode provider key、GitHub token 或其他 API key
- SSH 私钥和包含敏感信息的配置文件

如果问题只影响本仓库的 Dockerfile、Compose 或 GitHub Actions，请通过 GitHub 的私密漏洞报告功能联系维护者，并提供复现步骤、受影响的版本和最小必要日志。不要在报告中粘贴真实凭据。

如果问题来自 OpenChamber 本身，请同时参考上游项目的安全政策：[openchamber/openchamber](https://github.com/openchamber/openchamber)。

部署者仍需自行负责 UI 密码、SSH 密钥、provider 凭据、网络暴露范围和持久化数据备份。
