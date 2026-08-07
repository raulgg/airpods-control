# CLI reference

This is the complete `airpods-control` command-line reference. See the
[project README](../README.md) for installation and a shorter introduction.

## Synopsis

```text
airpods-control status [--device NAME] [--json] [--debug]
airpods-control [--device NAME] listening-mode get [--json] [--debug]
airpods-control [--device NAME] listening-mode set <mode> [--json] [--debug]
airpods-control [--device NAME] listening-mode list [--json] [--debug]
airpods-control [--device NAME] listening-mode cycle
    [--modes <m1,m2[,...]>] [--json] [--debug]
airpods-control [--device NAME] conversation-awareness get [--json] [--debug]
airpods-control [--device NAME] conversation-awareness set <on|off> [--json] [--debug]
airpods-control support-report [--with-write-tests | --no-write-tests] [--debug]
airpods-control --version | -v | version
airpods-control --help | -h
```

`listening-mode` can be shortened to `lm`, and `conversation-awareness` to `ca`.
These aliases replace only the resource name, so `airpods-control lm get` and
`airpods-control ca set off` are complete commands. `status` has no alias. Reads
of an individual resource are always explicit. A bare resource name is an error.

`<mode>` is one of `off`, `transparency`, `adaptive`, or `noise-cancellation`.
For interactive use, `trans` aliases `transparency`; `automatic` and `auto`
alias `adaptive`; and `anc` and `nc` alias `noise-cancellation`. Output always
uses the canonical names. There is intentionally no alias for `off`.

An unknown mode or state token produces `bad-args` (exit `2`). For an individual
resource command, a valid feature that the connected hardware does not provide
produces `unsupported` (exit `4`). Aggregate status instead omits a
proven-unsupported field.

Operational commands accept `--device NAME`, `--json`, and `--debug` in any
position. `--device` uses a case-insensitive, whole-name match among compatible
output devices. It never falls back to another device. No match or multiple
exact matches produce `no-device`. Without `--device`, the individual resource
commands use the first compatible device; `status` reports all compatible
devices.

`support-report` is a separate contributor command. It accepts
`--with-write-tests` or `--no-write-tests` (mutually exclusive), which answer
its write-test consent question in advance, and `--debug`. The report has a
fixed set of fields. The consent prompt and result rows depend on the device.

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
cycle set, the command still advances from its canonical position. For example,
cycling from `adaptive` with `--modes transparency,noise-cancellation` lands on
`noise-cancellation`. Cycling from `adaptive` with `--modes off,transparency`
wraps to `off`. If the current mode is `unknown`, `cycle` starts at the first
mode in the set.

`--modes` selects an explicit cycle set. Pass a comma-separated list of at least
two distinct modes, like the "Press and Hold to Cycle Between" checkboxes in
System Settings:

```console
$ airpods-control lm cycle --modes off,transparency,noise-cancellation
transparency
```

Order within `--modes` does not matter. Cycling follows the canonical order, and
the command accepts the mode aliases listed above. Fewer than two distinct modes
or an unknown token produces `bad-args` (exit `2`). The command skips modes that
the connected device does not support. If fewer than two remain, it reports
`unsupported` (exit `4`). A change that cannot be verified reports `no-op` (exit
`3`).

## Conversation Awareness

```console
$ airpods-control conversation-awareness get
on
$ airpods-control ca set off
ok
```

On hardware without Conversation Awareness, the command prints `unsupported` and
exits `4`.

## Status

`status` reads the current listening mode and Conversation Awareness state in
one command. It does not report battery levels, device metadata beyond the name
required to identify each record, or other settings. Compatibility metadata and
consented write tests remain the separate responsibility of `support-report`.

Without `--device`, it emits one record for every compatible connected output
device, including Beats. Records follow the system audio routing discovery
order, which the private API does not guarantee to be stable.

With `--device`, the command emits one record for the unique case-insensitive
whole-name match. A missing or ambiguous name fails with `no-device`; it never
selects one of several matches. Every plain-text record has a heading, including
a selected singleton:

```console
$ airpods-control status
My AirPods Pro:
  Listening mode: transparency
  Conversation Awareness: on

Studio Beats:
  Listening mode: adaptive
```

Device headings retain ordinary printable Unicode but render backslash, newline,
carriage return, and tab as `\\`, `\n`, `\r`, and `\t`. Other control characters
and the Unicode line and paragraph separators use `\u{XXXX}` form, so a device
name cannot alter the record layout. This applies only to the plain heading.
JSON retains the original name and uses normal JSON string escaping. Fields
appear beneath the heading in Listening mode, Conversation Awareness, and Read
errors order. Inapplicable lines are omitted, and records are separated by one
blank line.

A field is omitted only when the device is known not to support that feature. An
unresolved read follows the corresponding individual getter: listening mode
appears as `unknown`, while Conversation Awareness appears as `unsupported`.
Either state is JSON `null`, with its canonical key still present. A genuine
read failure keeps that same fallback state and also adds a plain summary such
as `Read errors: Listening mode, Conversation Awareness`, indented by two spaces
(errored labels only, in that fixed order), or an `errors` object in that
device's JSON record. One failed field does not hide a successfully read field
or stop the remaining devices from being sampled.

For example, when both reads genuinely fail, the record retains both getters'
fallback states and names both errors:

```text
My AirPods Pro:
  Listening mode: unknown
  Conversation Awareness: unsupported
  Read errors: Listening mode, Conversation Awareness
```

A record whose two fields are both proven unsupported still appears, but has
only its device heading in plain output and only `device` in JSON.

The command succeeds when at least one selected device produces any usable,
unresolved, or unsupported status result. It exits `5` with `read-error` only
when every selected device produces genuine read errors and no usable,
unresolved, or proven-unsupported field. Argument and device-selection failures
retain their own results and exit codes.

If no compatible device is connected, plain output is exactly:

```text
No compatible AirPods or Beats device is connected.
```

The corresponding JSON is exactly
`{"devices":[],"error":"no-device","result":"error"}`. This contract also
applies when `--device` has no unique match.

`status` takes a read-only snapshot. One-earbud operation uses the same feature
availability and getter behavior as the individual commands.

## Contributor compatibility report

The CLI has only been verified with AirPods Pro 3. Other AirPods may work when
macOS exposes the same private audio capabilities. We have not verified Beats,
but reports are welcome. The [device compatibility matrix](compatibility.md)
tracks each command separately.

Connect exactly one compatible AirPods or Beats device as a macOS output device,
then run:

```console
$ airpods-control support-report
Write tests
────────────────────────────────────────────
Plan
  Listening modes          off, transparency, adaptive (about 2s each)
  Restore mode             noise-cancellation
  Conversation Awareness   toggle and restore

Caution   Changes are audible. Do not run these tests during a call.
Safety    A setting is skipped if it changes before testing.
Restore   Captured settings are restored when possible; failures are reported.

Run write tests? [y/N] n
Write tests skipped. The report below is read-only.

Compatibility report
════════════════════════════════════════════

Device
  Model                    AirPods Pro 3
  Identifier               BTHeadphones76,8231 · product 0x2027
  Family                   AirPods
  macOS                    26.5.2
  airpods-control          0.2.0

Capabilities
  Listening modes          Off, Transparency, Adaptive, Noise cancellation
  Mode query               Available · recognized mode
  Mode setter              Available · not tested
  Conversation Awareness   Supported
  CA query                 Available
  CA setter                Available · not tested

Write tests
  Status                   NOT RUN

Review complete. Nothing has been submitted to GitHub.

Open the prefilled GitHub issue form in your browser? [y/N]
```

The read-only compatibility document includes only the normalized model
identifier, the advertised listening modes, the advertised Conversation
Awareness capability, whether the listening-mode and Conversation Awareness
queries answer, whether macOS exposes their setters, the macOS version, and the
CLI version. The model name is resolved locally: the model identifier embeds the
Bluetooth product ID, and the CLI maps known product IDs to model names (see the
[device compatibility matrix](compatibility.md)).

Unknown advertised listening modes that can be represented safely appear under
`Other modes`. Missing values appear as `Unavailable / not reported`; the
command does not guess them.

The read-only report says whether queries answer and setters exist, but it does
not include the setting values returned by those queries and never invokes a
setter. A consented run reads setting values locally only to plan, verify, and
restore its writes. If restoration cannot be verified, the report names the
final state so it can be restored manually.

The command never reads the customizable device name, firmware version, serial
numbers, Bluetooth/MAC addresses, account data, or raw system dumps and logs. It
never uses the clipboard, sends telemetry, or submits anything. A read-only
report does not change device settings or intentionally interrupt audio;
consented write tests temporarily change the settings in the captured plan.

`support-report` does not read customizable names or accept `--device`, so it
requires exactly one compatible output device. With zero or multiple compatible
devices it prints local instructions and exits `1` before a report, prompt, or
write.

### Consented write tests

When at least one write test can be planned safely, an interactive
`support-report` captures the initial settings and advertised capabilities,
displays that plan, and asks for consent. The default answer is no. Declining
produces the read-only report, marked `Write tests: not run`. The captured plan
does not change after it is disclosed. If a setting changes while consent is
pending, that setting is skipped rather than replaced with a different write.

The listening-mode plan contains the advertised modes recognized by this CLI. It
attempts each noninitial mode and, if the state changed, restores the captured
initial mode last. All listening-mode writes are skipped if the setter is
missing, the initial mode is unreadable or not advertised, or there is no
alternate recognized advertised mode to test.

Conversation Awareness is toggled away from the captured initial state and back.
It is skipped if its setter or initial state is unavailable. Both features use
the same bounded readback verification as their operational commands.

The tests may be disruptive: mode switches are audible, noise control changes
while the device is worn, and Conversation Awareness toggles briefly. Do not run
them during a call. Consent only if you accept this.

After normal completion or a setter error, the command makes one restoration
attempt if needed. An accepted write that cannot be verified is a `no-op` and
does not stop the remaining tests. A `setter error` stops the remaining tests
for that setting. A write whose target already matches the state read
immediately before it cannot demonstrate a transition and is
`inconclusive (already in this state; no transition demonstrated)`, not
`verified`.

The terminal always states the restoration outcome: `RESTORED`, `NOT NEEDED`, or
`NOT RESTORED`. A failed restoration names the final state, gives a manual-fix
hint, and exits `3`. An externally delivered SIGHUP, SIGINT, or SIGTERM caught
during the tests stops further writes, prints
`Interrupt caught; restoring initial settings...` on stderr, attempts
restoration first, prints any restoration warning, and then exits `129`, `130`,
or `143`, respectively. SIGKILL, a process crash, or power loss cannot guarantee
restoration. An interrupted run does not offer or print an issue-form URL. A
consented report shows each result and a compact summary:

```console
$ airpods-control support-report --with-write-tests
Compatibility report
════════════════════════════════════════════
...

Write tests
  Off                      NO-OP
  Transparency             INCONCLUSIVE · already in this state; no transition
                           demonstrated
  Adaptive                 VERIFIED
  Noise cancellation       VERIFIED
  Conversation Awareness   VERIFIED
  CA restoration           VERIFIED
  Summary                  4 verified · 1 inconclusive · 1 no-op
  Restoration              RESTORED

Review complete. Nothing has been submitted to GitHub.
```

`--with-write-tests` answers the consent question with yes and is the only way
to run the tests when standard input is not interactive, for example under a
script. `--no-write-tests` answers it with no. Without a flag, a noninteractive
run skips the tests and notes the flag on stderr.

After the write-test prompt and any tests, the report appears before the
issue-opening question. Review it before submitting the issue and complete the
required privacy confirmation. If the report cannot be prefilled, the CLI prints
a Markdown `GitHub report` block; paste that block into the Compatibility report
field.

The GitHub report includes the individual write-test verdicts but not the
terminal's `RESTORED` or `NOT RESTORED` summary. Check that summary locally and
describe any restoration failure in Additional notes.

The issue-opening question is asked only when standard input is interactive.
Under a script, pipeline, or CI, the command prints the report and writes the
issue form URL to stderr without prompting or opening a browser. On normal
completion it returns `0`, or `3` if consented write tests could not restore the
initial settings. The signal exit codes described above still apply to an
interrupted run.

## Target a device

Without `--device`, the individual listening-mode and Conversation Awareness
commands use the first compatible system output device. `status` is the
exception: it reports every compatible device in system audio-routing discovery
order. To select one explicitly:

```console
$ airpods-control --device "My AirPods Pro" listening-mode get
transparency
```

Unlike operational commands, `support-report` does not read device names or
accept `--device`. It requires exactly one compatible output device.

Names are matched exactly but case-insensitively. Substrings are not accepted,
so `--device "My"` will not silently select `"My AirPods Pro"`. If two devices
have the same name ignoring case, the match is ambiguous and every operational
command fails with `no-device` before reading or changing either one. A device
name passed on the command line must not begin with `-`; this prevents an option
token from being consumed as a missing `--device` value.

## JSON output

Add `--json` to an operational command or the version command for structured
output:

```console
$ airpods-control listening-mode get --json
{"device":"My AirPods Pro","listeningMode":"transparency","result":"ok"}

$ airpods-control listening-mode set noise-cancellation --json
{"device":"My AirPods Pro","listeningMode":"noise-cancellation","result":"ok"}

$ airpods-control listening-mode list --json
{"device":"My AirPods Pro","listeningMode":"transparency","result":"ok","supportedListeningModes":["off","transparency","adaptive","noise-cancellation"]}

$ airpods-control conversation-awareness get --json
{"conversationAwareness":"on","device":"My AirPods Pro","result":"ok"}

$ airpods-control status --device "My AirPods Pro" --json
{"devices":[{"conversationAwareness":"on","device":"My AirPods Pro","listeningMode":"transparency"}],"result":"ok"}
```

Every JSON response contains `result`, with a value of `ok`, `no-op`, or
`error`. A valid resource command also contains `device` and the resulting
`listeningMode` or `conversationAwareness` state. States normally come from
private-API readback. The accepted-`off` fallback described under Write
verification may report the expected eventual Transparency state instead. An
unresolved device or state is JSON `null`. Errors add an `error` field:

```console
$ airpods-control --device "Missing AirPods" listening-mode get --json
{"device":null,"error":"no-device","listeningMode":null,"result":"error"}
```

`listening-mode list` also returns `supportedListeningModes`. An unverified
write uses `"result":"no-op"` and exits `3`. The response contains the final
canonical state read during the bounded settling window, the Transparency
fallback, or JSON `null` when neither applies. Version JSON follows the same
result convention: `{"result":"ok","version":"0.2.0"}`.

`status` always returns a top-level `devices` array, including when `--device`
selects a single device. Each record has `device` and only the canonical
resource keys `listeningMode` and `conversationAwareness`; aliases such as `lm`
and `ca` never appear in JSON. A key is omitted for a proven-unsupported feature
and present with JSON `null` for an unresolved read. A genuine read failure
additionally adds an `errors` map whose canonical field key maps to
`"read-error"`; the map is absent when no genuine read error occurred. For
example, this mixed scan still succeeds:

```json
{
  "devices": [
    {
      "conversationAwareness": null,
      "device": "My AirPods Pro",
      "errors": {"conversationAwareness": "read-error"},
      "listeningMode": "transparency"
    },
    {
      "device": "Studio Beats",
      "listeningMode": "adaptive"
    }
  ],
  "result": "ok"
}
```

If every selected device produces only genuine read errors, the same records are
returned with `"error":"read-error"`, `"result":"error"`, and exit `5`:

```json
{"devices":[{"conversationAwareness":null,"device":"My AirPods Pro","errors":{"conversationAwareness":"read-error","listeningMode":"read-error"},"listeningMode":null}],"error":"read-error","result":"error"}
```

With no compatible device, status JSON is exactly
`{"devices":[],"error":"no-device","result":"error"}` and exits `1`.

`support-report` does not accept `--json` or `--device`. Its options are
`--with-write-tests`, `--no-write-tests`, and `--debug`.

`-h` and `--help` can appear anywhere. Help takes precedence, exits `0`, and
never accesses the device. A recognized resource before the flag selects
contextual help. Version flags are global only and do not accept `--device`.

## Debug diagnostics

Add `--debug` to emit private-API discovery and operation diagnostics on stderr:

```console
$ airpods-control --debug listening-mode get
debug: cli.command="listening-mode.get"
info: audio_context_selector="sharedSystemAudioContext"
info: selected_device="My AirPods Pro"
transparency
```

Debug output covers the entitlement bypass, private API discovery, compatible
devices, selection, capabilities, reads, and writes. It does not change stdout,
JSON, or the exit code, so stdout remains safe to pipe or parse.

`support-report` also accepts `--debug`. Its diagnostics explain device
discovery and advertised capabilities without reading the customizable device
name, but they can include the installed dylib path and therefore a home
directory in a source build. Debug output from operational commands can also
contain selected device names. Review diagnostics before pasting them into an
issue.

## Write verification

Listening-mode writes use a bounded readback window while the device settles.

When the setter accepts `off` but the change cannot be verified and the device
advertises Transparency, `set off` and explicit cycles into `off` report `no-op`
with `listeningMode: "transparency"`. This is the expected eventual fallback
when Off Listening Mode is disabled, not an observed final sample. For rejected
writes or devices without Transparency, the response contains the final observed
canonical mode or `null`.

## Exit codes

| Code | Meaning     | When                                                       |
| ---- | ----------- | ---------------------------------------------------------- |
| `0`  | ok          | Command succeeded, including reads and verified writes.    |
| `1`  | no-device   | No supported target was selected, or no unique identifiable report device was available. |
| `2`  | bad-args    | Arguments are missing or malformed.                        |
| `3`  | no-op       | A write was not verified in the bounded window, or write tests could not restore the initial state. |
| `4`  | unsupported | The mode or feature is not available on the selected device. |
| `5`  | read-error  | Every selected status record contains only genuine read errors. |
| `129` | hangup | An externally delivered SIGHUP was caught during the tests and restoration was attempted. |
| `130` | interrupted | An externally delivered SIGINT was caught during the tests and restoration was attempted. |
| `143` | terminated | An externally delivered SIGTERM was caught during the tests and restoration was attempted. |

Individual-resource plain stdout uses a single token such as `ok`, `no-op`,
`no-device`, `unsupported`, or a mode name. `status` emits headed device
records, and `support-report` emits its terminal-native compatibility report or
local guidance. Scripts can branch on the exit code.
