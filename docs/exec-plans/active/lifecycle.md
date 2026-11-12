# Lifecycle release

## Resume

Goal: improve frictionless install, upgrade rollback and complete uninstall; implement the previously reviewed CUA guidance, test, push GitHub and publish npm with updated README.
Baseline: 0.1.2, commit 93a32b4, clean worktree. Windows PowerShell 5.1 and Node 22+ remain supported. Process artifacts belong in `.Tacto-temp/`. User authorized repository push and npm release.
Current slice: verify public npm availability. Source and GitHub ZIP are released; Windows/Linux CI and both native lifecycle scenarios passed. Latest user correction: keep npm/command-based installation simple; remove the added EXE graphical installer. Existing production CUA/tunnel remain untouched; real tests use independent identities and pipes.
Next: wait for npm's accepted upload to become publicly available, verify its digest and fresh @latest CLI execution, then archive this plan. See [release history](../../histories/2026-11-12-v0.2.0.md).

## Checklist

- [x] Owned-resource manifest, complete uninstall, offline remote-cleanup receipt, idempotent retry.
- [x] Staged update, journal recovery, automatic/manual rollback, stable identity and MCP endpoint.
- [x] No console on background paths; least-needed elevation, restart-safe retry and verified downloads.
- [x] npm one-command setup, native installed-app uninstall via existing script, opt-in idle updates.
- [x] Target-bound Skill, client configuration merge/remove and release-matched runtime guidance.
- [x] Actual MCP health diagnostics, capability-aware batch/incremental observation, reconnect and browser workflows.
- [x] Isolated regression tests and real Windows daemon/MCP/lifecycle acceptance; Linux VPS checks.
- [ ] README, version, packages, CI, GitHub push/release and npm publication verification.

## Evidence and decisions

- Baseline audit: update repeats install with no rollback; remote remove failure precedes local cleanup; setup/check/uninstall all elevate; terminal-based installation; no target Skill.
- CUA research: 31 pages, 96 tab variants reviewed; installed 0.46.1 describes health_report, get_guide, run_steps, run_script and incremental get_window_state.

- User correction (2026-11-12): standalone EXE/GUI installer was unnecessary scope. Removed Installer.cs, its packaging and GUI/askpass path. Keep existing windowless runtime launcher for daemon/tunnel only.
- Real external-driver lifecycle passed: independent limited tasks, install/update/fault rollback/manual rollback/restart/retained uninstall/reinstall/full uninstall/repeat uninstall. MCP discovered 63 tools, full health returned ok and screen size was 1920x1080 at 1.25 scale. Default official download, SHA/signature and owned-driver cleanup are exercised by the same test without DriverPath.
- Regression coverage also includes legacy task-snapshot rollback, retained remote authorization, unchanged owned OpenSSH restoration, edited configuration preservation, updater on/off and busy deferral, compressed SSH bootstrap and VPS Skill synchronization.
- Fixed real findings: PowerShell download stalls (use bounded system curl), missing custom PID-file during status, bridge stream buffering, async VPS line buffering, and Windows image-handle cleanup races. Full diagnostics can report third-party UIA degradation/timeouts; activation has separate bounded core/capture checks.
- Package source/content/manifest validation passed. npm login refreshed. Deployment-specific acceptance still includes fresh OpenSSH/UAC/password login, new real VPS setup and whole-machine reboot; documented in VERIFICATION.md.
- GitHub release and CI completed. The renewed npm account verification succeeded; publish returned HTTP 202 and exit 0 at 13:40:43 UTC+08. As of 13:49, the public registry still serves 0.1.2 and 0.2.0 remains unavailable. Account verification is finished; public visibility is the remaining external dependency.
