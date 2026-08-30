# Agent instructions

Follow [CONTRIBUTING.md](CONTRIBUTING.md) for development, tests, and pull
requests. This file only records rules coding agents get wrong.

## Pull request descriptions

Wrap Markdown files in this git tree to 80 columns. rumdl runs in
`pre-commit` and in CI. It does not lint GitHub.

Do not wrap GitHub pull request descriptions. Leave the lines long. GitHub
wraps them in the browser. Do not wrap `gh pr create --body` either.

Use [`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md).
Keep the Summary, Testing, and Checklist headings.

Never wrap or rewrite a Release Please pull request body.

## Pull request titles

Use a Conventional Commit title. This repository squash-merges, so that
title becomes the release commit.
