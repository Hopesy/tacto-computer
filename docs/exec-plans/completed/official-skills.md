# Official CUA Skill integration

Goal: use the release-matched official CUA Skill pack, retain Tacto's target/transport binding, and include Skill files in update, rollback and owned uninstall. User accepted this direction after identifying the upstream `skills` commands. Preserve npm/CLI installation and `@latest` prompts. Baseline: Tacto 0.2.0, clean HEAD e5b1564.

Completed 2026-11-13. Source `baeda660e622e9f73e24f3fabbda59871b9b7f68` passed Windows/Linux CI 43374642997. The user completed npm login and initial security-key confirmation; GitHub trust was bound to `Hopesy/tacto-computer` / `publish.yml` with direct publish permission. OIDC run 43382560793 published 0.4.0 without interactive confirmation. Public npm `latest` is 0.4.0; tarball integrity, all 57 files against the release commit (with checkout attributes), provenance source/workflow/digest, and fresh-cache CLI/config export passed. GitHub v0.4.0 and ZIP are published. [Final release evidence](../../histories/2026-11-13-v0.4.0.md); local evidence: `.Tacto-temp/npm-release/`. The default local installation remains absent. No required work remains in this plan.

- [x] Prepare and statically validate `publish.yml` for direct OIDC publishing with shared Windows/Linux CI. Actionlint 1.7.12 passed; tag/version gate accepts the matching stable tag and rejects branch/mismatched tags. The real OIDC publish also passed.
- [x] Initialize the new npm package and bind `Hopesy/tacto-computer` / `publish.yml` with `Allow npm publish`.
- [x] Complete a real CI publish within two days of creating the trust configuration and verify the public package.

- [x] Apply the accepted names to CLI, package, installed Skill/MCP, docs and updates.
- [x] Verify old-name migration, conflicts, rollback and real package command.
- [x] Rename GitHub repository to `tacto-computer`, update origin, record evidence.

- [x] Build a shared reference bundle with `CUA.md`, corrected links and transformation provenance.
- [x] Migrate Windows/Node/VPS Skills from `official/`, retaining rollback and edited-file protection.
- [x] Verify one discoverable entry, valid references, package contents and a real isolated local installation.
- [x] Update the [design](../../design/cli-and-skills.md#single-device-skill-entry), README and delivery evidence.

- [x] Import verified official release Skill files with source, version, hashes and license attribution.
- [x] Expose native Driver CLI calls locally and through the existing SSH callback; preserve named CLI sessions and idle-update protection.
- [x] Replace duplicated custom guidance with a small device/transport adapter plus official references.
- [x] Make Skill installation optional; reuse detected supported Skill directories or an explicit directory.
- [x] Track every owned Skill file through Windows/Node/VPS update, rollback and uninstall; preserve edited or unrelated content.
- [x] Exercise native local installation, client integration, official content integrity and lifecycle regressions.
- [x] Update README, publish tested source and packages, verify CI and public npm availability.

Investigation: upstream 0.46.1 provides `skills install/update/uninstall/status/path` and `connect`. Its `skills install` installs a single shared `cua-driver` pack and links detected clients. Tacto needs isolated device ownership and target-bound CLI/MCP routes; the release pack is the reusable content source. Official named CLI sessions persist across calls on the same daemon; unnamed CLI calls use disposable leases. Use the native Driver CLI transport for this behavior, with JSON over stdin through the bridge.

Implementation milestone: CLI native sessions and read-only tool calls passed against real CUA 0.46.1 in isolated installation .Tacto-temp/native-3140bde3e03349c4bd4a06bff87700ff. Install, idle-session update deferral, update, faulty Driver recovery, manual rollback, task restart, retained reinstall and full uninstall passed. Windows/Node integration tests cover unchanged official hashes, legacy receipt migration, edited-reference retention and file cleanup; Linux VPS tests cover full-pack update/rollback and bounded stdin framing. The official CLI emits screenshot_png_b64, verified from its tagged Rust source and reflected in the host-side image decoder test.

Historical 0.3.0 checkpoint: source edf1e45 passed Windows/Linux CI 43171927260; native acceptance passed in .Tacto-temp/native-8d539514cbac476ebb6d3cef85dee607. GitHub v0.3.0 and ZIP were published, and npm's initial account verification was subsequently completed. The final 0.4.0 release above completes the naming, single-entry Skill and trusted publishing follow-up work.
