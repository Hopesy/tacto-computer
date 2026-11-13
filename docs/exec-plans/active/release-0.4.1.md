# Release the installation and usability fixes

User continuation (2026-11-13): continue after the accepted fixes and the report that npm publication remains. Release the patch through the established GitHub OIDC workflow. Acceptance stays limited to install/uninstall, Skill discovery, CLI/MCP connection and callable tools, per the user's explicit clarification. Preserve other installations, keys and unrelated client entries; keep test scripts/artifacts under `.Tacto-temp/`.

Baseline: HEAD `86ef09e` on `main`, synchronized with origin. Reviewed fixes and local regressions are recorded in [acceptance fixes](../../histories/2026-11-13-acceptance-fixes.md); real isolated install/use/uninstall already passed. Version becomes 0.4.1; Driver remains 0.46.1. Current slice: prepare source commit, release archives and notes, publish through CI, then validate the public package and clean up its isolated installation.

- [x] Review changes, latest constraints and repository/publishing state.
- [ ] Set patch version, verify package contents and commit reviewed changes.
- [ ] Publish GitHub release/tag and complete Windows/Linux CI plus OIDC npm publication.
- [ ] Verify public registry version/integrity/provenance and fresh-cache CLI.
- [ ] Install the public package into an isolated directory, verify CLI/MCP tools and integration, then uninstall and verify cleanup.
- [ ] Record release evidence and archive this plan.

Publishing contract: [npm publishing](../../design/npm-publishing.md). Process evidence: `.Tacto-temp/release-0.4.1/`. Original occupied empty test directory is retained following the earlier automatic approval rejection; do not retry terminating its holder. No Computer Use task-effect testing is required.
