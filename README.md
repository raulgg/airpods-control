# airpods-control

Control your AirPods listening mode and Conversation Awareness from the command line — instantly, with no Control Center, no menu bar, and no Accessibility permission.

```console
$ airpods-control lm set noise-cancellation
ok
$ airpods-control ca get
off
```

`airpods-control` talks to the macOS system audio daemon directly through the same private AVFoundation API that AirPods use internally. Switching a mode is exactly like pressing and holding a stem: the change is immediate and you get the same on-screen banner. There is no polling, no synthetic clicks, and no UI automation.

## What it does

- **Listening mode:** `off`, `transparency`, `adaptive`, `noise-cancellation`.
- **Conversation Awareness:** read it or turn it on and off.
- **Scriptable:** single-token output on stdout, meaningful exit codes, optional `--json`. Wire it to a hotkey, a Stream Deck, a Shortcut, or a `launchd` job.

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

Uninstall with `sudo make uninstall`; remove build artifacts with `make clean`.

## Usage

```
airpods-control listening-mode get
airpods-control listening-mode set <mode>
airpods-control listening-mode list
airpods-control conversation-awareness get
airpods-control conversation-awareness set <on|off>
airpods-control --version | -v | version
airpods-control --help | -h
```

`listening-mode` can be shortened to `lm`, and `conversation-awareness` to
`ca`. The aliases replace only the resource name, so `airpods-control lm get`
and `airpods-control ca set off` are complete commands. Reads are always
explicit; a bare resource name is an error.

`<mode>` is one of `off`, `transparency`, `adaptive`, `noise-cancellation`.
Unknown mode or state tokens are `bad-args` (exit `2`); a valid feature that
the connected hardware does not provide is `unsupported` (exit `4`).

Any command accepts `--json` for structured output.

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

Setters are idempotent: if the requested mode is already active, the command
prints `ok`, exits `0`, and does not issue a write. If a requested change is a
silent hardware no-op (see below), you get `no-op` and exit code `3`:

```console
$ airpods-control lm set noise-cancellation
no-op
```

### List the modes this device supports

```console
$ airpods-control listening-mode list
off,transparency,adaptive,noise-cancellation
```

Modes are always printed in that order, filtered to the modes supported by the
connected device.

### Conversation Awareness

```console
$ airpods-control conversation-awareness get
on
$ airpods-control ca set off
ok
```

On hardware that does not support Conversation Awareness you get `unsupported`
and exit code `4`.

### JSON output

Add `--json` to any command for structured output, e.g.:

```console
$ airpods-control listening-mode get --json
{"listeningMode":"transparency"}

$ airpods-control lm set noise-cancellation --json
{"listeningMode":"noise-cancellation","result":"ok"}

$ airpods-control lm list --json
{"listeningModes":["off","transparency","adaptive","noise-cancellation"]}

$ airpods-control ca get --json
{"conversationAwareness":"on"}
```

Successful writes include `"result":"ok"` and the resulting
`listeningMode` or `conversationAwareness` state. Errors use an `error` field,
such as `{"error":"no-device"}`, while a write that changes nothing returns
`{"result":"no-op"}` with exit code `3`.

`-h` and `--help` can appear anywhere. Help always wins, exits `0`, and never
accesses the device; a recognized resource before the flag selects contextual
help. Version flags are global only.

### The `off` no-op caveat

On **AirPods Pro**, `off` (the "Normal"/no-active-mode state) is a **silent no-op**: the API accepts the request but the hardware stays where it is. `airpods-control` verifies every change by reading the value back, so rather than falsely claiming success it reports `no-op` and exits `3`. This is expected behavior on AirPods Pro, not a bug — use `transparency` if you want a "hear everything" mode.

### Exit codes

| Code | Meaning       | When                                                        |
|------|---------------|-------------------------------------------------------------|
| `0`  | ok            | Command succeeded (including reads and verified writes).    |
| `1`  | no-device     | No supported AirPods found as the current output device.    |
| `2`  | bad-args      | Missing or malformed arguments.                             |
| `3`  | no-op         | A requested write did not change the setting.              |
| `4`  | unsupported   | The mode or feature isn't available on this device.         |

The single-token stdout (`ok`, `no-op`, `no-device`, `unsupported`, a mode name, etc.) mirrors the exit code so you can branch on either.

## How it works

This is the honest part, because the mechanism is unusual and you should understand exactly what you are running before you build it.

### The private API

macOS exposes AirPods listening modes and Conversation Awareness only through a **private, undocumented Apple API**: `AVOutputDevice` in `AVRouting.framework`, reached via `AVOutputContext`'s shared system audio context. There is no public, sanctioned way to do this from a normal command-line tool. `airpods-control` duck-types that API through an `@objc` protocol and calls it directly — the same surface the system itself uses.

### The one forged entitlement

Acquiring the *shared system audio context* is gated by a private entitlement, `com.apple.avfoundation.allow-system-wide-context`. Apple's own audio components carry it; a normal ad-hoc-signed binary does not. AVFoundation checks for it **in-process** by calling `SecTaskCopyValueForEntitlement`.

`airpods-control` satisfies that check with a tiny interpose library, [`native/bypass.c`](native/bypass.c) (~40 lines, fully included and auditable). It is loaded via `DYLD_INSERT_LIBRARIES` and does exactly one thing: when AVFoundation asks *"do I have `com.apple.avfoundation.allow-system-wide-context`?"* it answers *"yes."* **Every other entitlement query is passed straight through to the real implementation, unchanged.** On launch the tool re-execs itself once with the dylib inserted (setting `DYLD_INSERT_LIBRARIES` inside the child, so it works even if the parent environment strips `DYLD_*`), then does its work.

To be precise about what this does and does not do:

- It **forges exactly one** audio entitlement, and only **inside the `airpods-control` helper process**. Nothing else on your system is affected.
- It **grants no new privilege** over your own machine — you already own the audio hardware and could press the stem by hand. It just removes an in-process gate that keeps third-party tools out of a first-party API.
- It does **not** disable SIP, Gatekeeper, code signing, the sandbox, or any other protection. Nothing is turned off system-wide.
- It touches **no network and no files** — it makes no connections and reads/writes nothing on disk. It reads and sets an audio setting, and exits.

### Why it builds from source (and can't be notarized)

The interpose only works on an **ad-hoc-signed** binary. A notarized, hardened-runtime binary would enforce **library validation**, which blocks `DYLD_INSERT_LIBRARIES` from loading a library not signed by the same team — so the technique cannot be shipped as a signed, downloadable app. That is a feature of the trust model here, not a workaround: **`airpods-control` ships no prebuilt binary.** You clone the repo, read the ~40 lines of C and the Swift, and compile it yourself with your own toolchain. What runs is what you audited.

This is the same mechanism [NoiseBuddy](https://github.com/insidegui/NoiseBuddy) uses to offer these controls.

## Compatibility and fragility

This relies on a private API, so **Apple can change or remove it in any macOS update** without notice. The current release targets macOS **Tahoe (26)**. When an OS update breaks a selector or renames a mode string, releases will be patched to follow.

The tool is written to **fail safe**: when an expected selector or capability is missing it reports `no-device` or `unsupported` and exits cleanly, rather than crashing or doing something unexpected.

## Security

See [SECURITY.md](SECURITY.md) for the threat model and how to report issues.

## Credits and prior art

- [NoiseBuddy](https://github.com/insidegui/NoiseBuddy) by Guilherme Rambo — the prior art that documented this AVFoundation technique.

`airpods-control` is a personal, independent tool. It is **not affiliated with, endorsed by, or supported by Apple**. AirPods and AirPods Pro are trademarks of Apple Inc.

## License

MIT — see [LICENSE](LICENSE).
