# Release 0.4.2

Goal: release `tacto-computer` `0.4.2` containing the comprehensive codebase audit and re-audit fixes through the established GitHub Release + GitHub Actions OIDC trusted publishing workflow (`publish.yml`).

Completed 2026-11-27. Source commit `7dbdd78c921c16d362dc8e8a740444cafa69f246` is tagged `v0.4.2` and published at [GitHub Release v0.4.2](https://github.com/Hopesy/tacto-computer/releases/tag/v0.4.2). [Workflow run 45930082194](https://github.com/Hopesy/tacto-computer/actions/runs/45930082194) passed Windows/Linux CI and OIDC npm publication. Public npm `latest` is `0.4.2`, all 68 files and Sigstore DSSE provenance attestations match `v0.4.2`, and the live Windows + Antigravity installation upgraded cleanly to public `0.4.2`. Final evidence: [0.4.2 history](../../histories/2026-11-27-v0.4.2.md).

- [x] Bump `package.json` and `README.md` to `0.4.2`, build `tacto-computer-0.4.2.tgz` and `Tacto-0.4.2.zip` (+ `.sha256`), and verify package integrity.
- [x] Commit reviewed changes, push `main` and `v0.4.2`, and publish GitHub Release `v0.4.2` with verified ZIP and SHA256 assets.
- [x] Complete GitHub Actions Windows/Linux CI and OIDC npm publication (`publish.yml`).
- [x] Verify public npm registry visibility, tarball integrity/provenance, upgrade local Antigravity installation to public `0.4.2`, record release history in `docs/histories/2026-11-27-v0.4.2.md`, and archive this plan.
