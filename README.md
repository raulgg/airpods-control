# airpods-control

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/airpods-control-banner-dark.png">
    <source media="(prefers-color-scheme: light)" srcset=".github/assets/airpods-control-banner-light.png">
    <img alt="airpods-control — AirPods controls, straight from your terminal." src=".github/assets/airpods-control-banner-light.png" width="100%">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/raulgg/airpods-control/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/raulgg/airpods-control/ci.yml?branch=main&amp;style=flat-square&amp;label=CI"></a>&nbsp;
  <a href="https://github.com/raulgg/airpods-control/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/raulgg/airpods-control?style=flat-square&amp;color=0a0a0c"></a>&nbsp;
  <a href="#compatibility"><img alt="Tested on macOS Tahoe 26" src="https://img.shields.io/badge/tested-macOS%20Tahoe%2026-0a0a0c?style=flat-square&amp;logo=apple&amp;logoColor=white"></a>&nbsp;
  <a href="https://github.com/raulgg/homebrew-tap/blob/main/Formula/airpods-control.rb"><img alt="Homebrew" src="https://img.shields.io/badge/brew-raulgg%2Ftap%2Fairpods--control-FBB040?style=flat-square&amp;logo=homebrew&amp;logoColor=black"></a>&nbsp;
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square"></a>
</p>

Control AirPods listening modes and Conversation Awareness from the command
line without Control Center, a menu bar app, or Accessibility permission.

```console
$ airpods-control listening-mode set noise-cancellation
ok
$ airpods-control conversation-awareness get
off
```

`airpods-control` talks directly to the macOS system audio daemon through the
private AVFoundation API used by AirPods. Changes take effect immediately and
display the same on-screen banner as a stem press. The command performs one
operation and exits. It does not poll in the background or automate the UI.

## Features

- Read, set, list, or cycle the `off`, `transparency`, `adaptive`, and
  `noise-cancellation` listening modes.
- Read or set Conversation Awareness.
- Select a compatible output device by exact name.
- Use it from scripts, hotkeys, Stream Decks, Shortcuts, or `launchd`. Stdout
  is stable, exit codes are documented, JSON is available, and stderr
  diagnostics are opt-in.

## Requirements

- macOS (developed and tested on Tahoe 26).
- A compatible pair of AirPods connected as an output device. See
  [device compatibility](docs/compatibility.md).
- Command Line Tools (`clang` and `swiftc`) to build from source. Install them
  with `xcode-select --install`; full Xcode is not required.

## Install

### Homebrew

```sh
brew install raulgg/tap/airpods-control
```

The formula downloads the source and compiles it locally. There are no prebuilt
binaries.

### From source

```sh
git clone https://github.com/raulgg/airpods-control
cd airpods-control
make
sudo make install
```

By default, `make install` uses `/usr/local`. It honors `PREFIX` and `DESTDIR`,
so a user-local installation needs no `sudo`:

```sh
make install PREFIX="$HOME/.local"
```

The build produces a universal (arm64 + x86_64), ad-hoc-signed executable and
its companion `avbypass.dylib`. Run `sudo make uninstall` to uninstall,
`make clean` to remove build artifacts, or `make test` to run the
device-independent test suite.

## Quick start

```sh
# Read or change the listening mode
airpods-control listening-mode get
airpods-control listening-mode set noise-cancellation

# List supported modes or cycle between them
airpods-control listening-mode list
airpods-control listening-mode cycle

# Read or change Conversation Awareness
airpods-control conversation-awareness get
airpods-control conversation-awareness set off

# Target a device or request structured output
airpods-control --device "My AirPods Pro" listening-mode get
airpods-control listening-mode get --json
```

`listening-mode` can be shortened to `lm`, and `conversation-awareness` to
`ca`. Run `airpods-control --help` for built-in help. The
[complete CLI reference](docs/cli.md) covers aliases, JSON output, diagnostics,
write verification, and exit codes. After installation, you can also run
`man airpods-control`.

## Documentation

- [CLI reference](docs/cli.md)
- [Device compatibility](docs/compatibility.md)
- [Security and trust model](SECURITY.md)
- [Contributing](CONTRIBUTING.md)

## How it works

macOS exposes these controls through the private, undocumented
`AVOutputDevice` API in `AVRouting.framework`. The shared system audio context
requires the private `com.apple.avfoundation.allow-system-wide-context`
entitlement.

The small interpose library in
[`Sources/AVBypass/bypass.c`](Sources/AVBypass/bypass.c) satisfies that one
entitlement check inside the short-lived `airpods-control` process. It passes
all other entitlement queries through unchanged. The library does not elevate
privileges or affect other processes. It leaves system protections in place,
does not access user data, and makes no network connections.

The interpose requires an ad-hoc-signed binary. A notarized binary with the
hardened runtime enforces library validation, which blocks the inserted
library. For that reason, the project is distributed as source. Review the
[security documentation](SECURITY.md) and the source before building.

## Compatibility

Apple can change or remove this private API in any macOS update. The tool
probes known selector variants and checks each required selector before use. If
a capability is unavailable, it reports `no-device` or `unsupported` instead
of sending an unrecognized selector.

Use `--debug` to distinguish a missing private selector from an unavailable
device or hardware feature.

The CLI has only been verified with AirPods Pro 3. Other AirPods may work when
macOS exposes the same private audio capabilities. We have not verified Beats,
but reports are welcome. See the
[device and capability matrix](docs/compatibility.md).

To share compatibility details:

1. Connect exactly one compatible AirPods or Beats device as a macOS output
   device.
2. Run `airpods-control support-report`.
3. Choose whether to run the consented write tests when asked.
4. Read the report. You can then open a prefilled GitHub issue, edit it, and
   submit it.

The read-only compatibility report includes only the normalized model
identifier, the advertised listening modes (including modes this CLI version
does not recognize), the advertised Conversation Awareness capability, whether
the listening-mode and Conversation Awareness queries answer, whether macOS
exposes their setters, the macOS version, and the CLI version. The model name is
resolved locally from the Bluetooth product ID embedded in the model identifier.
A consented run reads setting values locally only to plan, verify, and restore
the write tests. If restoration cannot be verified, the terminal names the
final state so you can restore it manually. The prefilled issue omits
initial-state and restoration identifiers.

The command never reads the customizable device name, firmware version, serial
numbers, Bluetooth/MAC addresses, account data, or raw logs and system dumps.
Because it does not read names or accept `--device`, it requires exactly one
compatible output device and exits without a report when selection is
ambiguous.
Without write-test consent, it does not change device settings or intentionally
interrupt audio. Regardless of the write-test choice, it never uses the
clipboard, sends telemetry, or submits a report. If it cannot identify a
connected device, it prints a message and stops without opening the browser.

The optional write tests, run only after you accept an explicit prompt or pass
`--with-write-tests`, switch through the advertised listening modes recognized
by this CLI and toggle Conversation Awareness away from the captured initial
state and back. The plan is captured once before any write and, interactively,
displayed before consent. If a setting changes while consent is pending, or its
initial state cannot be restored safely, that setting is skipped without
writing. Each listening mode is held for about two seconds before the next
write. After normal completion or a setter error, the command makes a
best-effort restoration attempt; an unverified restoration names the final
state and exits `3`. An externally delivered SIGINT or SIGTERM caught during
these tests stops further writes, attempts restoration first, suppresses the
issue-opening prompt, and then exits `130` or `143`, respectively. The tests
can be disruptive (audible switches, noise control changes while worn), so
consent only if you accept that. See the
[CLI reference](docs/cli.md#consented-write-tests) for details.

Reports from other AirPods and Beats owners are welcome. A report does not make
a Beats device supported.

## Credits

[NoiseBuddy](https://github.com/insidegui/NoiseBuddy) by Guilherme Rambo
documented the AVFoundation technique used by this project.

`airpods-control` is an independent tool and is not endorsed by Apple. AirPods
and AirPods Pro are trademarks of Apple Inc.

## License

MIT. See [LICENSE](LICENSE).
