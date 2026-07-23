# airpods-control

Control your AirPods listening mode and Conversation Awareness from the command line — instantly, with no Control Center, no menu bar, and no Accessibility permission.

```console
$ airpods-control lm set noise-cancellation
ok
$ airpods-control ca get
off
```

`airpods-control` talks to the macOS system audio daemon directly through the same private AVFoundation API that AirPods use internally. Switching a mode is exactly like pressing and holding a stem: the change is immediate and you get the same on-screen banner. There is no background polling, no synthetic clicks, and no UI automation.

## What it does

- **Listening mode:** `off`, `transparency`, `adaptive`, `noise-cancellation` — read, set, or cycle through a configurable set.
- **Conversation Awareness:** read it or turn it on and off.
- **Device targeting:** select a compatible output device by exact name.
- **Scriptable:** single-token output on stdout, meaningful exit codes, optional `--json`, and opt-in diagnostics on stderr. Wire it to a hotkey, a Stream Deck, a Shortcut, or a `launchd` job.

Because it speaks to the audio daemon rather than driving the UI, it needs **no Accessibility or Automation permission** and there is nothing to click. It is effectively invisible and instant.

## Requirements

- macOS (developed and tested on **Tahoe 26**).
- **Command Line Tools** for the build (`clang` + `swiftc`). Install with `xcode-select --install`. Full Xcode is not required.
- A supported pair of AirPods connected as the current output device.

## Install

### Homebrew (build-from-source)

```sh
brew install raulg/tap/airpods-control
```

The formula compiles locally from source — no prebuilt binary is downloaded (see [How it works](#how-it-works)). You need Command Line Tools (or Xcode) installed so Homebrew can invoke `swiftc`.

### From source

```sh
git clone https://github.com/raulg/airpods-control-cli
cd airpods-control-cli
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
```

The binary resolves its own real path (through the symlink) to locate `avbypass.dylib` beside it, so the `bin` symlink just works.

Uninstall with `sudo make uninstall`; remove build artifacts with `make clean`. Run `make test` for device-independent CLI contract, parser, selector-discovery, and device-selection checks.

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

`cycle` advances to the next mode — like pressing and holding an AirPods stem —
and prints the mode it landed on:

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

`--modes` selects an explicit cycle set — a comma-separated list of at least
two distinct modes, mirroring the "Press and Hold to Cycle Between"
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
$ airpods-control --device "Raul’s AirPods Pro" lm get
transparency
```

Names are matched exactly but case-insensitively. Substrings are not accepted, so `--device "Raul"` will not silently select `"Raul’s AirPods Pro"`.

### JSON output

Add `--json` to any command for structured output, e.g.:

```console
$ airpods-control listening-mode get --json
{"device":"Raul’s AirPods Pro","listeningMode":"transparency","result":"ok"}

$ airpods-control lm set noise-cancellation --json
{"device":"Raul’s AirPods Pro","listeningMode":"noise-cancellation","result":"ok"}

$ airpods-control lm list --json
{"device":"Raul’s AirPods Pro","listeningMode":"transparency","result":"ok","supportedListeningModes":["off","transparency","adaptive","noise-cancellation"]}

$ airpods-control ca get --json
{"conversationAwareness":"on","device":"Raul’s AirPods Pro","result":"ok"}
```

Every JSON response contains `result`, whose value is `ok`, `no-op`, or `error`. A valid resource command also contains `device` and its resulting `listeningMode` or `conversationAwareness` state. States normally reflect private-API readback; the documented accepted-`off` fallback below may instead report the expected eventual Transparency state. Otherwise, an unresolved device or state is JSON `null`. Errors add an `error` field:

```console
$ airpods-control --device "Missing AirPods" lm get --json
{"device":null,"error":"no-device","listeningMode":null,"result":"error"}
```

`lm list` additionally returns `supportedListeningModes`. A write that does not verify uses `"result":"no-op"` and exits `3`. It returns the final canonical state read during the bounded settling window, the documented Transparency fallback, or JSON `null` when neither applies. Version JSON follows the same result convention: `{"result":"ok","version":"0.1.0"}`.

`-h` and `--help` can appear anywhere. Help always wins, exits `0`, and never accesses the device; a recognized resource before the flag selects contextual help. Version flags are global only and do not accept `--device`.

### Debug diagnostics

Add `--debug` to emit private-API discovery and operation diagnostics on stderr:

```console
$ airpods-control --debug lm get
debug: cli.command="listening-mode.get"
info: audio_context_selector="sharedSystemAudioContext"
info: selected_device="Raul’s AirPods Pro"
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

This is the honest part, because the mechanism is unusual and you should understand exactly what you are running before you build it.

### The private API

macOS exposes AirPods listening modes and Conversation Awareness only through a **private, undocumented Apple API**: `AVOutputDevice` in `AVRouting.framework`, reached via `AVOutputContext`'s shared system audio context. There is no public, sanctioned way to do this from a normal command-line tool. `airpods-control` duck-types that API through an `@objc` protocol and calls it directly — the same surface the system itself uses.

### The one forged entitlement

Acquiring the _shared system audio context_ is gated by a private entitlement, `com.apple.avfoundation.allow-system-wide-context`. Apple's own audio components carry it; a normal ad-hoc-signed binary does not. AVFoundation checks for it **in-process** by calling `SecTaskCopyValueForEntitlement`.

`airpods-control` satisfies that check with a tiny interpose library, [`native/bypass.c`](native/bypass.c) (~40 lines, fully included and auditable). It is loaded via `DYLD_INSERT_LIBRARIES` and does exactly one thing: when AVFoundation asks _"do I have `com.apple.avfoundation.allow-system-wide-context`?"_ it answers _"yes."_ **Every other entitlement query is passed straight through to the real implementation, unchanged.** On launch the tool re-execs itself once with the dylib inserted (setting `DYLD_INSERT_LIBRARIES` inside the child, so it works even if the parent environment strips `DYLD_*`), then does its work.

To be precise about what this does and does not do:

- It **forges exactly one** audio entitlement, and only **inside the `airpods-control` helper process**. Nothing else on your system is affected.
- It **grants no new privilege** over your own machine — you already own the audio hardware and could press the stem by hand. It just removes an in-process gate that keeps third-party tools out of a first-party API.
- It does **not** disable SIP, Gatekeeper, code signing, the sandbox, or any other protection. Nothing is turned off system-wide.
- It touches **no network and no files** — it makes no connections and reads/writes nothing on disk. It reads and sets an audio setting, and exits.

### Why it builds from source (and can't be notarized)

The interpose only works on an **ad-hoc-signed** binary. A notarized, hardened-runtime binary would enforce **library validation**, which blocks `DYLD_INSERT_LIBRARIES` from loading a library not signed by the same team — so the technique cannot be shipped as a signed, downloadable app. That is a feature of the trust model here, not a workaround: **`airpods-control` ships no prebuilt binary.** You clone the repo, read the ~40 lines of C and the Swift, and compile it yourself with your own toolchain. What runs is what you audited.

This is the same mechanism [NoiseBuddy](https://github.com/insidegui/NoiseBuddy) uses to offer these controls.

## Compatibility and fragility

This relies on a private API, so **Apple can change or remove it in any macOS update** without notice. The current release targets macOS **Tahoe (26)**. The tool probes known shared-context selector variants and verifies every required selector before calling it. When an OS update removes or renames a capability, the command reports `no-device` or `unsupported` instead of sending an unrecognized selector.

Use `--debug` to distinguish a missing private selector from an unavailable device or hardware feature.

## Security

See [SECURITY.md](SECURITY.md) for the threat model and how to report issues.

## Credits and prior art

- [NoiseBuddy](https://github.com/insidegui/NoiseBuddy) by Guilherme Rambo — the prior art that documented this AVFoundation technique.

`airpods-control` is a personal, independent tool. It is **not affiliated with, endorsed by, or supported by Apple**. AirPods and AirPods Pro are trademarks of Apple Inc.

## License

MIT — see [LICENSE](LICENSE).
