# Contributing

Bug reports, compatibility findings, documentation fixes, and focused pull requests are welcome.

## Before opening an issue

- Search existing issues first.
- For a compatibility report, connect AirPods and run `airpods-control support-report`. Check the local report before choosing whether to open the GitHub form. The CLI prefills the generated report and title; add optional notes and complete the privacy confirmation before submitting.
- Beats owners can use the same command. We welcome the reports, but have not verified Beats support.
- Check the [device compatibility matrix](docs/compatibility.md) for verified capabilities and candidates that still need testing.
- For a bug, include the macOS version, AirPods model, command, expected result, actual result, and exit code.
- Re-run the command with `--debug` when possible and attach stderr. Redact device names and other personal information.
- Report security concerns through [private vulnerability reporting](https://github.com/raulgg/airpods-control/security/advisories/new). Do not disclose sensitive vulnerability details in a public issue.

This project uses an undocumented macOS API, so an update can break compatibility. Report these regressions with the same details as other bugs.

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

`make test` builds both architectures when the installed toolchain supports them. It then runs the shell CLI contract tests, the C signal-monitor race test, and the Swift unit tests. Tests must not require AirPods or write device settings.

Check the product-name catalog against the pairings macOS itself publishes:

```sh
make verify-catalog
```

This reads `public.bluetooth-vendor-product-id` from the system's CoreTypes bundles and reports any Apple audio device the system knows about that `Sources/AirPodsControl/AppleAudioProducts.swift` does not. It stays out of `make test` because the answer depends on the macOS version of whoever runs it. Run it when adding hardware or after a major system upgrade. The catalog only supplies readable names for support reports; capability is always read from the device at runtime.

Test changes to live private-API behavior manually on supported hardware. State the macOS version and device in the pull request. Automated tests must not write device settings. Update [`docs/compatibility.md`](docs/compatibility.md) when a hardware check changes a device or capability status.

### Live one-earbud AVRouting regression check

The private-audio unit tests can model an AirPods endpoint whose listening-mode capabilities disappear or whose plural routing list omits the current device, but only connected hardware can verify private-API behavior across a placement change. Run this check on the same Mac and AirPods before merging a discovery change.

1. Build once with `make`, wear both earbuds, and confirm the AirPods are the selected macOS input and output devices.
2. Create an owner-only capture directory, then capture a capability baseline. Run all commands in the same shell and replace `My AirPods` if the customized name differs:

   ```sh
   capture_parent="${TMPDIR:-/tmp}"
   capture_previous_umask="$(umask)"
   umask 077
   capture_dir="$(mktemp -d "${capture_parent%/}/airpods-control.XXXXXX")" || exit 1
   chmod 700 "$capture_dir"
   printf 'Private capture directory: %s\n' "$capture_dir"

   build/airpods-control --device "My AirPods" listening-mode get --json --debug \
     >"$capture_dir/both-listening-mode.json" \
     2>"$capture_dir/both.debug.log"
   build/airpods-control --device "My AirPods" listening-mode list --json --debug \
     >"$capture_dir/both-listening-modes.json" \
     2>>"$capture_dir/both.debug.log"
   build/airpods-control --device "My AirPods" conversation-awareness get --json --debug \
     >"$capture_dir/both-conversation-awareness.json" \
     2>>"$capture_dir/both.debug.log"
   ```

3. Remove one earbud without putting it in the case. Verify in System Settings that the AirPods remain both the selected input and selected output, then run:

   ```sh
   build/airpods-control --device "My AirPods" listening-mode get --json --debug \
     >"$capture_dir/one-listening-mode.json" \
     2>"$capture_dir/one.debug.log"
   build/airpods-control --device "My AirPods" listening-mode list --json --debug \
     >"$capture_dir/one-listening-modes.json" \
     2>>"$capture_dir/one.debug.log"
   build/airpods-control --device "My AirPods" conversation-awareness get --json --debug \
     >"$capture_dir/one-conversation-awareness.json" \
     2>>"$capture_dir/one.debug.log"
   umask "$capture_previous_umask"
   ```

   If you stop before completing this block, restore the saved mask with `umask "$capture_previous_umask"`.

4. Compare the matching JSON files and these debug keys in `both.debug.log` and `one.debug.log`:

   - `discovery.context_plural_count`
   - `discovery.context_singular_present`
   - `discovery.candidate_*_sources`
   - `device.*.available_modes`
   - `device.*.transient_empty_modes`

5. If the one-earbud run selects the device, test only settings macOS currently permits. Toggle Conversation Awareness away from its initial value and back. Switch to Transparency and restore the initial listening mode. Test Noise Cancellation last: unless **Noise Cancellation with One AirPod** is enabled in Accessibility settings, a rejected or unverified ANC write is expected.

The regression check passes when the plural or singular system-audio context retains the endpoint and the CLI can apply and read back every setting that System Settings permits in the same state. The implementation intentionally does not add another discovery backend or make `--debug` change which devices are discovered.

The debug logs can contain the customized device name and source-build or home paths. Review and redact the capture before sharing it, then delete the private capture directory when the comparison is complete.

### Source layout

- `Sources/AirPodsControl` contains the single Swift executable module. `SupportReportDocument` contains the data shared by the terminal and GitHub renderers. Keep capture, verdict classification, privacy filtering, and restoration interpretation out of the renderers.
- `Sources/AVBypass` contains the C source for the interpose dylib, which is built separately.
- `Sources/SignalMonitor` contains the C termination monitor linked into the executable and its Clang module header.
- `Tests/AirPodsControlTests` mirrors the Swift module's interfaces.
- `Tests/CLIContractTests` verifies the built executable's output and exit codes.
- `Tests/SignalMonitorTests` verifies cross-thread signal teardown directly in C.

The names follow Swift target conventions. The Makefile is still the source of truth for builds because release builds combine architectures, sign both artifacts, and install them together.

## Pull requests

- Keep changes focused and explain the user-visible reason for them.
- Add or update tests for behavior changes.
- Keep `docs/cli.md`, `docs/man/airpods-control.1`, CLI help, and the README's quick-start examples in sync when the interface changes.
- Preserve the script-friendly stdout and exit-code contract.
- Avoid new runtime dependencies unless they are essential.

Maintainers should follow [RELEASING.md](RELEASING.md) for signed releases and Homebrew formula updates.

By contributing, you agree to license your contribution under the repository's [MIT License](LICENSE).
