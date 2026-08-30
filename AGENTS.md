# Agent instructions

Follow [CONTRIBUTING.md](CONTRIBUTING.md).

## Quality checks

- Run `make test`. Tests must not write device settings.
- Bypass or interpose changes: also `make verify-runtime`.
- Product-name catalog changes: also `make verify-catalog`.
- Markdown changes: `pre-commit run --all-files` (rumdl).
- Private-API discovery: `docs/hardware-testing.md`.
- GitHub: `Build, test, and verify install`, `rumdl`, `Validate title`.

## Markdown

- Wrap repo Markdown to 80 columns. rumdl lints git-tree files only.
- Do not wrap GitHub PR descriptions.

## Pull requests

- Title: Conventional Commits.
- Body: `.github/PULL_REQUEST_TEMPLATE.md`.
- Do not rewrite Release Please PR bodies.
