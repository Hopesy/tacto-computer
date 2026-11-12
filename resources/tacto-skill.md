---
name: tacto-{{DEVICE}}
description: Operate the Windows computer {{DEVICE}} through Tacto CLI or the {{SERVER}} MCP server for desktop application and browser tasks.
---

# Tacto: {{DEVICE}}

The controlled platform is **Windows**, including when this Agent runs on Linux or macOS. Browser preference: **{{BROWSER}}**.

Read the [official CUA Skill](official/SKILL.md) and its [Windows guide](official/WINDOWS.md). The official files are shipped unchanged from the verified CUA release recorded in [source.json](official/source.json). Follow the live Driver schema when it differs from a recipe.

## Choose the available transport

- **CLI:** replace the `cua-driver` command prefix in official examples with `{{CLI}}`. Use `list-tools`, `describe TOOL`, `call TOOL`, `status`, `doctor` or `--version`. Pass tool arguments as a JSON object, preferably through UTF-8 stdin. A remote prefix routes to this Windows computer through the SSH tunnel; file output specified by `--screenshot-out-file` is saved on the Agent host.
- **MCP:** use server `{{SERVER}}` and its advertised tools. Keep a persistent connection during the task.

Read [runtime and sessions](official/RUNTIME.md) before multi-call work. For CLI, choose a unique non-default `session` label, repeat it on every tool accepting `session`, and call `end_session` at completion. Named CLI sessions persist between commands on the same daemon, with a five-minute idle timeout. MCP sessions belong to their connection. After switching transport, reconnecting or restarting the daemon, obtain fresh targets and observations.

Start with `health_report` and the advertised tool schemas. Use the Windows guide for the controlled computer. Tools such as recording that need a persistent transport use MCP. Bind observations and actions to the exact target, and verify the requested outcome before finishing.

## Managed installation

Tacto owns this device's Driver, hidden login tasks and optional tunnel. Use `tacto-mcp check`, `update`, `rollback` and `uninstall` for maintenance. Ordinary updates wait for active MCP connections and named CLI sessions to finish. Skill files update and roll back with Tacto; edited files are preserved. Agent hosts can run `connect` again to refresh their local copies.
