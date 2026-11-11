# Tacto

**通用 Computer Use MCP，让 Agent 连接并操作本地或远端电脑。**

Tacto 将 Windows CUA、SSH 隧道、后台自启动和标准 MCP 配置封装成独立工具。Agent 通过 MCP 发现工具、执行操作、读取文字和图像结果，使用自己的模型完成判断。

- 受控电脑：Windows 10/11 x64，使用日常登录的桌面账户。
- Agent：支持 MCP stdio 的客户端，可运行在同一电脑、Linux VPS、容器或其他主机。
- npm CLI：Node.js 22+；Windows 安装器使用系统自带的 PowerShell 5.1。
- 远端模式：Linux VPS，已安装 Python 3 和 OpenSSH，具备 SSH 登录权限。

## 本机快速开始

在 Windows 终端执行：

```powershell
npx.cmd -y tacto-mcp@0.1.0 setup --local --unattended
npx.cmd -y tacto-mcp@0.1.0 check --unattended
npx.cmd -y tacto-mcp@0.1.0 config
```

接受 Windows 管理员权限提示后，安装器下载固定版本 CUA，验证 SHA256 和签名，并配置后台登录任务。`--unattended` 使用默认电脑名称并跳过文本输入、结束确认；系统管理员授权由 Windows 提供。

将 `config` 输出的 `mcpServers.tacto` 加入 Agent 的 MCP 设置。它指向已安装的 CUA 可执行文件和本安装的独立管道。安装器也会保存 `%LOCALAPPDATA%\Tacto\mcp-local.json`。

希望通过 npm 启动 MCP 时，可配置：

```json
{
  "mcpServers": {
    "tacto": {
      "command": "cmd",
      "args": ["/d", "/c", "npx", "-y", "tacto-mcp@0.1.0", "mcp"]
    }
  }
}
```

验证连接：

```powershell
npx.cmd -y tacto-mcp@0.1.0 probe "$env:LOCALAPPDATA\Tacto\mcp-local.json"
```

检查器执行 MCP 握手和工具发现，成功后输出服务器版本、协议版本及工具名。

## VPS 远端使用

在受控 Windows 上执行，替换为自己的 VPS 信息：

```powershell
npx.cmd -y tacto-mcp@0.1.0 setup --remote `
  --vps-host vps.example.com --vps-user deploy --device-name office-pc `
  --identity-file C:\Users\YourName\.ssh\id_ed25519
```

首次连接按 SSH 提示核对主机指纹并登录。使用密码登录时可省略 `--identity-file`。安装器配置 CUA、Windows OpenSSH、专用密钥、反向隧道和两个后台登录任务。

VPS 上的配置位于 `~/.tacto/devices/office-pc/mcp.json`，Windows 端同时保存 `%LOCALAPPDATA%\Tacto\mcp-vps.json`。将其中的配置加入 VPS 上的 Agent 即可。每台电脑使用不同名称。

也可在 VPS 直接使用 npm 入口：

```sh
npx -y tacto-mcp@0.1.0 mcp --proxy /home/deploy/.tacto/devices/office-pc/cua-proxy
```

Agent 位于另一台主机或容器时，先在该环境配置到 VPS 的 SSH 别名，再导出配置：

```sh
npx -y tacto-mcp@0.1.0 config --ssh my-vps \
  --proxy /home/deploy/.tacto/devices/office-pc/cua-proxy
```

可用 `--ssh-config /path/to/ssh_config` 指定 SSH 配置文件。代理路径属于 VPS；SSH 配置和登录密钥由运行 Agent 的机器读取。

```text
Agent → MCP stdio → VPS cua-proxy → SSH 反向通道
      → Windows OpenSSH → cua-driver mcp → 独立管道 → cua-driver serve
```

Windows 主动建立 `VPS 127.0.0.1:分配端口 → Windows 127.0.0.1:SSH端口` 的转发，断线自动重连。连接采用专用密钥、固定命令和双方主机密钥校验。

## 复制给 Agent 的安装提示词

### 本机安装

复制以下内容给有本机终端权限的 Agent：

```text
请在这台 Windows 电脑上安装 Tacto，并将它加入你的 MCP 工具配置。

官方仓库：https://github.com/Hopesy/tacto-mcp
先阅读仓库 README，按当前安装说明操作。

请完成：
1. 检查 Windows 10/11 x64、当前桌面登录账户及 Node.js 22+。缺少 Node.js 时从官方来源安装，刷新终端 PATH 后继续。
2. 执行 npx.cmd -y tacto-mcp@0.1.0 setup --local --unattended。
3. 执行 npx.cmd -y tacto-mcp@0.1.0 check --unattended。
4. 执行 npx.cmd -y tacto-mcp@0.1.0 config，保留已有 MCP 设置，新增一个 Tacto 服务。根据你所使用客户端的格式写入 command 和 args，然后重新加载工具。
5. 执行 npx.cmd -y tacto-mcp@0.1.0 probe，参数传入安装目录中的 mcp-local.json。默认路径为 %LOCALAPPDATA%\Tacto\mcp-local.json；PowerShell 中使用 $env:LOCALAPPDATA 展开路径。
6. 实际发现工具并调用 get_screen_size，汇报安装目录、MCP 配置位置、工具数量和检查结果。

我授权安装 Tacto、官方 CUA Driver 及其后台登录任务，并修改你的 MCP 配置以加入 Tacto。遇到 Windows 管理员授权时，告诉我需要完成的步骤；完成后继续。过程脚本和临时文件放在 .Tacto-temp 目录。
```

### 通过 VPS 连接 Windows

填写方括号中的信息后，交给能够访问 Windows 和 VPS 的 Agent：

```text
请安装 Tacto，让运行在 [Agent 所在位置] 的 Agent 通过 VPS 操作这台 Windows 电脑。

官方仓库：https://github.com/Hopesy/tacto-mcp
先阅读 README。连接信息：
- VPS 地址：[主机名或 IPv4]
- VPS SSH 用户：[用户名]
- VPS SSH 端口：[22]
- Windows 电脑名称：[office-pc]
- 首次 SSH 登录方式：[密钥文件路径或交互式密码登录]
- Agent 的 MCP 配置位置：[已知路径；未知时请在当前客户端中查找]

请完成：
1. 检查 Windows 10/11 x64、日常登录账户、Node.js 22+，以及 VPS 的 Python 3 和 OpenSSH。
2. 在受控 Windows 上执行 npx.cmd -y tacto-mcp@0.1.0 setup --remote，使用上面的信息填写 --vps-host、--vps-user、--vps-port、--device-name；密钥登录时加 --identity-file。
3. 完成 CUA、Windows OpenSSH、专用密钥、反向隧道和后台登录任务的配置。
4. 在 Windows 执行 npx.cmd -y tacto-mcp@0.1.0 check --unattended。
5. 读取 VPS 上 ~/.tacto/devices/[电脑名称]/mcp.json，保留原 MCP 设置并添加 Tacto。Agent 位于其他主机或容器时，使用它自己的 SSH 别名，通过 tacto-mcp config --ssh ... --proxy ... 导出连接配置。
6. 从实际运行 Agent 的环境执行 MCP 握手、工具发现和 get_screen_size，汇报结果与各端配置位置。

我授权上述安装、专用 SSH 授权、后台登录任务及 MCP 配置变更。遇到 Windows 管理员授权、SSH 首次指纹确认或登录验证时，告诉我具体需要完成的步骤；完成后继续。凭据保存在本机 SSH 配置中，过程文件放在 .Tacto-temp 目录。
```

## 日常命令

| 命令 | 用途 |
| --- | --- |
| `tacto-mcp setup --local` | 安装本机服务 |
| `tacto-mcp setup --remote ...` | 安装本机服务及 VPS 通道 |
| `tacto-mcp update --unattended` | 更新脚本和固定版本 CUA，沿用安装身份 |
| `tacto-mcp check --unattended` | 检查后台任务、CUA 和远端回连 |
| `tacto-mcp config` | 输出标准 MCP 配置 |
| `tacto-mcp config --output mcp.json` | 保存配置；覆盖已有文件时加 `--force` |
| `tacto-mcp mcp` | 以 stdio 启动 MCP，亦为默认命令 |
| `tacto-mcp probe mcp.json` | 验证 MCP 握手与工具发现 |
| `tacto-mcp uninstall --unattended` | 移除本安装创建的任务与授权，保留文件和日志 |

上述命令均可加前缀 `npx -y` 使用；Windows PowerShell 推荐使用 `npx.cmd -y`。`setup` 还支持 `--install-dir`、`--driver-path`、`--reverse-port`、`--local-ssh-port`。自定义安装目录后，检查、更新、卸载和本机 MCP 连接时传入相同的 `--install-dir`。

远端首次安装使用交互模式完成 SSH 指纹核对和登录；`--unattended` 适合已有主机密钥信任及密钥登录配置的自动化运行。电脑登录后后台启动，保持开机、联网并登录桌面即可使用。

## ZIP 与源码安装

也可下载 [GitHub 源码 ZIP](https://github.com/Hopesy/tacto-mcp/archive/refs/heads/main.zip)，解压后双击 `Install-Local.cmd` 或 `Install.cmd`。源码安装自动下载 `cua-release.json` 中固定的 CUA 版本。

开发和打包：

```sh
git clone https://github.com/Hopesy/tacto-mcp.git
cd tacto-mcp
npm run check
npm pack --pack-destination .Tacto-temp
```

Windows 下运行 `Package.ps1` 生成独立安装 ZIP、manifest 和 SHA256；`-CuaArchive` 可附带固定版本的官方原始归档。npm 包包含 CLI、脚本和文档；CUA 在执行 `setup` 时安装。测试入口位于 `.Tacto-temp/tests`，运行产物保存在 `.Tacto-temp`。

## 来源与验证

Tacto CLI 和安装脚本采用 [Apache-2.0](LICENSE)，来源说明见 [NOTICE](NOTICE)。CUA Driver 来自 [trycua/cua 官方 0.46.1 发行版](https://github.com/trycua/cua/releases/tag/cua-driver-rs-v0.46.1)，安装时验证原始归档 SHA256 和 Cua AI 数字签名。

工具清单由 CUA 实时提供，包括窗口读取、点击、输入、键盘、滚动和浏览器操作。MCP 连接遵循标准 stdio 的初始化、工具发现与调用流程。

验证结果和目标电脑验收范围见 [VERIFICATION.md](VERIFICATION.md)。
