# Contributing

Bug reports, compatibility findings, documentation fixes, and focused pull
requests are welcome.

## Before opening an issue

- Search existing issues first.
- For a compatibility report, connect exactly one compatible AirPods or Beats
  device and run `airpods-control support-report`. Review the local report
  before deciding whether to open the GitHub form.
- Beats reports are welcome, but we have not verified support.
- Check the [device compatibility matrix](docs/compatibility.md) for verified
  capabilities and candidates that still need testing.
- For a bug, include the macOS version, device model, command, expected result,
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

### Development setup

Install [mise](https://mise.jdx.dev/). From the repository root, run:

```sh
mise install
```

This installs the development tools and versions listed in `mise.toml`. The
build still needs the macOS Command Line Tools or Xcode listed above.

You can run the full test suite with `mise run test`. It calls `make test`.

Build and run the device-independent test suite:

```sh
make clean
make test
```

`make test` builds both architectures when the installed toolchain supports
them. It then runs the shell CLI contract tests, the C signal-monitor race test,
and the Swift unit tests. Tests must not require AirPods or write device
settings.

For runtime-bypass changes, launch the built CLI and confirm the interpose
reports active. This stays out of `make test` because it depends on the
installed macOS:

```sh
make verify-runtime
```

Check the product-name catalog against the pairings macOS itself publishes:

```sh
make verify-catalog
```

This reads `public.bluetooth-vendor-product-id` from the system's CoreTypes
bundles and reports Apple audio devices known to macOS but missing from
`Sources/AirPodsControl/AppleAudioProducts.swift`. It stays out of `make test`
because the result depends on the installed macOS version. Run it when adding
hardware or after a major system upgrade. The catalog supplies readable names
for support reports; capability is always read from the device at runtime.

Test changes to live private-API behavior on supported hardware. Follow the
[hardware testing guide](docs/hardware-testing.md) before merging a discovery
change. State the macOS version and device in the pull request. Automated tests
must not write device settings. Update
[`docs/compatibility.md`](docs/compatibility.md) when a hardware check changes a
device or capability status.

### Source layout

- `Sources/AirPodsControl` contains the single Swift executable module.
  `SupportReportDocument` contains the data shared by the terminal and GitHub
  renderers. Keep capture, verdict classification, privacy filtering, and
  restoration interpretation out of the renderers.
- `Sources/AVBypass` contains the C source for the interpose dylib, which is
  built separately.
- `Sources/BypassProbe` contains the linked C probe that verifies the interpose
  after re-execution.
- `Sources/SignalMonitor` contains the C termination monitor linked into the
  executable and its Clang module header.
- `Tests/AirPodsControlTests` mirrors the Swift module's interfaces.
- `Tests/CLIContractTests` verifies the built executable's output and exit
  codes.
- `Tests/SignalMonitorTests` verifies cross-thread signal teardown directly in
  C.
- `Tests/ReleasePleaseTests` verifies that a Release Please pull request body
  still parses.
- `Tests/ResolvePrefixTests` verifies install-prefix path rules.
- `Tests/InstallFromSourceTests` verifies the source install script.
- `Tests/VerifyRuntimeTests` verifies the DYLD interpose on a built CLI.
- `version.txt` is the single source for the CLI and release version. The
  Makefile generates the corresponding Swift constant under `build/`.

The names follow Swift target conventions. The Makefile is the source of
truth for builds: it compiles architectures the toolchain supports, ad-hoc
signs both artifacts, and installs them together.

### Documentation

Markdown files in the repository follow rumdl's standard 80-column wrapping.
Do not wrap GitHub pull request descriptions. rumdl never sees them. Use
`mise run markdown-check` to check Markdown, or use `mise run markdown-format`
to format it. Run `mise exec -- pre-commit install` once per clone. Use
`mise exec -- pre-commit run --all-files` to format and check the full Markdown
set.

## Pull requests

- Use a [Conventional Commit](https://www.conventionalcommits.org/) pull request
  title. The repository squash-merges pull requests, so that title becomes the
  commit used to generate versions and release notes.
- Fill the pull request template. Do not wrap the description to 80 columns.
- Keep changes focused and explain the user-visible reason for them.
- Add or update tests for behavior changes.
- Update CLI help and the affected user-facing documentation when the interface
  changes.
- Preserve the script-friendly stdout and exit-code contract.
- Avoid new runtime dependencies unless they are essential.

Maintainers should follow [RELEASING.md](RELEASING.md) for releases and Homebrew
formula updates.

By contributing, you agree to license your contribution under the repository's
[MIT License](LICENSE).
