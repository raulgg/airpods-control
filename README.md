# airpods-control

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/airpods-control-banner-dark.png">
    <source media="(prefers-color-scheme: light)" srcset=".github/assets/airpods-control-banner-light.png">
    <img alt="airpods-control — AirPods controls, straight from your terminal." src=".github/assets/airpods-control-banner-light.png" width="100%">
  </picture>
  <br>
  <a href="https://github.com/raulgg/airpods-control/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/raulgg/airpods-control/ci.yml?branch=main&amp;style=flat-square&amp;label=CI"></a>
  <a href="https://github.com/raulgg/airpods-control/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/raulgg/airpods-control?style=flat-square&amp;color=0a0a0c"></a>
  <a href="#compatibility"><img alt="Tested on macOS Tahoe 26" src="https://img.shields.io/badge/tested-macOS%20Tahoe%2026-0a0a0c?style=flat-square&amp;logo=apple&amp;logoColor=white"></a>
  <a href="https://github.com/raulgg/homebrew-tap/blob/main/Formula/airpods-control.rb"><img alt="Homebrew" src="https://img.shields.io/badge/brew-raulgg%2Ftap%2Fairpods--control-FBB040?style=flat-square&amp;logo=homebrew&amp;logoColor=black"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square"></a>
</div>

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
- A supported pair of AirPods connected as an output device.
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

## Credits

[NoiseBuddy](https://github.com/insidegui/NoiseBuddy) by Guilherme Rambo
documented the AVFoundation technique used by this project.

`airpods-control` is an independent tool and is not endorsed by Apple. AirPods
and AirPods Pro are trademarks of Apple Inc.

## License

MIT. See [LICENSE](LICENSE).
