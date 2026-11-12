# Tacto 验证记录

验证日期：2026-11-12。接入包版本：0.2.0；固定 CUA Driver：0.46.1。

## 自动回归

- Windows PowerShell 5.1 与 Node.js 语法检查；CLI 参数、SSH 引号、带空格路径和 npm 子进程环境隔离。
- MCP 分页、无效响应、提前退出、协议版本，以及健康报告的文本回退、能力降级、核心故障和目标平台校验。
- 本机与远端安装、版本暂存、故障恢复、事务中断恢复、手动回滚、旧版任务快照恢复、活动连接保护、保留配置重装、完整卸载和 VPS 离线清理凭据。
- 自动更新任务启用/关闭、活动连接期间延后；专有 SSH 配置恢复与重装、用户修改保护。
- 实际编译 C# MCP 替身，验证桥接脚本连续收发、维护门禁与连接租约清理。实际生成 SSH 密钥和编译原有隐藏后台启动器。
- JSON 客户端配置合并、Skill 更新、异常回退、编辑内容保护、VPS 端清理登记，以及压缩 SSH 初始化代码的完整性和长度。
- Linux/WSL 在临时 HOME 中运行 VPS 初始化、身份与端口冲突、重复卸载、Skill 同步、客户端清理、健康检查流式协议。实际执行 `ssh-keygen` 与 `ssh -G`。

## 真实 Windows 验收

在独立安装目录、设备身份、管道和计划任务中，使用真实官方 CUA Driver 执行：

- 本机安装、更新、损坏 Driver 故障注入及自动恢复、手动回滚、任务停止后重新启动。
- 通过稳定桥接入口完成 MCP 初始化、工具发现、`health_report` 和只读 `get_screen_size`；发现 **63 个工具**，屏幕尺寸为 **1920×1080**、缩放 **1.25**。
- 验证普通用户任务权限、后台启动器的 Windows GUI 子系统与空窗口句柄；验证保留配置卸载、重装、完整卸载和重复卸载。
- 验证客户端其他条目和用户文件保留，已登记 Skill、任务、密钥及“已安装的应用”记录清理；外部指定的 Driver 保留。
- 默认下载路径实际下载官方归档、核对 SHA256 与 Cua AI 签名；下载使用有超时的系统 curl，下载中断时保留有界重试。

测试脚本为 `tests/test-native-lifecycle.ps1`，过程证据位于 `.Tacto-temp/native-*`。省略 `-DriverPath` 可验证默认下载及自有 Driver 清理；指定该参数可验证外部 Driver 保留。

## 健康报告与环境因素

完整报告曾返回 `ok`，也观察到第三方 Windows UIA provider 能力降级及诊断超时。安装/更新使用 binary、platform、session、screen capture 的启动检查；显式 `check` 与 `probe --health` 获取完整报告，保留故障与修复提示。超时会返回失败，后续可根据环境状态重新诊断。

任务启动等待与 MCP 健康验收分别处理；有界重试后仍失败会触发旧版恢复。卸载对 Windows 进程退出后短暂保留的文件句柄做有界重试。

## 打包与 CI

`tests/verify-package.py` 验证 npm/ZIP 必要文件、npm 内容与源码一致、ZIP manifest 的逐文件摘要，以及解压到带空格目录后的 CLI 入口。发行形态为 npm 包及源码 ZIP；ZIP 可选附带官方原始 CUA 归档。

[GitHub Actions](https://github.com/Hopesy/tacto-mcp/actions/workflows/ci.yml) 在 Windows 与 Linux 上运行回归。真实桌面测试作为发布前本机验收，CI 使用隔离的系统边界和实际流式 MCP 替身。

## 部署验收范围

本次实测覆盖已登录 Windows 的本机生命周期与任务重启。全新 Windows 首次安装 OpenSSH、提权后的 SSH 密码登录、真实 VPS 首次部署和整机重启登录仍需在目标电脑验收。此前 0.1.2 已验证过现有 SSH 隧道上的 VPS → Windows MCP 握手及屏幕尺寸调用；0.2.0 的 VPS 生命周期与清理行为已在 Linux 隔离环境回归。

## 0.3.0 CLI 与官方 Skill

原生 CLI 跨进程命名会话、维护保护和完整 Windows 生命周期验收通过；整套 Skill 的迁移、回滚、编辑保留及 UTF-8 大包传输回归通过。证据与发布状态见 [0.3.0 记录](histories/2026-11-12-v0.3.0.md)。
