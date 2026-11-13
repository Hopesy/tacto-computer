# Installation and usability fixes after Claude Code acceptance

Status: completed for the user's clarified scope and subsequently published in [0.4.1](2026-11-13-v0.4.1.md). The pre-release evidence below used baseline HEAD `86ef09e` plus the working-tree fixes and package metadata `tacto-computer@0.4.0`; official Driver remains 0.46.1.

The user first requested uninstalling the acceptance installation and repairing issues found by the tests. The final scope clarification on 2026-11-13 requires normal install/uninstall, discoverable Skill, working CLI/MCP connections and callable tools. Computer Use task effectiveness is outside this acceptance scope. The ongoing effect test was stopped, its visible test terminals closed, and the new isolated installation removed.

## Changes

- Windows PowerShell 5.1 child processes now receive the system module directory before startup. Generated local MCP configurations carry that environment; standalone setup/bridge scripts also normalize their process-local module path. A real PowerShell 7 → Node → Windows PowerShell regression reproduces the original missing-cmdlet issue and passes with the fix. Unrelated child commands retain their environment.
- Verified Driver downloads retain partial files and resume with curl HTTP Range across retries and later invocations. A server rejecting ranges receives one clean-transfer fallback; corrupted completed downloads are discarded. SHA256 promotion and Authenticode validation remain in place. Download rules live in `install/windows/Download.ps1`.
- After successful removal of owned services and files, an IO failure pruning an occupied empty installation root is reported as a warning. Earlier cleanup failures still propagate. The regression holds a real directory as the process working directory and verifies this behavior.

Current contracts: [lifecycle design](../design/lifecycle.md). Regression commands: [development guide](../DEVELOPMENT.md).

## Verified behavior

Evidence root: `.Tacto-temp/claude-fixes/`.

| Acceptance | Result and evidence |
| --- | --- |
| Fresh installation from PowerShell 7 | Passed through the corrected Node CLI, using the verified official cached 0.46.1 archive. The isolated `fixes-test` installation reached complete without a caller-side module-path workaround. `setup.log` |
| Real official HTTPS resume | Seeded the verified archive's first 32,928,231 bytes, downloaded the remainder from GitHub in 6.2947 s, and verified all 35,858,658 bytes against SHA256 `ec49cca509f25f65db2fa917718215f55f959d5ef650bf8ab2238a201d5666ac`. `resume-real.log`, `resume-real-result.json` |
| CLI usability | Real named session start, separate CLI tool calls, window discovery/read and session end succeeded. The corrected bridge processed UTF-8 JSON over stdin. `start_session.json`, `before-health.json`, `end_session.json` |
| MCP connection and tools | Real stdio negotiation used protocol `2025-06-18`, advertised 63 tools, passed all applicable health checks and returned screen size 1920 × 1080 at 1.25×. `probe-fixed.log` |
| Actual Claude Code integration | Claude Code discovered installed Skill `tacto-computer`, connected service `tacto-mcp`, started a named MCP session and successfully called native tools. `claude-fixed-events.jsonl`, session `e5f14cd7-8bcf-4aec-905e-b28c503914cd` |
| Full uninstall of the repaired test build | Exit 0; installation directory, Driver, config, scheduled task, installed Skill and owned MCP entry all absent afterward. Default `%LOCALAPPDATA%/Tacto` remains absent. `uninstall.log`, `uninstall-before.json`, `uninstall-result.json` |
| Regression and packaging | `npm run check`; all 13 Node tests; Python CLI (3 pass, 2 Unix-only skips), probe (4 pass) and bridge (2 pass); Windows CLI forwarding, Local/Remote lifecycle, exports, maintenance, downloads and Skills all passed. npm tarball and Windows ZIP integrity checks passed; changed PowerShell scripts retain BOM and CRLF. |

The original `claude-test` installation's runtime, task, Skill and MCP entry were removed first. Its root is an empty directory held by an earlier test-created helper; automated approval review rejected terminating that helper (`blocked by policy`). The empty directory was retained, with zero entries confirmed, and no alternate termination was attempted. Evidence: `.Tacto-temp/claude-desktop-20261113/uninstall*.{log,json}` and the new `uninstall-result.json`.

## Retained observations

Before scope clarification, direct CLI UIA entry and Save As produced `desktop-acceptance.txt` with matching content; evidence includes `desktop-saved.png` and `save-exact-*.json`. Intermittent UIA/capture/foreground observations remain historical evidence and are not completion requirements for this task. No Driver upgrade or alternate input implementation was introduced.

One Claude test harness passed its prompt through Windows `claude.cmd` arguments and truncated the instruction at an embedded quote. The actual Claude transcript confirmed this. A subsequent harness uses UTF-8 stdin; that expanded effect test was stopped after the user's scope clarification. Its interrupted status is not a product failure. The original ConsoleHost initialization exception did not recur in corrected CLI/MCP calls; its root cause remains unconfirmed. See the [issue tracker](../exec-plans/tech-debt-tracker.md).
