# CLI and official Skills

Status: accepted, 2026-11-12. The user requested both CLI and MCP access, with reusable official guidance and unobtrusive lifecycle management.

The Node `driver` command sends a bounded JSON request to the Windows bridge. Locally it uses PowerShell stdin; remotely it uses the VPS device's existing `ssh_config` and the restricted `cua-cli` callback. The bridge validates the command/tool and invokes the native Driver CLI against the installation's pipe. Tool arguments travel through UTF-8 stdin; shell strings contain only quoted connection paths. `call` is a convenience alias. Supported commands are call, list-tools, describe, status, doctor and version.

Native named CLI sessions use the same daemon namespace across processes. Each successful call with a non-default session refreshes a five-minute maintenance lease; end_session removes it. Running processes retain the existing connection lease, covering the handover to the idle lease. Normal maintenance respects both types. Forced maintenance removes the leases and restarts the owned daemon. MCP retains its persistent transport scope. Screenshots use the native CLI's screenshot_png_b64 result and are saved on the invoking Agent host with existing-file protection.

The official 0.46.1 Skill release archive has SHA256 dfdbff1351035143a503c337b7fb06b4b3d8a1bea5841417a651825b14ccaaf4. `resources/cua-skill/` retains the verified upstream files and MIT license; `source.json` records the release URL and original hashes. A small Tacto adapter binds the selected Windows device, CLI prefix, MCP name and browser preference.

## Single device Skill entry

Status: accepted, 2026-11-13, by the user after Codex discovered the nested upstream `cua-driver` as a second Skill. This supersedes the 0.3.0 choice to install the complete upstream pack verbatim under `official/`.

The installed `tacto-computer/` folder contains one `SKILL.md` plus `references/`. The official entry becomes `references/CUA.md`, with YAML frontmatter removed. References to `SKILL.md` within the upstream Markdown become `CUA.md`, including prose and relative links. Other text and the license remain unchanged. The adapter routes readers through the device's Windows target and CLI/MCP bindings before loading these guides.

`scripts/Build-Skill.mjs` is the single transformation implementation. It verifies upstream hashes and produces the committed runtime resource `install/skill-references.json`; both Node and standalone Windows PowerShell read that bundle. `references/source.json` retains original provenance and records adaptation rules and installed file hashes. `npm run build:skills` regenerates it; source checks and both packaging paths reject a stale bundle.

Skill installation is optional. Fresh installs detect existing supported Agent directories; explicit paths and --no-skills override discovery. Existing integrations retain their registered directories. Each device owns its adapter and reference files, tracked by per-file hashes. Legacy single-file and 0.3.0 `official/` receipts migrate on update: unchanged owned files are replaced and empty old directories are pruned. Conflicting edits block overwrite; disconnect/uninstall removes unchanged owned files and preserves edits. Local Windows lifecycle transactions restore the previous runtime's layout, reading old upstream resources for runtimes predating the shared bundle. VPS-local registered copies follow remote configure/rollback; other Agent hosts refresh through connect.

VPS management helper version 3 accepts both `references/` and legacy `official/` ownership paths; bounded JSON stdin framing remains `tacto-stdin-v2`. Upgrading a version-1 or version-2 helper uses the saved original VPS login once. The upgraded helper also accepts legacy base64 framing, so previous runtimes can configure their old layout, check and remove their device. Node `connect` checks the helper version before registering the new layout for VPS-managed cleanup. Each client update snapshots affected files and restores them after a write failure.

Sources: [CUA agent connection guide](https://cua.ai/docs/cua-driver/guides/connect-your-agent), [CUA Skill release](https://github.com/trycua/cua/releases/tag/cua-driver-rs-v0.46.1). Tests and native acceptance results are recorded in the release history.

## Product naming

Status: accepted, 2026-11-13. The user specified CLI command `tacto-cli`, Skill `tacto-computer`, MCP server `tacto-mcp`, and repository `tacto-computer`, then explicitly selected npm package `tacto-computer`. This supersedes device-suffixed public Skill/MCP names and the `tacto-mcp` CLI/package name.

`package.json` owns the current package name, executable mapping and `tacto` Skill/MCP names. Node reads them through `src/product.mjs`; Windows reads the selected runtime's metadata, preserving prior-runtime naming during rollback. The installer sends the selected names and CLI prefix to the VPS helper, which accepts the current and legacy naming contracts. Installed adapters use `npx -y --package tacto-computer@latest tacto-cli` with target-specific connection options.

The device identity remains in connection state and ownership receipts. Each client config has a fixed `tacto-mcp` key and each selected Skill directory has a `tacto-computer` child. Another device can use a separate client config/Skill directory; an occupied unowned destination produces a conflict. Existing owned `computer-<device>` entries and `tacto-<device>` directories migrate transactionally. Edited entries/files are preserved; rollback reconstructs the selected runtime's names. Receipt filenames keep their device identity for migration and cleanup.
