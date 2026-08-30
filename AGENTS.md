# Agent instructions

Follow [CONTRIBUTING.md](CONTRIBUTING.md).

## Quality checks

- `make test`. Do not write device settings in tests.
- `make verify-runtime` when changing the bypass or interpose.
- `make verify-catalog` when changing `AppleAudioProducts.swift`.
- `pre-commit run --all-files` when changing Markdown.
- Read `docs/hardware-testing.md` before merging live private-API work.
- Required checks: `Build, test, and verify install`, `rumdl`,
  `Validate title`.

## Markdown

- Wrap repo Markdown to 80 columns. rumdl lints git-tree files only.
- Do not wrap GitHub PR descriptions.

## Pull requests

- Conventional Commit title.
- Fill `.github/PULL_REQUEST_TEMPLATE.md`.
- Do not rewrite Release Please PR bodies.
