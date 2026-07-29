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
airpods-control support-report [--with-write-tests | --no-write-tests]
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

`support-report` is a separate contributor command. It accepts only
`--with-write-tests` or `--no-write-tests` (mutually exclusive), which answer
its write-test consent question in advance. The report has a fixed set of
fields. The consent prompt and result rows depend on the device.

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

## Contributor compatibility report

The CLI has only been verified with AirPods Pro 3. Other AirPods may work when
macOS exposes the same private audio capabilities. We have not verified Beats,
but reports are welcome. The [device compatibility matrix](compatibility.md)
tracks each command separately.

Connect exactly one compatible AirPods or Beats device as a macOS output
device, then run:

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
  airpods-control          0.1.0

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

The terminal report uses plain text with separate Device, Capabilities, and
Write tests sections. Labels align in an 88-column layout and long values wrap.
When stdout is a terminal, color distinguishes headings and statuses.
Redirected output is plain text; `NO_COLOR` or `TERM=dumb` also disables color.

The read-only compatibility document includes only the normalized model
identifier, the advertised listening modes, the advertised Conversation
Awareness capability, whether the listening-mode and Conversation Awareness
queries answer, whether macOS exposes their setters, the macOS version, and the
CLI version. The model name is resolved locally: the model identifier embeds
the Bluetooth product ID, and the CLI maps known product IDs to model names
(see the [device compatibility matrix](compatibility.md)).

Unknown advertised listening modes appear verbatim under `Other modes`. The
report lists at most six and drops names outside its character allowlist.
Missing values appear as `Unavailable / not reported`. The command does not
guess them.

The read-only report says whether queries answer and setters exist, but it does
not include the setting values returned by those queries and never invokes a
setter. A consented run reads setting values locally only to plan, verify, and
restore its writes. If restoration cannot be verified, the report names the
final state so it can be restored manually. The prefilled Compatibility report
field includes the same per-mode verdicts but omits the restoration outcome.

### Consented write tests

When at least one write test can be planned safely, an interactive
`support-report` captures the initial settings and advertised capabilities,
displays that plan, and asks for consent. The default answer is no. Declining
produces the read-only report, marked `Write tests: not run`. The captured plan
does not change after it is disclosed. If a setting changes while consent is
pending, that setting is skipped rather than replaced with a different write.

The listening-mode plan contains the advertised modes recognized by this CLI.
It attempts each noninitial mode and, if the state changed, restores the
captured initial mode last. All listening-mode writes are skipped if the setter
is missing, the initial mode is unreadable or not advertised, or there is no
alternate recognized advertised mode to test. Each completed listening-mode
write is held for about two seconds before the next write or before the report
is printed.

Conversation Awareness is toggled away from the captured initial state and
back. It is skipped if its setter or initial state is unavailable. Both
features use the same bounded readback verification as their operational
commands.

The tests may be disruptive: mode switches are audible, noise control changes
while the device is worn, and Conversation Awareness toggles briefly. Do not
run them during a call. Consent only if you accept this.

After normal completion or a setter error, the command makes one restoration
attempt if needed. An accepted write whose readback does not verify
is reported as a `no-op` and does not stop the remaining tests. A setter
rejection is reported as `setter error` and stops the remaining tests for that
setting. Each write gets its own result row, so a restoration failure is
attributed to the restoring write rather than folded into the write it was
restoring. A write whose target already equals the state read immediately
before it (for example after an Off write fell back to Transparency) cannot
demonstrate a transition; if its readback still matches, both output adapters
report it as `inconclusive (already in this state; no transition
demonstrated)` rather than `verified`.

The terminal always states the restoration outcome: `RESTORED`, `NOT NEEDED`,
or `NOT RESTORED`. A failed restoration names the final state, gives a
manual-fix hint, and exits `3`. An externally delivered SIGHUP, SIGINT, or
SIGTERM caught during the tests stops further writes, prints `Interrupt caught;
restoring initial settings...` on stderr, attempts restoration first, prints
any restoration warning, and then exits `129`, `130`, or `143`, respectively.
SIGKILL, a process crash, or power loss cannot guarantee restoration. The CLI
does not generate thread-directed signals; those are outside this
process-signal guarantee. An interrupted run does not offer or print an
issue-form URL. A consented report shows each result and a compact summary:

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

The command builds one `SupportReportDocument` and passes it to separate
terminal and GitHub renderers. Capture, privacy filtering, verdict
classification, and restoration interpretation happen before rendering. Each
write gets its own row, so a Conversation Awareness toggle that verified stays
visible even when its restore then fails. The GitHub renderer uses the same
Device, Capabilities, and Write tests sections. It includes every per-mode
verdict but omits the restoration status and the terminal review footer. The
issue form supplies the Compatibility report heading. The listening-mode row
that restored the initial mode carries no restore label, and if the state never
left the captured initial mode, the untested `listening-mode set` row does not
name that mode.

`--with-write-tests` answers the consent question with yes and is the only
way to run the tests when standard input is not interactive, for example
under a script. `--no-write-tests` answers it with no. Without a flag, a
noninteractive run skips the tests and notes the flag on stderr.

It never reads the customizable device name, firmware version, serial numbers,
Bluetooth/MAC addresses, account data, or raw system dumps and logs. A
read-only report does not change device settings or intentionally interrupt
audio. Consented write tests temporarily change the settings in the captured
plan. The command never uses the clipboard, sends telemetry, or submits
anything.

`support-report` does not read customizable names or accept `--device`, so it
requires exactly one compatible output device. With zero or multiple compatible
devices it exits `1` before a report, prompt, or write.

After the write-test prompt and any tests finish, the report appears in the
terminal before the issue-opening question. The GitHub issue form keeps the
generated Compatibility report separate from optional contributor notes and
requires an unchecked privacy-review confirmation. It adds the `compatibility`
label and assigns the issue to `raulgg`; you still review and submit the issue.

The CLI selects `compatibility-report.yml`, prefills the dynamic title through
GitHub's `title` query parameter, and prefills the generated report through the
form field ID `report`. If the encoded URL is too long, the command leaves the
report in the terminal and opens the same form with the title but without the
report field. Copy the reviewed terminal report into the required
Compatibility report field.

The issue-opening question is asked only when standard input is interactive.
For a completed run under a script, pipeline, or CI, the command prints the
report and writes the issue form URL to stderr without prompting
or opening a browser, then returns the report outcome: normally `0`, or `3`
when consented write tests cannot restore the initial settings. Unless the
length cap above applies, the URL carries the generated report field with
write-test verdicts but without restoration status.

If the command cannot select one unique identifiable AirPods or Beats device,
it prints local instructions, exits `1`, and stops. Reports from other AirPods
and Beats owners are welcome, but a report does not make a Beats device
supported.

## Target a device

Without `--device`, the first compatible system output device is used. To
select one explicitly:

```console
$ airpods-control --device "My AirPods Pro" listening-mode get
transparency
```

Unlike operational commands, `support-report` does not read device names or
accept `--device`. It requires exactly one compatible output device.

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

`support-report` does not accept `--json`, `--debug`, or `--device`. Its only
options are `--with-write-tests` and `--no-write-tests`.

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
| `1`  | no-device   | No supported target was selected, or no unique identifiable report device was available. |
| `2`  | bad-args    | Arguments are missing or malformed.                        |
| `3`  | no-op       | A write was not verified in the bounded window, or write tests could not restore the initial state. |
| `4`  | unsupported | The mode or feature is not available on the selected device. |
| `129` | hangup | An externally delivered SIGHUP was caught during the tests and restoration was attempted. |
| `130` | interrupted | An externally delivered SIGINT was caught during the tests and restoration was attempted. |
| `143` | terminated | An externally delivered SIGTERM was caught during the tests and restoration was attempted. |

Operational plain stdout uses a single token such as `ok`, `no-op`,
`no-device`, `unsupported`, or a mode name. `support-report` instead emits its
terminal-native compatibility report or local guidance. Scripts can branch on
the exit code.
