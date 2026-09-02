# Releasing

Publish source releases from this repository. Update the source-building
Homebrew formula in
[`raulgg/homebrew-tap`](https://github.com/raulgg/homebrew-tap).

## One-time setup

1. Create the `release-automation` environment. Allow deployments only from the
   selected branch `main`, and disable administrator bypass.
2. Create a fine-grained personal access token limited to this repository with
   read and write access to contents, issues, and pull requests. Store it as the
   `RELEASE_PLEASE_TOKEN` environment secret in `release-automation`.
3. Allow squash merging. Set the default squash commit to the pull request title
   and description (`PR_TITLE` and `PR_BODY`).
4. Require CI, Quality Checks, and PR Title on `main`.
5. For tags matching `v*`, restrict updates and deletions but allow creation.
6. Create the `tap-dispatch` environment. Allow deployments only from the
   selected branch `main`, and disable administrator bypass. Store a separate
   fine-grained personal access token as `HOMEBREW_TAP_DISPATCH_TOKEN`. Limit it
   to `raulgg/homebrew-tap` with write access to Actions.
7. In the tap repository, create the `formula-updater` environment. Allow
   deployments only from the selected branch `main`, and disable administrator
   bypass. Store a separate fine-grained personal access token as
   `HOMEBREW_TAP_TOKEN` with write access to contents and pull requests.
8. Enable auto-merge in the tap repository and require every `brew test-bot`
   check on `main`. Do not allow the updater to push directly to `main`.

## Pull request titles

Format pull request titles according to the
[Conventional Commits 1.0.0 specification](https://www.conventionalcommits.org/en/v1.0.0/).
Use squash merge so Release Please receives the pull request title and body as
the commit message.

## Publish a release

1. Merge normal pull requests into `main` using squash merge. Release Please
   opens or refreshes its release pull request when a releasable change lands.
2. Review the proposed version and `CHANGELOG.md`. Merging this protected pull
   request approves and publishes the release.
3. Verify that Release Please created the `vVERSION` tag and public GitHub
   release. Use GitHub's automatic source archive; do not upload a duplicate
   source asset.

If the workflow fails after the release pull request merges, rerun its failed
job. Never move, delete, or recreate a published tag. Correct bad source with a
new patch release.

## 0.3.x patch releases

Cut 0.3.x patches from `release/0.3`, not `main`. `main` already has later
features, and `bump-patch-for-minor-pre-major` is false, so a `fix:` commit
on `main` becomes 0.4.0.

1. Allow `release/0.3` in the `release-automation` and `tap-dispatch`
   GitHub environments, in addition to `main`.
2. Land only the patch on `release/0.3`. This line enables pre-1.0 patch
   bumps; include a `Release-As: 0.3.1` footer on the first patch so the
   version is unambiguous.
3. Do not edit `version.txt`, `.release-please-manifest.json`, or
   `CHANGELOG.md` by hand. Review the draft Release Please pull request
   against `release/0.3`, then squash-merge it. Do not rewrite its body.
4. Do not merge `release/0.3` into `main`. Land the same fix on `main`
   separately so 0.4.0 includes it.

## Update the Homebrew tap

1. Verify that the release run completed its `tap-dispatch` job.
2. Verify that the tap's `Update airpods-control formula` workflow opened a pull
   request.
3. Wait for every required `brew test-bot` check and the squash auto-merge.
4. If dispatch fails, run the tap workflow manually with the existing release
   tag.

## Experimental binary bundle

1. Run the `Experimental Binary Bundle` workflow.
2. Verify that its Apple Silicon and Intel jobs pass.
3. Verify that each artifact name includes the checked-out commit and that its
   `BUILD.txt` identifies the same commit, native runner, and toolchain.
4. Download the seven-day Actions artifact if the package needs inspection and
   verify `SHA256SUMS` before extracting it.

Do not attach the ad-hoc-signed experimental artifact to a GitHub release.

## Optional signed binary release

1. Keep the repository variable `PUBLISH_BINARY_RELEASES` set to `false` until
   the binary-release pull request is approved.
2. Create a `binary-release` environment restricted to `main` and require the
   maintainer's approval for each deployment.
3. Store these secrets in the `binary-release` environment:
   - `DEVELOPER_ID_APPLICATION_CERTIFICATE`: base64-encoded Developer ID
     Application `.p12`;
   - `DEVELOPER_ID_APPLICATION_PASSWORD`: password for the `.p12`;
   - `APPLE_API_ISSUER`;
   - `APPLE_API_KEY_ID`;
   - `APPLE_API_PRIVATE_KEY`.
4. After a stable release contains this workflow, run `Publish Binary Release`
   manually from `main` for the latest stable tag. Leave asset publication
   disabled.
5. Verify signing, notarization, Apple Silicon, and Intel jobs. Install the
   archive on a clean machine.
6. Set `PUBLISH_BINARY_RELEASES` to `true` for subsequent releases.

If binary publication fails, fix it with a new patch release. Never overwrite a
published asset.
