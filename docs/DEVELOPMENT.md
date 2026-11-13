# 开发与验证

从仓库根目录执行命令。运行 CLI 和检查器需要 Node.js 22+；测试需要 Python 3。Windows 安装测试使用 PowerShell 5.1、OpenSSH Client 和系统 C# 编译器。

## 模块与运行目录

| 目录 | 职责 |
| --- | --- |
| `bin/` | npm 可执行入口，加载 `src/cli.mjs` |
| `src/` | 参数处理、MCP 连接与协议检查 |
| `install/windows/` | Windows 安装和维护入口、后台启动器、SSH 回连脚本 |
| `install/linux/` | VPS 用户目录、SSH 授权和代理配置 |
| `resources/` | CUA 版本、下载地址与 SHA256 |
| `scripts/` | ZIP 打包工具 |
| `tests/` | 可重复运行的回归测试 |
| `.Tacto-temp/` | 临时过程脚本、隔离测试目录、日志、npm 缓存和安装包 |

用户运行状态位于 `%LOCALAPPDATA%\Tacto` 和 VPS 的 `~/.tacto`。目录调整只影响源码和安装包布局，运行时仍沿用这些路径。

## 通用检查

修改上游 Skill 资源后，运行 `npm run build:skills`，由单一转换脚本更新 `install/skill-references.json`。原始发布包文件保存在 `resources/cua-skill/`；Windows 安装器与 Node CLI 共用生成的参考文档。`npm run check`、npm 打包和 ZIP 打包都会核对生成结果与来源一致。

```sh
npm run check
node bin/tacto.mjs --help
python tests/test-cli.py
python tests/test-probe.py
node --test tests/*.test.mjs
```

## Windows 安装流程

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-cli-forwarding.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-lifecycle.ps1 -TestMode Local
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-lifecycle.ps1 -TestMode Remote
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-exports.ps1
python tests/test-bridge.py
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-maintenance.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-skills.ps1
```

安装测试为系统功能、计划任务和 VPS 通信提供隔离替身，实际执行密钥生成和后台启动器编译。CLI 转发测试通过进程替身检查安装入口和参数。目标电脑的首次安装与重启验收见 [验证记录](VERIFICATION.md)。

## Linux VPS 流程

```sh
python3 tests/test-vps.py
```

测试使用独立临时 HOME，实际执行 `ssh-keygen` 和 `ssh -G`。文件权限测试目录位于 Linux 文件系统的 `.Tacto-temp` 中。

## 打包

正式 npm 发布工作流位于 `.github/workflows/publish.yml`，复用 Windows/Linux CI，通过 npm Trusted Publisher 直接发布。首次包初始化与信任绑定、后续发布触发方式见[发布说明](design/npm-publishing.md)。

运行测试会创建 `.Tacto-temp`。也可先手动创建该目录，再打包 npm：

```sh
node -e "require('node:fs').mkdirSync('.Tacto-temp',{recursive:true})"
npm pack --pack-destination .Tacto-temp
python tests/verify-package.py .Tacto-temp/tacto-computer-0.4.0.tgz
```

生成 Windows ZIP：

```powershell
./scripts/Package.ps1
python tests/verify-package.py .Tacto-temp/packages/Tacto-0.4.0.zip
```

`Package.ps1 -CuaArchive <官方压缩包路径>` 将校验通过的原始 CUA 归档放入 ZIP 的 `vendor/`。打包程序保留源码目录结构；解压后的双击安装入口位于 `install/windows/`。

npm 与 ZIP 均包含运行代码、安装资源和文档。正式测试、CI 配置及 `.Tacto-temp` 运行产物保留在开发环境。

## 真实 Windows 生命周期

在已登录的测试桌面使用现有官方 Driver，测试创建独立任务、管道与目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-native-lifecycle.ps1 -DriverPath C:\path\to\cua-driver.exe
```

覆盖安装、更新、坏版本故障注入、自动恢复、手动回滚、任务重启、保留配置卸载、重装和完整卸载。该测试需要真实交互桌面，作为发布前验收；CI 使用隔离系统边界的生命周期测试及真实流式 MCP 桥接测试。产物位于 `.Tacto-temp/native-*`。

省略 `-DriverPath` 会实际下载、校验官方 Driver，并验证自有 Driver 随完整卸载清理。完整健康报告包含 Windows UIA provider，环境异常会输出具体故障或超时；启动验收另有有界健康重试。

npm 安装入口保持命令行形态；后台沿用 windowless launcher，发行包提供 npm 与源码 ZIP。
