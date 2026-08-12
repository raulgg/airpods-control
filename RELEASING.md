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

## Update the Homebrew tap

Until the automated handoff is enabled:

1. Wait until the GitHub release is public.
2. Create `feat/airpods-control-VERSION` from the tap's current `main`.
3. Download the release's tag archive twice, compare the files byte for byte,
   and calculate its SHA-256.
4. Update `Formula/airpods-control.rb` with the new tag URL and checksum. Keep
   the source build, Apple toolchain overrides, exact read-only version test,
   and absence of a `bottle` block.
5. Open a tap pull request. Merge it with squash only after every required
   `brew test-bot` check passes. Do not use `brew pr-pull`; this tap does not
   publish bottles.
