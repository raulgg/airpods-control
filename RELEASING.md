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
3. Download the seven-day Actions artifact if the package needs inspection.

Do not attach the ad-hoc-signed experimental artifact to a GitHub release.
