---
name: tacto-{{DEVICE}}
description: Operate the Windows desktop {{DEVICE}} through the {{SERVER}} MCP server for desktop application and browser tasks.
---

# Tacto: {{DEVICE}}

Use MCP server `{{SERVER}}`. The controlled platform is **Windows**, including when this Agent runs on Linux or macOS. Browser preference: **{{BROWSER}}**.

At the first connection, discover the live tools and call `health_report`. Read the Windows and workflow guidance through this server's `get_guide` using its advertised schema. These guides travel with the installed Driver; use their version and live tool schemas when choosing parameters. Report failed session, UIA or capture checks with their remediation hints.

Use exact window/process targets. Prefer structured application or browser observations; use screenshots for visual questions. Carry forward the latest state revision and request incremental `get_window_state` observations (`since`, `query`, tree/image limits) where the live schema supports them. After restart or stale-target errors, obtain fresh state.

Batch known actions with `run_steps`, using available `wait_for`, `expect` and observation options at meaningful checkpoints. Use `run_script` for supported conditional flows. Verify the resulting UI or saved artifact before reporting success. Keep uncertain, externally consequential decisions with the Agent and its current user authorization.

Keep one MCP connection for a task. After disconnect, recreate the session and targets, observe the previous action's result, and resume from the confirmed state. Session expiry invalidates element tokens and browser refs. Coordinate a single active operator per device; a named session groups work but does not by itself provide an exclusive device lock. Close the connection at the end so idle maintenance can proceed.

For web tasks, read the target Driver's browser guide. Bind browser tools to the exact native window, target and tab. With `isolated` preference, create a session-owned profile; with `existing`, use the selected existing browser/profile after checking its current state. Inspect upload, download and dialog results. Close only resources created for the task, using the supported session/resource lifecycle tools.

For reproducible failures, offer a scoped diagnostic recording and use the live recording schema if available. Keep recordings local to the chosen task directory and close the recording session after collecting evidence. Discover Computer History and visual-region capabilities before using these preview features; follow their current guide and user-selected settings.

Installation and updates are managed by Tacto. `check` verifies the desktop over MCP; `update` preserves device identity and rolls back failed activation; `rollback` restores the previous verified runtime. Re-read live guidance after a version change. Windows login supplies the interactive desktop used by the daemon.
