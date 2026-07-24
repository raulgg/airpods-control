# Contributing

Bug reports, compatibility findings, documentation fixes, and focused pull
requests are welcome.

## Before opening an issue

- Search existing issues first.
- For a bug, include the macOS version, AirPods model, command, expected result,
  actual result, and exit code.
- Re-run the command with `--debug` when possible and attach stderr. Redact
  device names and other personal information.
- Report security concerns through
  [private vulnerability reporting](https://github.com/raulgg/airpods-control/security/advisories/new).
  Do not disclose sensitive vulnerability details in a public issue.

This project uses an undocumented macOS API, so an update can break
compatibility. Report these regressions with the same details as other bugs.

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

`make test` builds both architectures when the installed toolchain supports
them. It then runs the shell CLI contract tests and Swift unit tests. Tests
must not require AirPods or write device settings.

Test changes to live private-API behavior manually on supported hardware.
State the macOS version and device in the pull request. Automated tests must
not write device settings.

### Source layout

- `Sources/AirPodsControl` contains the single Swift executable module.
- `Sources/AVBypass` contains the C source for the interpose dylib, which is
  built separately.
- `Tests/AirPodsControlTests` mirrors the Swift module's interfaces.
- `Tests/CLIContractTests` verifies the built executable's output and exit codes.

The names follow Swift target conventions. The Makefile is still the source of
truth for builds because release builds combine architectures, sign both
artifacts, and install them together.

## Pull requests

- Keep changes focused and explain the user-visible reason for them.
- Add or update tests for behavior changes.
- Keep `docs/cli.md`, `docs/man/airpods-control.1`, CLI help, and the README's
  quick-start examples in sync when the interface changes.
- Preserve the script-friendly stdout and exit-code contract.
- Avoid new runtime dependencies unless they are essential.

Maintainers should follow [RELEASING.md](RELEASING.md) for signed releases
and Homebrew formula updates.

By contributing, you agree to license your contribution under the repository's
[MIT License](LICENSE).
