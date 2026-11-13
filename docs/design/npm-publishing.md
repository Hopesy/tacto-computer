# npm trusted publishing

Prepared 2026-11-13 in response to the user's request to reduce repeated npm authorization. The selected implementation uses GitHub Actions OIDC with direct `npm publish`; the npm-side trust relationship still needs one-time setup.

## One-time setup

The package is `tacto-computer`, the executable is `tacto-cli`, and the repository is `Hopesy/tacto-computer`. At preparation time the npm registry returned 404 for the new package name. npm requires an existing package before configuring a trusted publisher, so initialize the new package through an authenticated first publish, then configure trust. Account 2FA must be enabled for the `npm trust` command.

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

Preparation verification (2026-11-13): actionlint 1.7.12 passed for both workflow files. The tag/version gate passed with the current stable tag and rejected a branch name and mismatched version. Tooling artifacts are under `.Tacto-temp/npm-publishing/`. The workflow and documentation are local edits; npm trust and a real CI publication remain pending.

Sources checked 2026-11-13: [Trusted publishing](https://docs.npmjs.com/trusted-publishers/), [npm trust](https://docs.npmjs.com/cli/v11/commands/npm-trust), [Staged publishing](https://docs.npmjs.com/staged-publishing/).
