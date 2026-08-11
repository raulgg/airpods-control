# airpods-control

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/airpods-control-banner-dark.png">
    <source media="(prefers-color-scheme: light)" srcset=".github/assets/airpods-control-banner-light.png">
    <img alt="airpods-control: AirPods controls, straight from your terminal." src=".github/assets/airpods-control-banner-light.png" width="100%">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/raulgg/airpods-control/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/raulgg/airpods-control/ci.yml?branch=main&amp;style=flat-square&amp;label=CI"></a>&nbsp;
  <a href="https://github.com/raulgg/airpods-control/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/raulgg/airpods-control?style=flat-square&amp;color=0a0a0c"></a>&nbsp;
  <a href="#compatibility"><img alt="Tested on macOS Tahoe 26" src="https://img.shields.io/badge/tested-macOS%20Tahoe%2026-0a0a0c?style=flat-square&amp;logo=apple&amp;logoColor=white"></a>&nbsp;
  <a href="https://github.com/raulgg/homebrew-tap/blob/main/Formula/airpods-control.rb"><img alt="Homebrew" src="https://img.shields.io/badge/brew-raulgg%2Ftap%2Fairpods--control-FBB040?style=flat-square&amp;logo=homebrew&amp;logoColor=black"></a>&nbsp;
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square"></a>
</p>

Control AirPods listening modes and Conversation Awareness from the command line
without Control Center, a menu bar app, or Accessibility permission.

```console
$ airpods-control status
My AirPods Pro:
  Listening mode: transparency
  Conversation Awareness: off
  Selected as audio output: yes
  Selected as audio input: no
$ airpods-control listening-mode set noise-cancellation
ok
```

`airpods-control` talks directly to private macOS audio interfaces used by
AirPods. Successful changes take effect immediately and display the same
on-screen banner as a stem press. Each operational command performs one
operation and exits without polling in the background or automating the UI.

## Features

- Read, set, list, or cycle the `off`, `transparency`, `adaptive`, and
  `noise-cancellation` listening modes.
- Read or set Conversation Awareness.
- Report listening mode, Conversation Awareness, and whether each eligible
  connected AirPods or Beats device represented by Core Audio is selected as
  the macOS audio output or input with one `status` command.
- Select a compatible output device by exact name.
- Use it from scripts, hotkeys, Stream Decks, Shortcuts, or `launchd`.
  Operational commands have stable stdout, documented exit codes, JSON output,
  and opt-in debug diagnostics.

## Requirements

- macOS (developed and tested on Tahoe 26).
- A compatible AirPods or Beats device connected over Bluetooth. Individual
  resource commands and `support-report` also require the private output-device
  interface described in [device compatibility](docs/compatibility.md).
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
its companion `avbypass.dylib`. Run `sudo make uninstall` to remove them.

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

# Read status for every eligible device represented by Core Audio
airpods-control status

# Target a device or request structured output
airpods-control --device "My AirPods Pro" listening-mode get
airpods-control status --device "My AirPods Pro" --json
```

`listening-mode` can be shortened to `lm`, and `conversation-awareness` to `ca`;
`status` has no alias. Without `--device`, `status` reports every eligible
AirPods or Beats record derived from the currently available Core Audio device
list, even when it is not the selected audio output. The individual resource
commands continue to use the first compatible output device. Run
`airpods-control --help` for built-in help. The
[complete CLI reference](docs/cli.md) covers aliases, JSON output, diagnostics,
write verification, and exit codes. After installation, you can also run
`man airpods-control`.

## Documentation

- [CLI reference](docs/cli.md)
- [Device compatibility](docs/compatibility.md)
- [Hardware testing](docs/hardware-testing.md)
- [Security and trust model](SECURITY.md)
- [Contributing](CONTRIBUTING.md)

## How it works

Feature commands use the private `AVOutputDevice` API in
`AVRouting.framework`. `status` uses a separate Core Audio inventory so it can
find an eligible device even when that device is not the selected output.

The inventory starts with macOS's public list of available Core Audio devices.
It accepts an ordinary, nonaggregate classic-Bluetooth endpoint when the
endpoint is alive and ready, has an audio stream, and maps to an
`IOBluetoothDevice`. An undocumented HAL property identifies Apple audio
hardware. If that property is unavailable, `status` falls back to an allowlisted
Apple or Beats manufacturer. Input and output endpoints form one record only
when their mapped objects compare equal in both directions. The output endpoint
supplies the preferred name. Names are for display and `--device` matching, not
identity.

Input and output selection are checked independently. For each direction,
`status` maps the ordinary default Core Audio endpoint and compares the result
with the record's mapped Bluetooth object. Aggregate routes and known unrelated
transports produce `no`. Bluetooth LE, USB, unknown transports, missing
properties, and unavailable mappings produce `unknown`. A failed read or mapper
call is reported as a read error. This includes failures while reading the
default route, device class, or transport.

An inactive endpoint may still expose its current listening mode through an
undocumented HAL property. The mapped Bluetooth object is the fallback when the
HAL property is unavailable or neutral, or when its read fails. The active AV
endpoint has the highest priority when it can be joined safely to the default
output. Unknown AV or HAL values, and conflicting HAL values, leave the mode
`unknown` rather than falling back.

The active-output join translates
`AVOutputContext.associatedAudioDeviceID` through Core Audio and compares the
result with the stable default output. That output's mapped Bluetooth object
must match the status record. The probe also samples `AVOutputDevice.deviceID`
before and after to catch a route change. Conversation Awareness is `unknown`
when this join is unavailable.

Core Audio handles and the identifiers used by the enrichment probe stay inside
the process. The CLI does not parse or log them. Inventory and selection do not
read Bluetooth addresses, Core Audio UIDs, or private route identifiers, and
raw HAL values are not emitted. `support-report` does not use this status path.

To reach the shared system audio context used by feature controls, the
`airpods-control` process loads the small interpose library in
[`Sources/AVBypass/bypass.c`](Sources/AVBypass/bypass.c). The library satisfies
one private entitlement check inside that process and passes every other
entitlement query through unchanged. It does not elevate privileges or affect
other processes.

The interpose requires an ad-hoc-signed binary because the hardened runtime's
library validation blocks it. The project therefore distributes source instead
of prebuilt binaries. Review the source and the
[security documentation](SECURITY.md) before building.

## Compatibility

Apple can change or remove this private API in any macOS update. Compatibility
varies by device, firmware, and macOS version; see the [device and capability
matrix](docs/compatibility.md) for current results. Reports are welcome, but a
report does not by itself establish support.

To share compatibility details:

1. Connect exactly one compatible AirPods or Beats device as a macOS output
   device.
2. Run `airpods-control support-report`.
3. Choose whether to run the consented write tests when asked.
4. Review the report, add any safe optional notes, complete the privacy
   confirmation, and submit the GitHub issue if you choose to open it.

`support-report` builds the report locally and prints it before offering to open
GitHub. It never reads the customizable device name, firmware version, serial
numbers, Bluetooth/MAC addresses, account data, or raw system dumps and logs. It
does not enumerate the Core Audio status inventory, query selected audio routes,
call the selection mapper, run active-output enrichment, or read routing
identifiers. It does not use the clipboard, send telemetry, or submit a report.
Opening the prefilled form is your choice, and GitHub still requires you to
review and submit the issue.

The optional write tests run only with your consent (the interactive question or
`--with-write-tests`). They temporarily switch through the advertised listening
modes recognized by this CLI, toggle Conversation Awareness, and then try to
restore the captured initial settings. The tests may be disruptive: mode
switches are audible and noise control changes while the device is worn. Do not
run them during a call. Consent only if you accept this. Without consent,
`support-report` does not change device settings or intentionally interrupt
audio.

The [CLI reference](docs/cli.md#contributor-compatibility-report) documents the
exact report contents and privacy rules, and its
[write-test section](docs/cli.md#consented-write-tests) covers the plan, skip
rules, verdict vocabulary, restoration behavior, and exit codes.

## Credits

[NoiseBuddy](https://github.com/insidegui/NoiseBuddy) by Guilherme Rambo
documented the AVFoundation technique used by this project.

`airpods-control` is an independent tool and is not endorsed by Apple. AirPods
and AirPods Pro are trademarks of Apple Inc.

## License

MIT. See [LICENSE](LICENSE).
