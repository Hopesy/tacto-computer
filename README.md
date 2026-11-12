# Tacto

**通用 Computer Use MCP，让 Agent 操作本地或远端 Windows 电脑。**

Tacto 负责 CUA Driver、SSH 隧道、后台启动、升级恢复和卸载。Agent 通过标准 MCP stdio 调用工具，使用自己的模型判断；随连接提供的设备 Skill 介绍目标电脑和操作方法。

当前版本 **0.2.0**。安装入口统一使用 npm/命令行。受控电脑需要 Windows 10/11 x64；npm CLI 需要 Node.js 22+。Agent 可以运行在 Windows、Linux VPS、容器或其他支持 MCP 的环境。远端 VPS 需要 Python 3 和 OpenSSH。

## 一条命令安装

在受控 Windows 上执行：

```powershell
npx.cmd -y tacto-mcp@latest setup --local --unattended
```

安装器自动下载固定版本 CUA，验证 SHA256 与 Cua AI 签名，建立独立管道和普通用户登录任务，验证实际 MCP 连接。本机新安装使用当前用户权限；后台 CUA 与隧道通过已有的隐藏启动器运行。

提供客户端的 JSON 配置和 Skill 目录，可同时完成接入：

```powershell
npx.cmd -y tacto-mcp@latest setup --local --unattended --mcp-config "C:\path\to\mcp.json" --skill-dir "C:\path\to\skills"
```

配置合并保留其他 MCP 服务；遇到同名、来源未确认的条目时会报告冲突。安装状态和导出的 `mcp-local.json`、`skill/SKILL.md` 位于 `%LOCALAPPDATA%\Tacto`。支持 `--install-dir` 指定独立目录，后续命令使用相同目录。

也可以在 Agent 中配置标准 stdio 入口：

```json
{
  "mcpServers": {
    "tacto": {
      "command": "cmd",
      "args": ["/d", "/c", "npx", "-y", "tacto-mcp@latest", "mcp"]
    }
  }
}
```

`tacto-mcp config` 可导出直接指向已安装桥接脚本的配置，后续 MCP 启动可直接使用该入口。脚本读取当前生效版本，升级后连接地址保持稳定。

## 通过 VPS 接入

在 Windows 上填写自己的 VPS 信息：

```powershell
npx.cmd -y tacto-mcp@latest setup --remote --vps-host vps.example.com --vps-user agent --device-name office-pc --identity-file "C:\Users\you\.ssh\id_ed25519"
```

远端首次安装会请求必要的 Windows 管理员权限，配置 OpenSSH、专用密钥和反向隧道。交互式安装复用原终端完成 SSH 登录与指纹核对；自动化使用已信任的主机和密钥登录，加上 `--unattended`。普通更新复用既有设备身份、端口和受限管理密钥。

在运行 Agent 的 VPS 上，将连接与设备 Skill 加入客户端：

```sh
npx -y tacto-mcp@latest connect --proxy "$HOME/.tacto/devices/office-pc/cua-proxy" --device-name office-pc --mcp-config /path/to/mcp.json --skill-dir /path/to/skills
```

`connect` 支持使用 `mcpServers` 的 JSON 配置。其他格式可使用 `config` 导出的命令和参数，由 Agent 按客户端格式合并。Agent 位于另一台主机时，增加 `--ssh <已配置的SSH别名>`，`--proxy` 填 VPS 上的绝对路径；可同时指定 `--ssh-config`。

## 更新、回滚与卸载

```powershell
# 获取最新安装逻辑并更新现有服务
npx.cmd -y tacto-mcp@latest update --unattended

# 手动恢复上一份验证成功的运行环境
npx.cmd -y tacto-mcp@latest rollback --unattended

# 完整卸载
npx.cmd -y tacto-mcp@latest uninstall --unattended
```

- **更新**：先准备并校验新版，再切换服务；连接与健康验收失败时恢复旧版。设备名、管道、VPS 信息和密钥沿用原值。中途被终止后，下次维护命令会根据事务记录恢复。
- **连接保护**：通过 Tacto 桥接入口建立的 MCP 连接存续期间，普通更新会提示关闭连接后重试；`--force` 允许立即重启。Agent 完成任务后应释放连接。
- **完整卸载**：停止本安装的连接和任务，撤销 Windows/VPS 专用授权，删除自有运行文件、下载缓存、密钥和日志，清理登记过且未被用户修改的 MCP 配置与 Skill。其他安装、外部指定的 Driver 和无关文件保留。
- **保留设置**：`uninstall --keep-config --unattended` 保留连接配置、密钥和日志，方便重新安装。
- **离线卸载**：VPS 离线时继续本机清理，输出 `%LOCALAPPDATA%\Tacto-cleanup\<安装ID>.json`。联网后，使用 VPS 原有登录身份执行 `tacto-mcp cleanup --receipt <文件> --identity-file <密钥>`，完成远端清理。
- **Agent 配置**：本机安装参数登记的配置、同一 VPS 上通过 `connect --proxy` 登记的配置随卸载清理。其他 Agent 主机可运行 `disconnect --mcp-config <文件> --device-name <电脑名>`。用户编辑过的条目和 Skill 会保留并提示。

Windows“已安装的应用”中也提供脚本卸载入口。OpenSSH 作为 Windows 共享组件保留；本安装独占且仍保持原样的服务配置会恢复。

可选空闲自动更新：

```powershell
npx.cmd -y tacto-mcp@latest update --unattended --auto-update on
# 关闭
npx.cmd -y tacto-mcp@latest update --unattended --auto-update off
```

启用后每天在已登录的用户会话中检查 GitHub 正式发行版；已有 MCP 连接时跳过。更新先验证发布包和逐文件摘要，失败保留恢复记录。结果位于安装目录的 `.Tacto-temp/updates/last-update.json`。默认关闭自动更新。

从 **0.1.x** 迁移时，旧管理员任务需要一次权限迁移；远端旧管理脚本还需要一次原始 VPS 登录。迁移成功后的普通更新使用现有受限管理连接。旧版手动配置的直接 Driver 入口，建议改用新导出的桥接入口，以启用连接保护。

## 检查与操作指引

```powershell
npx.cmd -y tacto-mcp@latest check --unattended
npx.cmd -y tacto-mcp@latest probe "$env:LOCALAPPDATA\Tacto\mcp-local.json" --health --smoke
```

检查覆盖计划任务、命名管道及实际 MCP 初始化、工具发现、`health_report`；远端模式会沿 VPS 回连再次检查。`--smoke` 额外调用只读的 `get_screen_size`。

安装和升级使用启动所需的健康检查，显式 `check`/`probe --health` 获取完整能力报告。按官方语义，核心检查失败触发故障；`degraded` 会保留失败能力和修复提示。Windows 第三方 UIA provider 的超时会如实显示。电脑需保持开机、联网并登录桌面；后台任务在登录时恢复。

设备 Skill 会：

- 绑定具体 MCP 服务和目标 Windows 平台，在 Linux Agent 上也读取 Windows 指引。
- 通过 `get_guide` 获取与实际 Driver 配套的说明，按实时工具 schema 选择参数。
- 使用 `run_steps`、`run_script` 和增量观察减少往返，在关键节点验证结果。
- 在断线后重建会话和目标，先确认上一步结果再继续。
- 明确浏览器 profile 选择，按需使用诊断录制和已发现的预览能力。`--browser-mode isolated|existing` 设置偏好，默认 `isolated`。

## 交给 Agent 自动安装的提示词

### 本机

```text
请安装并配置 Tacto，让你通过 MCP 操作这台 Windows 电脑。
仓库：https://github.com/Hopesy/tacto-mcp

先阅读 README，检查 Windows x64、Node.js 22+ 和当前登录用户。找到你使用的 MCP 配置与 Skill 目录，保留已有内容。
使用 npx.cmd -y tacto-mcp@latest setup --local --unattended；JSON 客户端可加 --mcp-config 和 --skill-dir 完成合并。其他格式按 config 导出的标准 stdio 参数合并，并安装生成的设备 Skill。
然后运行 check，并从实际 Agent 环境执行 probe --health --smoke，报告健康状态、工具数量和配置位置。
后续升级、卸载也使用 tacto-mcp@latest。遇到能力降级时报告具体检查与提示。

我授权安装 Tacto、官方 CUA Driver、后台登录任务及对应 MCP/Skill 配置。过程文件放在 .Tacto-temp 目录。
```

### 经 VPS 连接

```text
请安装 Tacto，让运行在 [Agent 所在位置] 的 Agent 操作这台 Windows 电脑。
仓库：https://github.com/Hopesy/tacto-mcp

连接信息：VPS [主机名或IPv4]，SSH 用户 [用户名]，端口 [22]，电脑名称 [office-pc]，SSH 登录密钥 [路径；或交互式登录]。
先阅读 README，检查 Windows x64、Node.js 22+、VPS Python 3 和 OpenSSH。
在 Windows 使用 npx.cmd -y tacto-mcp@latest setup --remote，填入上述连接参数；已有密钥和主机信任时加 --unattended。
在 Agent 环境通过 connect 配置对应设备 MCP 和 Skill；若使用其他格式的配置，按标准 stdio 参数合并。保留已有客户端设置。
沿实际 VPS→Windows 路径完成 MCP 握手、工具发现、health_report 和 get_screen_size，并汇报结果。

我授权上述安装、专用 SSH 授权、后台登录任务和对应 MCP/Skill 配置。Windows 授权或 SSH 登录验证由我完成后继续。临时文件放在 .Tacto-temp，凭据保留在 SSH 配置中。
```

## 源码、打包与验证

源码安装入口位于 `install/windows/`。现有 `.cmd` 文件供手动终端操作使用；运行脚本使用系统 PowerShell 5.1。`scripts/Package.ps1` 生成 ZIP 和 SHA256，可选附带经过校验的官方 CUA 归档。npm 包在 `setup` 时下载 Driver。

目录按职责组织：`src/` 为 CLI 和协议检查，`install/` 为 Windows/VPS 生命周期，`resources/` 为 Driver 校验信息和 Skill 模板，`tests/` 为回归测试，`.Tacto-temp/` 为 Git 忽略的过程产物。

开发与测试命令见[开发说明](docs/DEVELOPMENT.md)，实际结果见[验证记录](docs/VERIFICATION.md)，生命周期设计见[架构](docs/ARCHITECTURE.md)。

Tacto 采用 [Apache-2.0](LICENSE)，来源说明见 [NOTICE](NOTICE)。固定 Driver 来自 [CUA 官方 0.46.1 发行版](https://github.com/trycua/cua/releases/tag/cua-driver-rs-v0.46.1)；操作指导依据 [CUA Driver 文档](https://cua.ai/docs/cua-driver)。
