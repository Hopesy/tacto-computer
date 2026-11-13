# Fixes from Claude Code acceptance

Status: complete for the user's clarified scope, 2026-11-13. Source baseline: HEAD `86ef09e`, public package 0.4.0. The repairs were subsequently published in [0.4.1](../../histories/2026-11-13-v0.4.1.md) after the user's continuation.

The original instruction was to uninstall first and repair the observed failures. The user's latest clarification supersedes the edit/save completion criterion: test whether the product can be used, installs and uninstalls normally; Computer Use task effectiveness does not need investigation. Preserve other installations, user keys, unrelated client entries and test evidence. Windows scripts retain UTF-8 BOM and PowerShell 5.1 compatibility.

- [x] Remove the original isolated installation's runtime, task, Skill and MCP entry; retain its occupied empty root after automatic approval review rejected helper termination.
- [x] Repair PowerShell 7 → Node → Windows PowerShell 5.1 module-path inheritance and direct MCP startup environment; pass real process and configuration regressions.
- [x] Retain/resume interrupted verified downloads with bounded retries; pass simulated interruptions and a real GitHub Range download with full SHA256 validation.
- [x] Report final empty-directory occupancy as a warning after owned service/file cleanup; pass a real directory-lock regression.
- [x] Verify fresh isolated setup, CLI calls, explicit sessions, native MCP handshake/health/smoke, and actual Claude Code Skill discovery/MCP calls.
- [x] Pass focused Windows, Node and Python regressions and npm/Windows ZIP integrity checks.
- [x] Stop the effect-test Claude process after the user's clarification and close completed test terminals.
- [x] Uninstall the repaired isolated installation and independently confirm removal of its directory, Driver, task, Skill and MCP entry.

Final evidence and limitations: [repair history](../../histories/2026-11-13-acceptance-fixes.md). Current behavior: [lifecycle design](../../design/lifecycle.md). Historical intermittent observations: [issue tracker](../tech-debt-tracker.md). Detailed logs and process scripts remain under `.Tacto-temp/claude-fixes/`; original uninstall evidence remains under `.Tacto-temp/claude-desktop-20261113/`.

The original ConsoleHost exception has not recurred after the environment fix; its root cause remains unconfirmed. Original UIA/input-effect observations are retained without further investigation under the user's updated scope. No Driver version change, alternate input implementation or npm publication was performed.
