# Comprehensive audit fixes

## Resume

Goal: repair all functional, state-machine, CUA contract, cross-platform SSH, security-hardening and test-coverage issues identified in the two-pass codebase audit.
Baseline: `0.4.1`, commit `0328d6b`, clean `main` worktree. Supported runtimes remain Node.js 22+, Windows PowerShell 5.1 (UTF-8 BOM + CRLF) and Python 3 on Linux VPS. Process and test artifacts stay under `.Tacto-temp/`.
Status: completed on 2026-11-26. All unit, isolated Windows/WSL integration, package integrity and real Windows desktop lifecycle acceptance checks passed. See [audit repair history](../../histories/2026-11-26-audit-fixes.md).

## Checklist

- [x] **CLI, probe and Agent integration (`src/`, `resources/tacto-skill.md`)**:
  - Support bare `tacto-cli driver <tool> [json]` alongside `driver call <tool>` to match upstream CUA examples while blocking all 22 daemon management subcommands.
  - Pre-check `--screenshot-out-file` (and intercept JSON `screenshot_out_file` on remote `--proxy`/`--ssh` CLI calls so screenshots save on the Agent host), omit raw base64 image payloads from stdout when saved to disk, and preserve tool stdout when post-call image extraction fails.
  - Pass `server.command` to `childEnvironment` in `src/probe.mjs`, format top-level probe errors cleanly, and accept `--health`/`--smoke` in any argument position in `tacto-cli probe` while rejecting unknown `-` flags.
  - Support `--key=value` CLI options, IPv6 VPS host literals, optional `--mcp-name` / `--skill-name` overrides with `customNames` preservation on VPS `configure` updates, canonical key-order-independent MCP entry comparisons, unified OpenCode Skill path discovery, and optional CUA `--permission-mode` / `--capability-manifest` daemon configuration on `cua-driver serve`.
- [x] **Windows bridge, leases and MCP health (`Invoke-CuaBridge.ps1`, `McpHealth.ps1`, `Start-Tunnel.ps1`)**:
  - Bind bridge child processes to a Win32 Job Object (`KILL_ON_JOB_CLOSE`), bound stdin-EOF shutdown and stdout/stderr drain waits, and cap `cua-cli` stdin at 8 MiB.
  - Track nested `run_steps` session leases/terminations and respect `isError` on `end_session`.
  - Route Local activation and `tacto-cli check` through `Invoke-CuaBridge.ps1` (`-Local -Health` / `-Local`), handle `tools/list` pagination, and return `-32601` for unsupported server-to-client JSON-RPC requests.
  - Prefer `System32\OpenSSH\ssh.exe` and stream tunnel logs line-by-line with live rotation in `Start-Tunnel.ps1`.
- [x] **Windows lifecycle, SSH and scripts (`Lifecycle.ps1`, `Setup-Tacto.ps1`, `Update-Available.ps1`, `Update.cmd`, `Export-McpConfig.ps1`, `Download.ps1`)**:
  - Validate Agent config/Skill edit conflicts before `Start-Transaction`, guard `Restore-Transaction` so client conflicts never leave `transaction.json` wedged, and bypass `Restore-Transaction` during `Uninstall`.
  - Allow re-running `setup` with corrected parameters after an incomplete initial attempt (`preparing`/`failed`/`connecting`), and synchronize `Set-WindowsAuthorization` on every Remote configure/bootstrap.
  - Set `sshd` `StartupType` to `Automatic` even when `OpenSSH.Server` was pre-installed as `Manual` (restoring prior start type on uninstall when unshared), and resolve domain/Entra usernames and space-containing usernames safely.
  - Embed trusted `known_hosts` entries (read via pure string lines without PS 5.1 ETS provider properties) into offline uninstall receipts and consume them in `tacto-cli cleanup`.
  - Prune superseded `releases\*` directories, clean up `Update-Available.ps1` staging files and `%TEMP%\.Tacto-temp\elevation-*`, preserve child error details, skip background elevation in auto-update, verify GitHub release asset digests, add share-lock retries to `Write-AtomicJson`, fix `Update.cmd` (`-Action Update`), split interactive `UninstallString` vs `QuietUninstallString`, and align `Export-McpConfig.ps1` with bridge exports.
- [x] **Linux VPS helper (`install/linux/setup-vps.py`)**:
  - Preserve `~/.ssh/authorized_keys` symlinks during atomic updates, isolate corrupted sibling `state.json` files in `allocate_port`, resolve `ssh` dynamically for `cua-proxy`, support `tools/list` pagination and pure binary `Popen` I/O in `mcp_health`, and accept custom `--mcp-name` / `--skill-name` plus qualified Windows usernames.
- [x] **Verification and documentation**:
  - Added automated regressions for every repaired bug across Node, Python, Windows PowerShell and WSL Linux tests.
  - Passed full CI check suite, `npm pack` + `Package.ps1` verification, and real isolated Windows desktop lifecycle acceptance (`test-native-lifecycle.ps1`).
  - Updated `README.md`, `docs/design/`, `docs/VERIFICATION.md` and `docs/histories/2026-11-26-audit-fixes.md`.
