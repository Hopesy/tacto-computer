# npm trusted publishing

Active and verified 2026-11-13. The user requested fewer npm authorization steps and approved initialization. GitHub Actions OIDC with direct `npm publish` successfully published 0.4.0; the npm trust relationship is configured for `Hopesy/tacto-computer` / `publish.yml`. See [release evidence](../histories/2026-11-13-v0.4.0.md).

## One-time setup

The package is `tacto-computer`, the executable is `tacto-cli`, and the repository is `Hopesy/tacto-computer`. Initial package creation and trust binding are complete. The following records the setup procedure for future recreation: npm requires an existing package before configuring a trusted publisher, so initialize a new package through an authenticated first publish, then configure trust. Account 2FA must be enabled for the `npm trust` command.

After `.github/workflows/publish.yml` is committed and available on GitHub, run with npm 11.15.0 or newer:

```powershell
npm.cmd trust github tacto-computer --repo Hopesy/tacto-computer --file publish.yml --allow-publish
```

The equivalent npm package Settings → Trusted Publisher fields are:

| Field | Value |
| --- | --- |
| Provider | GitHub Actions |
| Organization or user | Hopesy |
| Repository | tacto-computer |
| Workflow filename | publish.yml |
| Environment name | Leave empty; this workflow does not declare an environment |
| Allowed actions | Enable **Allow npm publish** |

Direct publish permission is required for this workflow. New trusted publisher configurations default to staged publishing, whose approval step requires a maintainer's 2FA each time. The configuration must complete its first successful publish within **2 days** or it expires. Create the trust relationship when the first CI publication is ready.

## Routine releases

Update `package.json` to the next stable version, commit the reviewed source, tag it `v<version>`, and publish a GitHub Release. `publish.yml` runs the shared Windows/Linux CI, checks the tag against the package version, packs and verifies the tarball, and publishes it through OIDC. A manual retry can target the release tag:

```sh
gh workflow run publish.yml --ref v0.4.0
```

Only stable version tags run publication. Pull requests and ordinary branch pushes run CI. The publish job uses a GitHub-hosted runner, Node 24, current npm 11 and `id-token: write`; npm generates a short-lived workflow credential. The workflow has no npm write-token secret or per-run approval environment. Account 2FA remains in place for interactive account actions. npm automatically generates provenance for public packages published through this public repository.

CI is reused through `workflow_call` in `ci.yml`; the actual npm publish is in the top-level `publish.yml`, matching the trusted publisher filename. A successful real publish is the final OIDC verification. Local packing and static workflow checks validate preparation only.

Verification (2026-11-13): actionlint 1.7.12 passed for both workflows; the tag/version gate accepted a matching stable tag and rejected branch/mismatched tags. [Run 43382560793](https://github.com/Hopesy/tacto-computer/actions/runs/43382560793) passed Windows/Linux CI and published 0.4.0 via OIDC without interactive confirmation. Public tarball contents, integrity, provenance and fresh-cache CLI checks passed. Evidence is under `.Tacto-temp/npm-release/`.

The npm 11.17 `trust` subcommand rejected a global `--cache` option placed before `trust`; using `npm_config_cache` and keeping `npm trust ...` at the start worked. A read-only `npm trust list` can itself prompt for account verification; the successful OIDC publish and its public provenance provide direct release evidence.

Sources checked 2026-11-13: [Trusted publishing](https://docs.npmjs.com/trusted-publishers/), [npm trust](https://docs.npmjs.com/cli/v11/commands/npm-trust), [Staged publishing](https://docs.npmjs.com/staged-publishing/).
