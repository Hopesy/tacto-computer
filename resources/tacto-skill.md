---
name: {{SKILL}}
description: Operate the Windows computer {{DEVICE}} through Tacto CLI or the {{SERVER}} MCP server for desktop application and browser tasks.
---

# Tacto: {{DEVICE}}

The controlled platform is **Windows**, including when this Agent runs on Linux or macOS. Browser preference: **{{BROWSER}}**.

Read the [CUA operation guide](references/CUA.md) and its [Windows guide](references/WINDOWS.md) (ignore `MACOS.md` and `LINUX.md`). Apply this device's Windows target and transport bindings when following those guides. The verified upstream release, reference adaptations and file hashes are recorded in [source.json](references/source.json). Follow the live Driver schema when it differs from a recipe.

## Choose the available transport

- **CLI:** replace the `cua-driver` command prefix in official examples with `{{CLI}}`. Use `call TOOL` (or `TOOL` directly), `list-tools`, `describe TOOL`, `status`, `doctor` or `--version`. Pass tool arguments as a JSON object, preferably through UTF-8 stdin. A remote prefix routes to this Windows computer through the SSH tunnel; file output specified by `--screenshot-out-file` (or JSON `screenshot_out_file` in remote CLI calls) is saved on the Agent host and omitted from JSON stdout.
- **MCP:** use server `{{SERVER}}` and its advertised tools. Keep a persistent connection during the task. Over a remote MCP tunnel, omit `screenshot_out_file` so images arrive inline instead of writing to the remote Windows disk.

Read [runtime and sessions](references/RUNTIME.md) before multi-call work. For CLI, choose a unique non-default `session` label, repeat it on every tool accepting `session`, and call `end_session` at completion. Named CLI sessions persist between commands on the same daemon, with a five-minute idle timeout. MCP sessions belong to their connection. After switching transport, reconnecting or restarting the daemon, obtain fresh targets and observations.

Start with `health_report` and the advertised tool schemas. Use the Windows guide for the controlled computer. Tools such as recording that need a persistent transport use MCP. Bind observations and actions to the exact target, and verify the requested outcome before finishing.

## Managed installation

Tacto owns this device's Driver, hidden login tasks and optional tunnel. Use `tacto-cli check`, `update`, `rollback` and `uninstall` for maintenance. Ordinary updates wait for active MCP connections and named CLI sessions to finish. Skill files update and roll back with Tacto; edited files are preserved. Agent hosts can run `connect` again to refresh their local copies.
