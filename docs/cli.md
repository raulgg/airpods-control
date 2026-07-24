# CLI reference

This is the complete `airpods-control` command-line reference. See the
[project README](../README.md) for installation and a shorter introduction.

## Synopsis

```text
airpods-control [--device NAME] listening-mode get [--json] [--debug]
airpods-control [--device NAME] listening-mode set <mode> [--json] [--debug]
airpods-control [--device NAME] listening-mode list [--json] [--debug]
airpods-control [--device NAME] listening-mode cycle [--modes <m1,m2[,...]>] [--json] [--debug]
airpods-control [--device NAME] conversation-awareness get [--json] [--debug]
airpods-control [--device NAME] conversation-awareness set <on|off> [--json] [--debug]
airpods-control --version | -v | version
airpods-control --help | -h
```

`listening-mode` can be shortened to `lm`, and `conversation-awareness` to
`ca`. These aliases replace only the resource name, so
`airpods-control lm get` and `airpods-control ca set off` are complete
commands. Reads are always explicit. A bare resource name is an error.

`<mode>` is one of `off`, `transparency`, `adaptive`, or
`noise-cancellation`. For interactive use, `trans` aliases `transparency`;
`automatic` and `auto` alias `adaptive`; and `anc` and `nc` alias
`noise-cancellation`. Output always uses the canonical names. There is
intentionally no alias for `off`.

An unknown mode or state token produces `bad-args` (exit `2`). A valid feature
that the connected hardware does not provide produces `unsupported` (exit
`4`).

Operational commands accept `--device NAME`, `--json`, and `--debug` in any
position. `--device` uses a case-insensitive exact name match among compatible
output devices. It never falls back to another device. No match or multiple
exact matches produce `no-device`.

## Listening modes

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

Setters are idempotent. If the requested mode is already active, the command
prints `ok`, exits `0`, and does not issue a write. If the change cannot be
verified within the bounded readback window, the command prints `no-op` and
exits `3`:

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

### Cycle through modes

`cycle` advances to the next mode, like pressing and holding an AirPods stem,
and prints the resulting mode:

```console
$ airpods-control listening-mode cycle
adaptive
$ airpods-control lm cycle
noise-cancellation
```

By default, the cycle set contains every supported mode except `off`. Modes
cycle in canonical order (`off`, `transparency`, `adaptive`,
`noise-cancellation`) and wrap at the end. If the current mode is outside the
cycle set, the command still advances from its canonical position. For
example, cycling from `adaptive` with
`--modes transparency,noise-cancellation` lands on `noise-cancellation`.
Cycling from `adaptive` with `--modes off,transparency` wraps to `off`. If the
current mode is `unknown`, `cycle` starts at the first mode in the set.

`--modes` selects an explicit cycle set. Pass a comma-separated list of at
least two distinct modes, like the "Press and Hold to Cycle Between"
checkboxes in System Settings:

```console
$ airpods-control lm cycle --modes off,transparency,noise-cancellation
transparency
```

Order within `--modes` does not matter. Cycling follows the canonical order,
and the command accepts the mode aliases listed above. Fewer than two distinct
modes or an unknown token produces `bad-args` (exit `2`). The command skips
modes that the connected device does not support. If fewer than two remain, it
reports `unsupported` (exit `4`). A change that cannot be verified reports
`no-op` (exit `3`).

## Conversation Awareness

```console
$ airpods-control conversation-awareness get
on
$ airpods-control ca set off
ok
```

On hardware without Conversation Awareness, the command prints `unsupported`
and exits `4`.

## Target a device

Without `--device`, the first compatible system output device is used. To
select one explicitly:

```console
$ airpods-control --device "My AirPods Pro" listening-mode get
transparency
```

Names are matched exactly but case-insensitively. Substrings are not accepted,
so `--device "My"` will not silently select `"My AirPods Pro"`.

## JSON output

Add `--json` to any command for structured output:

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

Every JSON response contains `result`, with a value of `ok`, `no-op`, or
`error`. A valid resource command also contains `device` and the resulting
`listeningMode` or `conversationAwareness` state. States normally come from
private-API readback. The accepted-`off` fallback described under
Write verification may report the expected eventual Transparency state
instead. An unresolved device or state is JSON `null`. Errors add an `error`
field:

```console
$ airpods-control --device "Missing AirPods" listening-mode get --json
{"device":null,"error":"no-device","listeningMode":null,"result":"error"}
```

`listening-mode list` also returns `supportedListeningModes`. An unverified
write uses `"result":"no-op"` and exits `3`. The response contains the final
canonical state read during the bounded settling window, the Transparency
fallback, or JSON `null` when neither applies. Version JSON follows the same
result convention: `{"result":"ok","version":"0.1.0"}`.

`-h` and `--help` can appear anywhere. Help takes precedence, exits `0`, and
never accesses the device. A recognized resource before the flag selects
contextual help. Version flags are global only and do not accept `--device`.

## Debug diagnostics

Add `--debug` to emit private-API discovery and operation diagnostics on
stderr:

```console
$ airpods-control --debug listening-mode get
debug: cli.command="listening-mode.get"
info: audio_context_selector="sharedSystemAudioContext"
info: selected_device="My AirPods Pro"
transparency
```

Debug output includes bypass and re-exec status, framework and selector
discovery, compatible devices, exact-name selection, raw modes, capability
checks, writes, and read-back attempts. It does not change stdout, JSON, or the
exit code, so stdout remains safe to pipe or parse.

## Write verification

Listening-mode writes are checked every 50 ms while the device settles.
Non-`off` writes return when the target is observed, within about 800 ms.
Changed `off` writes use a 1.5-second window because their fallback can bounce
between modes.

When the setter accepts `off` but the change cannot be verified and the device
advertises Transparency, `set off` and explicit cycles into `off` report
`no-op` with `listeningMode: "transparency"`. This is the expected eventual
fallback when Off Listening Mode is disabled, not an observed final sample.
With `--debug`, `verify.listening_mode.inferred_off_fallback=true` marks this
inference. For rejected writes or devices without Transparency, the response
contains the final observed canonical mode or `null`.

## Exit codes

| Code | Meaning     | When                                                       |
| ---- | ----------- | ---------------------------------------------------------- |
| `0`  | ok          | Command succeeded, including reads and verified writes.    |
| `1`  | no-device   | No supported AirPods found as the current output device.   |
| `2`  | bad-args    | Arguments are missing or malformed.                        |
| `3`  | no-op       | A write was not verified in the bounded readback window.   |
| `4`  | unsupported | The mode or feature is not available on the selected device. |

Plain stdout uses a single token such as `ok`, `no-op`, `no-device`,
`unsupported`, or a mode name. Scripts can branch on either that token or the
exit code.
