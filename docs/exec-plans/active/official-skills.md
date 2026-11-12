# Official CUA Skill integration

Goal: use the release-matched official CUA Skill pack, retain Tacto's target/transport binding, and include Skill files in update, rollback and owned uninstall. User accepted this direction after identifying the upstream `skills` commands. Preserve npm/CLI installation and `@latest` prompts. Baseline: Tacto 0.2.0, clean HEAD e5b1564.

Current slice: implement both CLI and MCP routes, then managed official Skill integration. User correction: preserve CLI support for local and remote computers. Official Skill defaults include local CLI usage; Tacto's adapter binds the selected CLI/MCP endpoint and the controlled Windows platform, including Linux Agent hosts. Tests use `.Tacto-temp/`; existing production services and Agent skills stay untouched.

- [x] Import verified official release Skill files with source, version, hashes and license attribution.
- [x] Expose native Driver CLI calls locally and through the existing SSH callback; preserve named CLI sessions and idle-update protection.
- [x] Replace duplicated custom guidance with a small device/transport adapter plus official references.
- [x] Make Skill installation optional; reuse detected supported Skill directories or an explicit directory.
- [x] Track every owned Skill file through Windows/Node/VPS update, rollback and uninstall; preserve edited or unrelated content.
- [x] Exercise native local installation, client integration, official content integrity and lifecycle regressions.
- [ ] Update README, publish tested source and packages, verify CI and public npm availability.

Investigation: upstream 0.46.1 provides `skills install/update/uninstall/status/path` and `connect`. Its `skills install` installs a single shared `cua-driver` pack and links detected clients. Tacto needs isolated device ownership and target-bound CLI/MCP routes; the release pack is the reusable content source. Official named CLI sessions persist across calls on the same daemon; unnamed CLI calls use disposable leases. Use the native Driver CLI transport for this behavior, with JSON over stdin through the bridge.

Implementation milestone: CLI native sessions and read-only tool calls passed against real CUA 0.46.1 in isolated installation .Tacto-temp/native-3140bde3e03349c4bd4a06bff87700ff. Install, idle-session update deferral, update, faulty Driver recovery, manual rollback, task restart, retained reinstall and full uninstall passed. Windows/Node integration tests cover unchanged official hashes, legacy receipt migration, edited-reference retention and file cleanup; Linux VPS tests cover full-pack update/rollback and bounded stdin framing. Public release 0.3.0 and CI remain pending. The official CLI emits screenshot_png_b64, verified from its tagged Rust source and reflected in the host-side image decoder test.

Release checkpoint: source edf1e45 passed Windows/Linux CI 43171927260. Final native acceptance passed in .Tacto-temp/native-8d539514cbac476ebb6d3cef85dee607. GitHub v0.3.0 and ZIP are published. npm 0.3.0 publish is waiting for per-publish account verification; complete public tarball integrity, fresh-cache @latest and README checks after verification. Detailed in-session state: .Tacto-temp/release-status-030.json.
