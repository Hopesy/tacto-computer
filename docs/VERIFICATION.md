# Tacto 验证记录

验证日期：2026-11-11。接入包版本：0.1.2；固定 CUA Driver：0.46.1。

## 独立 npm 包

- `tacto-mcp` 提供 setup、update、check、uninstall、config、mcp、probe 命令；npm 包的本地安装与版本入口已实测。
- Tacto CLI 连接现有 CUA 完成真实 MCP 握手，发现 63 个工具；测试配置位于独立临时目录。
- CLI 测试覆盖参数校验、SSH 引号与路径、本机配置、已有文件保护和安装参数转发；安装器覆盖自动模式默认值和缺失参数提示。
- Windows 和 Linux CI 使用隔离测试验证安装生命周期、VPS 初始化、配置导出、MCP 分页与错误处理；正式测试位于 `tests/`，运行产物位于 `.Tacto-temp/`。

## 实际协议与进程验证

- 使用独立 Node.js 客户端连接已有本机 CUA，经 `initialize`、`notifications/initialized` 和 `tools/list` 发现 63 个工具。
- 同一客户端经 SSH → VPS → Windows 回连完成握手与工具发现；`tools/call get_screen_size` 返回文字和结构化屏幕尺寸。该路径使用已有 SSH 隧道。
- 在独立命名管道、PID 文件和临时目录下启动真实 CUA。使用本包编译的 WinExe 后台启动器启动，握手、工具发现及 `get_screen_size` 调用通过。
- 结束临时后台启动器后，其 CUA 子进程随 Windows Job Object 退出，既有 CUA 服务继续运行。
- 协商协议版本为 `2025-06-18`。工具发现检查器测试覆盖分页结果、重复游标、无效 JSON、提前退出及未知协议版本。

## 安装生命周期隔离验证

- Windows PowerShell 5.1：本机模式、远端模式分别完成安装 → 更新 → 检查 → 卸载。
- Windows 功能安装、计划任务和 VPS 请求使用隔离替身；SSH 密钥生成和 C# 后台启动器编译实际执行。
- 检查本机模式仅创建一项任务，远端模式创建两项任务；更新保留身份、管道和端口；重复授权幂等；卸载保留其他安装的授权。
- Linux/WSL 的独立临时 HOME 下验证 VPS 准备、重复准备、卸载后重新接入、设备身份冲突、端口冲突、主机密钥配置、文件权限及异常 JSON 响应。真实执行 `ssh-keygen`、`ssh -G`。
- VPS 权限测试在 Linux 文件系统的 `.Tacto-temp` 下执行；Windows 挂载目录的 POSIX 权限映射与 Linux VPS 存在差异。
- 本机、VPS、外部 SSH 三种配置导出通过；含空格和单引号的路径保持正确，已有导出文件需显式 `-Force` 覆盖。

## 打包与静态检查

- PowerShell 5.1 语法解析和 Node.js 语法检查通过。抽离前的源项目另已通过 `pnpm lint`。
- 完整 ZIP 收录固定清单的源文件与官方原始 CUA 归档，逐文件 SHA256 写入 `manifest.json`；ZIP 另附 SHA256 文件。
- 打包校验检查 manifest、文件内容、官方归档摘要及 CUA 数字签名。包内包含通用示例；安装状态和本机连接配置留在运行目录。

## 目标电脑验收

全新 Windows 上首次安装 OpenSSH、实际创建管理员计划任务，以及重启后登录恢复，仍需在目标电脑验收。安装器提供 `Check.cmd` 检查服务和远端回连。当前完成的是隔离安装流程测试、真实后台进程测试和既有 SSH 路径上的协议实测。
