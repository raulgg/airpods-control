# Agent instructions

Follow [CONTRIBUTING.md](CONTRIBUTING.md). Agent failure modes only.

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
