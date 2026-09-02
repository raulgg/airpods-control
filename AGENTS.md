# Agent instructions

Follow [CONTRIBUTING.md](CONTRIBUTING.md). Register common pitfalls
here and avoid them.

## Support-report write tests

- Probe listening modes in reverse canonical order (noise cancellation,
  Adaptive, Transparency, Off). Off may fall back to Transparency; probing
  Off first makes the Transparency write already-current and inconclusive.

## Quality checks

- Do not skip `make test`.
- Leave `verify-runtime` and `verify-catalog` out of `make test`.
- Do not add tests that need AirPods or write device settings.
- Do not rename `Build, test, and verify install` or turn it into a matrix.

## Markdown

- rumdl 80-column wrap is for files in git. Not for GitHub PR descriptions.

## Pull requests

- Conventional Commit title. That title becomes the squash-merge commit.
- Fill the PR template.
- Do not rewrite Release Please PR bodies.

## Release Please

- Do not hand-edit `version.txt`, `.release-please-manifest.json`, or
  `CHANGELOG.md`. Let the release pull request do that.
- Notes are `feat`, `fix`, and `perf` only. Hide `ci`, `chore`, `deps`,
  `revert`, and the other non-user types in `changelog-sections`. After
  changing that config, close the open draft release PR so a fresh one is
  generated.
- Cherry-pick a patch onto `release/X.Y`. Do not merge a maintenance
  branch into `main`.
- Do not create a git tag with the same name as a maintenance branch.
