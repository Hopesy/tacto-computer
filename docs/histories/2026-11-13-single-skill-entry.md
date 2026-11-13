# Single Skill entry and product naming

Delivered in [Tacto Computer 0.4.0](2026-11-13-v0.4.0.md). The sections below retain the implementation checkpoints; npm trusted publishing and public verification are now complete.

The user approved a single target-bound Skill entry after Codex discovered both `tacto-zhouh` and the nested upstream `cua-driver`. The implementation is a working-tree change on `bbabe83`; npm/release publication is separate follow-up work.

- Installed layout: `SKILL.md` plus `references/`, with the upstream entry renamed to `CUA.md`, Skill frontmatter removed and document references updated.
- One build script compiles verified upstream sources into `install/skill-references.json`. Node and Windows PowerShell share that runtime bundle. Source provenance, adaptation rules, installed hashes and the MIT license accompany the references.
- Owned `official/` files migrate on update; legacy rollback reconstructs the previous layout. Edited content remains protected. VPS helper version 3 supports both layouts and upgrades version-2 helpers through the existing bootstrap route; stdin framing stays at version 2.
- README, development instructions and the [design](../design/cli-and-skills.md#single-device-skill-entry) describe the current layout and generation workflow.

Verification on Windows PowerShell 5.1: 15 scripts passed syntax/BOM checks; `npm run check`, 11 Node tests, `tests/test-skills.ps1` and the isolated remote lifecycle passed. WSL Ubuntu passed all 8 VPS tests, including old/new layout migration, rollback and edited-file cleanup. Node integration verifies a single `SKILL.md`, reference links, provenance and old receipt migration. Both npm and ZIP packages passed `tests/verify-package.py`.

Real Windows acceptance used the original `bbabe83` installer and CUA 0.46.1 in an isolated installation, then the modified installer. Entry counts were **2 → 1 → 2 → 1** across baseline installation, update, rollback and re-update. Activation health passed at each switch; native CLI `get_screen_size` returned 1920×1080 at scale 1.25. Full uninstall removed the owned Skill and preserved the unrelated MCP entry. Evidence: `.Tacto-temp/skill-layout-native-3b4e6fbf233047a0aa06b6e855a3efc3/result.json` and adjacent logs; runner: `.Tacto-temp/verify-skill-layout.ps1`.

The first download attempt exhausted the installer's bounded network timeout and cleaned up the isolated installation. The official GitHub asset was then downloaded using the authenticated API and verified against the pinned archive SHA256 `ec49cca509f25f65db2fa917718215f55f959d5ef650bf8ab2238a201d5666ac`. Acceptance used that verified archive via the installer's existing bundled-archive path.

Local package outputs are in `.Tacto-temp/skill-layout-packages/`; test logs are in `.Tacto-temp/skill-layout-checks/`. The former default Tacto installation and Agent Skill directories were absent at execution time; acceptance preserved that state.

## Product naming correction

The user subsequently specified CLI `tacto-cli`, Skill `tacto-computer`, MCP server `tacto-mcp`, repository `tacto-computer`, and selected npm package `tacto-computer`. Current naming is defined in package metadata and documented in the [design](../design/cli-and-skills.md#product-naming). The earlier device-suffixed naming is retained only for migration and rollback.

Node and Windows migrate owned Skill directories and MCP keys to the fixed names. Device-specific receipt filenames and stored device identity preserve cleanup ownership. Foreign destinations and edited files/entries remain protected. The VPS helper accepts the current and prior naming contracts, including rollback initiated by older runtimes. CLI help, configuration exports, npm bin metadata, README commands, CI package names, cleanup instructions and updater repository URLs use the accepted names.

Verification: 11 Node integration tests; Windows CLI tests (3 pass, 2 Unix-only skips); Windows PowerShell Skill and MCP export tests; isolated remote lifecycle including helper migration; all 8 WSL VPS tests. The packed `tacto-computer-0.3.0.tgz` ran `tacto-cli --version` and `--help` through `npm exec` using an isolated fresh cache. Public npm publication remains a follow-up step.

Real CUA 0.46.1 acceptance passed baseline installation → upgrade → rollback → re-upgrade → CLI read-only call → full uninstall. The new Skill was named `tacto-computer`; client and exported MCP configurations used `tacto-mcp`. Rollback restored the old device-suffixed names; re-upgrade removed those old entries. Evidence: `.Tacto-temp/naming-native-82df4416d11a40a786eeee706fb7edb6/result.json` and adjacent logs; runner: `.Tacto-temp/verify-naming.ps1`. Current local packages are in `.Tacto-temp/naming-packages/`.

GitHub confirmed the repository rename to [Hopesy/tacto-computer](https://github.com/Hopesy/tacto-computer); Git origin now uses `https://github.com/Hopesy/tacto-computer.git`. The active checkout directory remains `C:\Users\zhouh\Desktop\tacto-mcp`. Source changes are local working-tree edits on `bbabe83`.

## npm publication preparation

The user raised repeated npm authorization as a usability issue. Prepared `publish.yml` to reuse Windows/Linux CI and publish stable GitHub Releases directly through npm OIDC. Actionlint 1.7.12 and the release tag/version gate passed. npm's current documentation requires `Allow npm publish` for direct publication; staged publishing retains per-release approval. The new package still returned 404 during preparation, so initial package creation, the one-time npm trust binding, and a real CI publish remain pending. Setup values and the two-day first-publish validation window are recorded in the [publishing design](../design/npm-publishing.md).
