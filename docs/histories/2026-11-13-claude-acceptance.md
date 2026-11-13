# Claude Code 安装与桌面功能实测

后续：用户明确将验收范围收敛为安装、卸载、接入与工具可调用；相关修复和最终结果见 [安装与可用性修复](2026-11-13-acceptance-fixes.md)。以下保留原始实测事实。

2026-11-13，用户要求从桌面 Claude Code 测试安装及功能。Computer Use 工具阻止 PowerShell 启动后，用户明确选择通过正常终端工具启动可见 Claude Code。使用真实 Claude Code 2.1.323、公开 `tacto-computer@latest`（0.4.0）和独立目录 `.Tacto-temp/claude-desktop-20261113` 执行；源码版本为 `baeda66`，运行时代码保持原样。

**结果：部分通过。** 安装通过后备路径完成，CLI/MCP 接入、会话和截图可用；记事本输入与保存验收失败。

| 场景 | 实测结果 |
| --- | --- |
| 默认在线安装 | 三次 Driver 下载重试后超时，371.01 秒，最后一次下载到 32,928,231 / 35,858,658 字节 |
| 已校验官方归档后备 | SHA256 与公开发行元数据一致；随后遇到子 PowerShell 的 `Get-FileHash` 缺失 |
| 测试进程模块路径调整 | 将 PSModulePath 指向系统 Windows PowerShell 5.1 模块后，18.79 秒安装完成；摘要和 Authenticode 校验正常 |
| Skill/MCP 配置 | 一份 `tacto-computer` Skill，树内一个 SKILL.md；MCP 名称 `tacto-mcp`；接续后的 Claude 自动发现 Skill 并连接 MCP |
| CLI 读取/会话 | 63 个工具、1920×1080 / 1.25×；独立 CLI 调用共享命名会话，end_session 生效 |
| MCP | probe 握手/健康/smoke 通过；Claude 实际原生 MCP 工具返回活动 `mcp_stdio` 会话、窗口列表和截图 |
| 完整健康检查 | `degraded`：UIA provider 超时；系统、活动会话和截图检查通过 |
| CLI GUI 输入 | PowerShell ConsoleHost 类型初始化异常，退出 -65536；前一 Claude 进程随后退出，原因尚未定位 |
| 原生 MCP GUI 输入 | 后台 PostMessage 返回未验证效果，截图仍为 0 字符；前台重试返回 `foreground_unavailable` |
| 保存结果 | 输入失败后停止，Save As 未执行；`desktop-acceptance.txt` 未生成，测试原文件为 0 字节 |

应用启动还观察到返回 PID 与最终记事本窗口 PID 不同、窗口发现延迟。Claude 最终按专用测试标题重新定位 HWND 后操作，保留用户原有文档。首次批量 MCP 调用存在 `target` 与继承 PID/HWND 参数冲突，修正为独立调用后仍得到上述 UIA/输入失败；该参数错误与最终输入故障分别记录。

控制侧曾通过 Computer Use 将专用空白记事本窗口置前并观察；文字输入与保存尝试均由 Claude 使用 Tacto 执行。最终 Tacto 截图和独立文件检查确认文档仍为空白，未以工具返回成功替代实际编辑结果。

完整报告：`.Tacto-temp/claude-desktop-20261113/REPORT.md`。主要证据：`setup.log`、`setup-fallback.log`、`setup-fallback-winps.log`、`mcp-probe.log`、`session-*.log`、`ui-mcp-results.log`、`mcp-notepad-final-unsaved.png`；原始会话：`claude-events.jsonl` 和 `claude-mcp-events.jsonl`。测试安装和普通用户计划任务保留供复测；原生 MCP 会话已释放，CLI 连续性会话已结束，早期 UI CLI 租约已自然过期。默认 `%LOCALAPPDATA%\Tacto` 安装仍不存在。

后续缺陷见[跟踪表](../exec-plans/tech-debt-tracker.md)。本轮完成实测与报告，产品修复另行推进。
