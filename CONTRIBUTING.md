# Contributing

Bug reports, compatibility findings, documentation fixes, and focused pull requests are welcome.

## Before opening an issue

- Search existing issues first.
- For a bug, include the macOS version, AirPods model, command used, expected result, actual result, and exit code.
- Re-run the command with `--debug` when possible and attach stderr. Redact device names and other personal information.
- Use [private vulnerability reporting](https://github.com/raulgg/airpods-control/security/advisories/new) for security concerns. Do not disclose sensitive vulnerability details in a public issue.

This project uses an undocumented macOS API, so a macOS update can break compatibility. Report these regressions with the same details as other bugs.

## Development

You need:

- macOS
- Command Line Tools or Xcode
- `make`, `clang`, `swiftc`, `lipo`, and `codesign`

Build and run the device-independent test suite:

```sh
make clean
make test
```

`make test` builds both architectures when the installed toolchain supports them, runs the shell CLI contract tests, and runs the Swift unit tests. Tests must not require AirPods or write device settings.

Test changes to live private-API behavior manually on supported hardware. State the macOS version and device in the pull request. Automated tests must not write device settings.

## Pull requests

- Keep changes focused and explain the user-visible reason for them.
- Add or update tests for behavior changes.
- Keep `README.md`, `docs/airpods-control.1`, CLI help, and JSON examples in sync when the interface changes.
- Preserve the script-friendly stdout and exit-code contract.
- Avoid new runtime dependencies unless they are essential.

By contributing, you agree that your contribution is licensed under the repository's [MIT License](LICENSE).
