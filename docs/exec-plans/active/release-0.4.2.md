# Release 0.4.2

Goal: release `tacto-computer` `0.4.2` containing the comprehensive codebase audit and re-audit fixes through the established GitHub Release + GitHub Actions OIDC trusted publishing workflow (`publish.yml`).

Baseline: `0328d6b` on `main`. Pinned upstream CUA Driver remains `0.46.1`. Preserve existing installations, SSH keys and unrelated client MCP/Skill entries; keep process evidence under `.Tacto-temp/release-0.4.2/`.

- [ ] Bump `package.json` and `README.md` to `0.4.2`, build `tacto-computer-0.4.2.tgz` and `Tacto-0.4.2.zip` (+ `.sha256`), and verify package integrity.
- [ ] Commit reviewed changes, push `main` and `v0.4.2`, and publish GitHub Release `v0.4.2` with verified ZIP and SHA256 assets.
- [ ] Complete GitHub Actions Windows/Linux CI and OIDC npm publication (`publish.yml`).
- [ ] Verify public npm registry visibility, tarball integrity/provenance, upgrade local Antigravity installation to public `0.4.2`, record release history in `docs/histories/2026-11-27-v0.4.2.md`, and archive this plan.
