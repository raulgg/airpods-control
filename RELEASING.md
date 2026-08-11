# Releasing

`airpods-control` publishes source releases from this repository. Its Homebrew
formula lives in
[`raulgg/homebrew-tap`](https://github.com/raulgg/homebrew-tap) and builds each
release from source. Do not add a second formula to this repository.

## Repository setup

Release Please needs a fine-grained personal access token stored as the
`RELEASE_PLEASE_TOKEN` Actions secret. Limit it to this repository with read and
write access to contents, issues, and pull requests. A pull request created with
the default `GITHUB_TOKEN` would not start the repository's required workflows.

Configure GitHub to:

- allow squash merging and use the pull request title as the default squash
  commit message;
- require CI, Quality Checks, and PR Title on `main`;
- prevent updates and deletions of tags matching `v*`.

The release workflow creates tags, so tag creation must remain allowed. A tag
points to a commit that passed the protected `main` pull request workflow; tags
are not moved or reused. Automated tags are not maintainer GPG-signed: protected
`main` and the protected tag namespace replace that manual trust boundary.

## Version policy

Pull request titles follow Conventional Commits. While the project is below
`1.0.0`, Release Please applies these version changes:

- `fix` creates a patch release;
- `feat` creates a minor release;
- a title containing `!` creates a minor release;
- documentation, chores, CI, builds, refactors, and tests do not initiate a
  release.

Release Please updates `version.txt` and `CHANGELOG.md` together. The Makefile
generates the Swift version constant, and tests and CI derive their expectations
from `version.txt`.

## Publish a release

1. Merge normal pull requests into `main` using squash merge. Release Please
   opens or refreshes its release pull request when a releasable change lands.
2. Review the proposed version and `CHANGELOG.md`. Merging this protected pull
   request is the release approval boundary.
3. Release Please creates the protected `vVERSION` tag and GitHub release. The
   release uses GitHub's automatic source archives; there is no duplicate source
   asset.

If the workflow fails after the release pull request merges, rerun its failed
job. Never move, delete, or recreate a published tag. Correct bad source with a
new patch release.

## Update the Homebrew tap

Until the automated handoff is enabled, update the tap after the GitHub release
is public:

1. Create `feat/airpods-control-VERSION` from the tap's current `main`.
2. Download the release's tag archive twice, compare the files byte for byte,
   and calculate its SHA-256.
3. Update `Formula/airpods-control.rb` with the new tag URL and checksum. Keep
   the source build, Apple toolchain overrides, exact read-only version test,
   and absence of a `bottle` block.
4. Open a tap pull request. Merge it with squash only after every required
   `brew test-bot` check passes. Do not use `brew pr-pull`; this tap does not
   publish bottles.

Packaging tests must remain read-only and must never change AirPods settings. A
failed tap update does not roll back or block the upstream GitHub release. Fix
the formula or rerun its updater instead.
