# airpods-control

[![CI](https://github.com/raulgg/airpods-control/actions/workflows/ci.yml/badge.svg)](https://github.com/raulgg/airpods-control/actions/workflows/ci.yml)

Control your AirPods listening mode and Conversation Awareness from the command line without using Control Center, a menu bar app, or Accessibility permission.

```console
$ airpods-control listening-mode set noise-cancellation
ok
$ airpods-control conversation-awareness get
off
```

`airpods-control` talks directly to the macOS system audio daemon through the private AVFoundation API used by AirPods. Mode changes take effect immediately and display the same on-screen banner as a stem press. The tool does not poll in the background, synthesize clicks, or automate the UI.

## What it does

- Read, set, list, or cycle the `off`, `transparency`, `adaptive`, and `noise-cancellation` listening modes.
- Read or set Conversation Awareness.
- Select a compatible output device by exact name.
- Use single-token stdout, documented exit codes, optional JSON, and opt-in stderr diagnostics from scripts. The command works with hotkeys, Stream Decks, Shortcuts, and `launchd` jobs.

Because it talks to the audio daemon instead of driving the UI, it needs no Accessibility or Automation permission. Each invocation performs one operation and exits.

## Requirements

- macOS (developed and tested on Tahoe 26).
- Command Line Tools for the build (`clang` and `swiftc`). Install them with `xcode-select --install`. Full Xcode is not required.
- A supported pair of AirPods connected as the current output device.

## Install

### Homebrew (build-from-source)

```sh
brew install raulgg/tap/airpods-control
```

The formula downloads the source and compiles it locally. It does not download a prebuilt binary. See [How it works](#how-it-works). Homebrew needs Command Line Tools or Xcode to run `swiftc`.

### From source

```sh
git clone https://github.com/raulgg/airpods-control
cd airpods-control
make
sudo make install            # installs to /usr/local by default
```

`make` produces a universal (arm64 + x86_64), ad-hoc-signed `build/airpods-control` and its companion `build/avbypass.dylib` using only Command Line Tools.

`make install` honors `PREFIX` and `DESTDIR`:

```sh
make install PREFIX="$HOME/.local"       # no sudo needed for a user prefix
```

It lays the files out as:

```
<PREFIX>/libexec/airpods-control/airpods-control
<PREFIX>/libexec/airpods-control/avbypass.dylib
<PREFIX>/bin/airpods-control -> ../libexec/airpods-control/airpods-control   # relative symlink
<PREFIX>/share/man/man1/airpods-control.1
```

The binary resolves the symlink to its real path and loads `avbypass.dylib` from the same directory.

Run `sudo make uninstall` to uninstall it and `make clean` to remove build artifacts. `make test` runs device-independent checks for the CLI contract, parser, selector discovery, and device selection.

## Usage

```
airpods-control [--device NAME] listening-mode get [--json] [--debug]
airpods-control [--device NAME] listening-mode set <mode> [--json] [--debug]
airpods-control [--device NAME] listening-mode list [--json] [--debug]
airpods-control [--device NAME] listening-mode cycle [--modes <m1,m2[,...]>] [--json] [--debug]
airpods-control [--device NAME] conversation-awareness get [--json] [--debug]
airpods-control [--device NAME] conversation-awareness set <on|off> [--json] [--debug]
airpods-control --version | -v | version
airpods-control --help | -h
```

`listening-mode` can be shortened to `lm`, and `conversation-awareness` to `ca`. The aliases replace only the resource name, so `airpods-control lm get` and `airpods-control ca set off` are complete commands. Reads are always explicit; a bare resource name is an error.

`<mode>` is one of `off`, `transparency`, `adaptive`, `noise-cancellation`. For interactive use, `trans` aliases `transparency`; `automatic` and `auto` alias `adaptive`; and `anc` and `nc` alias `noise-cancellation`. Output always uses the canonical names. There is intentionally no alias for `off`.

Unknown mode or state tokens are `bad-args` (exit `2`); a valid feature that the connected hardware does not provide is `unsupported` (exit `4`).

Operational commands accept `--device NAME`, `--json`, and `--debug` anywhere. `--device` uses a case-insensitive exact name match among compatible output devices. It never falls back to another device; no match or multiple exact matches produce `no-device`.

### Read the current mode

```console
$ airpods-control listening-mode get
transparency
```

### Set a mode

```console
$ airpods-control listening-mode set noise-cancellation
ok
```

Setters are idempotent: if the requested mode is already active, the command prints `ok`, exits `0`, and does not issue a write. If a requested change does not verify within the bounded readback window, you get `no-op` and exit code `3`:

```console
$ airpods-control lm set noise-cancellation
no-op
```

### List the modes this device supports

```console
$ airpods-control listening-mode list
off,transparency,adaptive,noise-cancellation
```

Modes are always printed in that order, filtered to the modes supported by the connected device.

### Cycle through modes

`cycle` advances to the next mode, like pressing and holding an AirPods stem,
and prints the resulting mode:

```console
$ airpods-control listening-mode cycle
adaptive
$ airpods-control lm cycle
noise-cancellation
```

By default the cycle set is every mode the device supports except `off`. Modes
always cycle in canonical order (`off`, `transparency`, `adaptive`,
`noise-cancellation`), wrapping around. A current mode outside the cycle set
folds into that same order: cycling from `adaptive` with
`--modes transparency,noise-cancellation` lands on `noise-cancellation`, and
with `--modes off,transparency` it wraps to `off`. If the current mode is
`unknown`, `cycle` starts at the set's first mode.

`--modes` selects an explicit cycle set: a comma-separated list of at least
two distinct modes that mirrors the "Press and Hold to Cycle Between"
checkboxes in System Settings:

```console
$ airpods-control lm cycle --modes off,transparency,noise-cancellation
transparency
```

Order within `--modes` does not matter; cycling always follows the canonical
order, and the mode aliases listed above are accepted. Fewer than two distinct
modes or an unknown token is `bad-args` (exit `2`). Listed modes the connected
device does not support are skipped; if fewer than two remain, the command
reports `unsupported` (exit `4`). A change that does not verify reports
`no-op` (exit `3`).

### Conversation Awareness

```console
$ airpods-control conversation-awareness get
on
$ airpods-control ca set off
ok
```

On hardware that does not support Conversation Awareness you get `unsupported` and exit code `4`.

### Target a device

Without `--device`, the first compatible system output device is used. To select one explicitly:

```console
$ airpods-control --device "My AirPods Pro" listening-mode get
transparency
```

Names are matched exactly but case-insensitively. Substrings are not accepted, so `--device "My"` will not silently select `"My AirPods Pro"`.

### JSON output

Add `--json` to any command for structured output, e.g.:

```console
$ airpods-control listening-mode get --json
{"device":"My AirPods Pro","listeningMode":"transparency","result":"ok"}

$ airpods-control listening-mode set noise-cancellation --json
{"device":"My AirPods Pro","listeningMode":"noise-cancellation","result":"ok"}

$ airpods-control listening-mode list --json
{"device":"My AirPods Pro","listeningMode":"transparency","result":"ok","supportedListeningModes":["off","transparency","adaptive","noise-cancellation"]}

$ airpods-control conversation-awareness get --json
{"conversationAwareness":"on","device":"My AirPods Pro","result":"ok"}
```

Every JSON response contains `result`, whose value is `ok`, `no-op`, or `error`. A valid resource command also contains `device` and its resulting `listeningMode` or `conversationAwareness` state. States normally reflect private-API readback; the documented accepted-`off` fallback below may instead report the expected eventual Transparency state. Otherwise, an unresolved device or state is JSON `null`. Errors add an `error` field:

```console
$ airpods-control --device "Missing AirPods" listening-mode get --json
{"device":null,"error":"no-device","listeningMode":null,"result":"error"}
```

`listening-mode list` also returns `supportedListeningModes`. A write that does not verify uses `"result":"no-op"` and exits `3`. It returns the final canonical state read during the bounded settling window, the documented Transparency fallback, or JSON `null` when neither applies. Version JSON follows the same result convention: `{"result":"ok","version":"0.1.0"}`.

`-h` and `--help` can appear anywhere. Help always wins, exits `0`, and never accesses the device; a recognized resource before the flag selects contextual help. Version flags are global only and do not accept `--device`.

### Debug diagnostics

Add `--debug` to emit private-API discovery and operation diagnostics on stderr:

```console
$ airpods-control --debug listening-mode get
debug: cli.command="listening-mode.get"
info: audio_context_selector="sharedSystemAudioContext"
info: selected_device="My AirPods Pro"
transparency
```

Debug output covers bypass/re-exec status, framework and selector discovery, compatible devices, exact-name selection, raw modes, capability checks, writes, and read-back attempts. It never changes stdout, JSON, or the exit code, so stdout remains safe to pipe or parse.

### Write verification

Listening-mode writes are checked every 50 ms while the device settles. Non-`off` writes return when the target is observed, within about 800 ms. Changed `off` writes use a 1.5-second window because their fallback can bounce between modes.

If `off` is not verified, the setter accepted the request, and the device advertises Transparency, `set off` and explicit cycles into `off` report `no-op` with `listeningMode: "transparency"`. This is the expected eventual fallback when Off Listening Mode is disabled, not an observed final sample. With `--debug`, `verify.listening_mode.inferred_off_fallback=true` identifies this inference. Rejected writes and devices without Transparency continue to report the final observed canonical mode or `null`.

### Exit codes

| Code | Meaning     | When                                                     |
| ---- | ----------- | -------------------------------------------------------- |
| `0`  | ok          | Command succeeded (including reads and verified writes). |
| `1`  | no-device   | No supported AirPods found as the current output device. |
| `2`  | bad-args    | Missing or malformed arguments.                          |
| `3`  | no-op       | A requested write was not verified in the bounded window. |
| `4`  | unsupported | The mode or feature isn't available on this device.      |

The single-token stdout (`ok`, `no-op`, `no-device`, `unsupported`, a mode name, etc.) mirrors the exit code so you can branch on either.

## How it works

The tool depends on a private API and an entitlement interpose. Review how both work before building it.

### The private API

macOS exposes AirPods listening modes and Conversation Awareness through the private, undocumented `AVOutputDevice` API in `AVRouting.framework`. The tool reaches it through the shared system audio context in `AVOutputContext`. Apple provides no public API for this from a normal command-line tool, so `airpods-control` defines the required surface as an `@objc` protocol and calls it directly.

### The one forged entitlement

The shared system audio context requires the private `com.apple.avfoundation.allow-system-wide-context` entitlement. Apple's audio components carry it, but a normal ad-hoc-signed binary does not. AVFoundation checks for the entitlement in-process by calling `SecTaskCopyValueForEntitlement`.

The interpose library in [`native/bypass.c`](native/bypass.c), about 40 lines of C, satisfies that check. It loads through `DYLD_INSERT_LIBRARIES` and returns true only for `com.apple.avfoundation.allow-system-wide-context`. It passes every other entitlement query to the real implementation unchanged. At launch, the tool re-execs itself once with the dylib inserted. It sets `DYLD_INSERT_LIBRARIES` in the child so the process still works if the parent environment strips `DYLD_*` variables.

The interpose has a narrow scope:

- It forges one audio entitlement inside the `airpods-control` helper process. Other processes are unaffected.
- It does not elevate to root or another user. The changed entitlement check only lets the helper call the private audio API.
- It leaves SIP, Gatekeeper, code signing, the sandbox, and other system protections enabled.
- It makes no network connections and accesses no user data or configuration files. It loads its own executable and dylib, loads Apple system frameworks, reads or sets an audio setting, and exits.

### Why it builds from source (and can't be notarized)

The interpose only works with an ad-hoc-signed binary. A notarized binary with the hardened runtime would enforce library validation, which blocks `DYLD_INSERT_LIBRARIES` from loading a library signed by a different team. The project therefore distributes source instead of a prebuilt binary. You can review the C and Swift sources, then compile them with your own toolchain.

This is the same mechanism [NoiseBuddy](https://github.com/insidegui/NoiseBuddy) uses to offer these controls.

## Compatibility and fragility

Apple can change or remove this private API in any macOS update. The current release targets macOS Tahoe 26. The tool probes known shared-context selector variants and checks each required selector before calling it. If an OS update removes or renames a capability, the command reports `no-device` or `unsupported` instead of sending an unrecognized selector.

Use `--debug` to distinguish a missing private selector from an unavailable device or hardware feature.

## Security

See [SECURITY.md](SECURITY.md) for the threat model and how to report issues.

## Contributing

Bug reports and focused pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before contributing, especially the notes about testing changes that touch the private API.

## Credits and prior art

- [NoiseBuddy](https://github.com/insidegui/NoiseBuddy) by Guilherme Rambo documented this AVFoundation technique.

`airpods-control` is a personal, independent tool. Apple does not endorse or support it. AirPods and AirPods Pro are trademarks of Apple Inc.

## License

MIT. See [LICENSE](LICENSE).
