# Release the installation and usability fixes

User continuation (2026-11-13): continue after the accepted fixes and the report that npm publication remains. Release the patch through the established GitHub OIDC workflow. Acceptance stays limited to install/uninstall, Skill discovery, CLI/MCP connection and callable tools, per the user's explicit clarification. Preserve other installations, keys and unrelated client entries; keep test scripts/artifacts under `.Tacto-temp/`.

Complete, 2026-11-13. Baseline HEAD `86ef09e`; source commit `265f2dc4a9c9891b388130e5cc478f62165da696` is tagged `v0.4.1` and pushed. Driver remains 0.46.1. [Publication run 43405507827](https://github.com/Hopesy/tacto-computer/actions/runs/43405507827) passed Windows/Linux CI and OIDC publish without interactive authorization. Public npm `latest` is 0.4.1, all 64 files and provenance match the tagged source, and the public package passed isolated default online install, CLI/MCP usability and complete uninstall. Final evidence: [0.4.1 history](../../histories/2026-11-13-v0.4.1.md).

- [x] Review changes, latest constraints and repository/publishing state.
- [x] Set patch version, verify package contents and commit reviewed changes.
- [x] Publish GitHub release/tag and complete Windows/Linux CI plus OIDC npm publication.
- [x] Verify public registry version/integrity/provenance and fresh-cache CLI.
- [x] Install the public package into an isolated directory, verify CLI/MCP tools and integration, then uninstall and verify cleanup.
- [x] Record release evidence and archive this plan.

Publishing contract: [npm publishing](../../design/npm-publishing.md). Process evidence: `.Tacto-temp/release-0.4.1/`. Original occupied empty test directory is retained following the earlier automatic approval rejection; do not retry terminating its holder. No Computer Use task-effect testing is required.
