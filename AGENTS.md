# Agent instructions

Follow [CONTRIBUTING.md](CONTRIBUTING.md) for development, tests, and pull
requests. This file only records rules coding agents get wrong.

## GitHub Markdown is not rumdl Markdown

Wrap Markdown files that live in this git tree to rumdl's 80-column limit.
`pre-commit` and CI rumdl only lint those files.

Do not wrap GitHub pull request bodies, issue comments, or review comments.
Those are unwrapped GitHub Markdown. Do not wrap the `--body` of
`gh pr create`, `gh pr comment`, or `gh issue comment`. Fill
[`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md): keep
the `## Summary`, `## Testing`, and `## Checklist` headings, and write
normal prose under them.

Never wrap or rewrite a Release Please pull request body.

## Pull request titles

Use a Conventional Commit title. This repository squash-merges, so that
title becomes the release commit.
