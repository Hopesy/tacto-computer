# Claude Code desktop installation acceptance

User request (2026-11-13): use computer use to open a desktop Claude Code terminal and test installation and functionality. Use the public `tacto-computer@latest` package, currently 0.4.0. Preserve existing installations and client settings; all test files belong under `.Tacto-temp/`.

Testing completed 2026-11-13; acceptance result is partial pass. Computer Use rejected PowerShell launch with `product policy blocks this app`; the user explicitly chose the terminal-tool alternative. Real Claude Code 2.1.323 installed public 0.4.0 in `.Tacto-temp/claude-desktop-20261113` using a verified Driver archive and a process-local PSModulePath workaround. CLI discovery/session continuity, probe and native Claude MCP connection/Skill discovery/window capture passed. Desktop input failed: UIA timed out, background text left the document blank, and foreground delivery returned `foreground_unavailable`; Save As was not attempted. The resumed Claude process exited 0 after producing REPORT.md and releasing its MCP sessions. The controller independently checked install state, one Skill entry, MCP name, final blank screenshot and absence of the output file. See [results](../../histories/2026-11-13-claude-acceptance.md) and [follow-up defects](../tech-debt-tracker.md). Runtime source was unchanged.

- [x] Start Claude Code through the user-approved fallback and submit the acceptance task.
- [x] Install the public npm package with recorded workarounds; verify generated Skill/MCP names.
- [x] Test health, CLI discovery/sessions, MCP handshake/native tools and desktop editing; record the failed input/Save As acceptance explicitly.
- [x] Inspect the actual results and preserve evidence. Test installation and blank test document remain for follow-up; the default installation remains absent.
