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
position. `--device` uses a case-insensitive, whole-name match among the
command's compatible devices. It never falls back to another device. For
listening-mode commands, multiple exact matches produce `ambiguous-device`;
the user must give connected devices distinct names. Without `--device`, a
selected AirPods output remains the automatic listening-mode target, and a
single eligible HAL (Core Audio's hardware abstraction layer) device is
selected automatically. If no selected HAL target exists and several HAL
devices remain, an interactive terminal displays them in discovery order and
asks for a displayed number. The chooser is used only when standard input
and standard error are terminals and `--json` is absent. Multiple selected HAL
targets fail closed as `ambiguous-device`; the chooser is not used for that
case. Blank input, `q`, or end of input
prints `cancelled` and exits `1`; automated or JSON ambiguity returns
`ambiguous-device` and exits `1`. Conversation Awareness retains its existing
first compatible AV output behavior. If listening-mode HAL control is entirely
unavailable, the older AV-only behavior likewise keeps the first compatible AV
output. HAL target selection does not add leftover AV records to its chooser.
A unique selected HAL target and unique singular active AV endpoint form one
logical target even when optional status enrichment cannot join them; this
pairing is based on selected-route evidence, never a matching name. A named
AV-only target remains reachable when no HAL name matches.
`status` reports every eligible compatible record it can derive from currently
available Core Audio endpoints, independently of the selected output.

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

Setters are idempotent, meaning that repeating a request for the current state
does not issue another write. If the requested mode is already active, the
command prints `ok`, exits `0`, and does not issue a write. If the change
cannot be verified within the bounded readback window, the command prints
`no-op` and exits `3`:

```console
$ airpods-control lm set noise-cancellation
no-op
```

The provider is selected before any write. A command-ready selected AV endpoint
uses the existing AV control surface; an unselected device uses its mapped Core
Audio HAL output endpoint that exposes `lstm`. In a group with multiple Core
Audio outputs, that control endpoint can differ from the named display endpoint.
Unknown routing tries AV first and may fall back to HAL only if AV preflight
fails before a setter call. Once a setter is attempted,
the command never retries through the other provider. No listening-mode command
changes the default output or starts an audio stream.

A matching bounded readback means the chosen macOS control surface reports the
requested state. It is operational verification for this CLI, not a direct
AirPods protocol acknowledgement.

### List the modes this device supports

```console
$ airpods-control listening-mode list
off,transparency,adaptive,noise-cancellation
```

Modes are always printed in that order, filtered to the modes supported by the
connected device. A HAL-backed list uses the `lsms` capability mask and can
establish Noise Cancellation, Transparency, and Adaptive. HAL does not expose
the separate user-configured Allow Off setting. A HAL-backed command includes
Off only when it can consume recent positive AV evidence for the exact output
endpoint, as described under
[Cached Allow Off availability](#cached-allow-off-availability). Without that
evidence, HAL `list` omits Off, `set off` is unsupported, and Off is removed
from an explicit cycle set. AV-backed commands continue to expose Off when AV
advertises it.

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

### Cached Allow Off availability

The HAL `lsms` mask has no Allow Off bit. To support a connected but unselected
device without changing the audio route, the CLI keeps a weak cache of the
exact output endpoint's latest eligible AV availability observation. Only a
positive observation, where AV advertises Off, can authorize a HAL command.

An AV available-mode read updates this cache only when the read is already
needed for `list`, `set off`, or an explicit cycle set containing Off. A
successful eligible read that includes Off writes or refreshes the positive
observation; a successful eligible read that omits Off removes the positive
observation and writes a negative tombstone. The latest observation time wins,
and a negative observation wins ties, so an older in-flight positive read cannot
restore stale evidence. An AV-backed `listening-mode get` also refreshes the
positive observation when it returns Off. A non-Off current-mode result is not
an availability observation, and incidental current-mode reads made by other
operations do not warm the cache. Selector failures, unavailable endpoints,
and failed reads leave the cache unchanged. The CLI does not perform an extra
AV read solely to warm the cache, and HAL observations never refresh it.

A valid observation lets the exact HAL target include Off in `list`, attempt
`set off`, or retain Off in an explicit cycle set. It never adds Off to the
default cycle. A cache miss preserves the ordinary HAL behavior, including the
minimum-size check after unavailable modes are removed from an explicit cycle
set. Cache correlation happens after target and provider selection; it cannot
select, merge, or disambiguate devices. A missing or nonunique exact endpoint
correlation is a silent miss.

The cache stores positive observations and negative tombstones. Only a positive
observation can add Off or authorize a HAL write. Positive observations expire
seven days after the AV observation, and use does not extend that lifetime.
Negative tombstones only order observations and never authorize a write. A new
eligible observation replaces the older state for that endpoint; a macOS update
does not extend or invalidate a positive observation. Missing, expired,
malformed, or unreadable data is treated as a miss. The disposable,
backup-excluded cache is stored at:

```text
~/Library/Caches/io.github.raulgg.airpods-control/allow-off-v1.json
```

The key is the full SHA-256 digest of a random per-cache salt followed by the
exact, case-sensitive public Core Audio UID. The cache persists the salt,
digest, and observation time. The raw UID is held only transiently and is never
persisted; the raw UID, digest, and salt are never printed or logged.
`support-report` does not access the cache or include its data. Deleting the
cache file safely restores the pre-cache HAL behavior. If a negative update
cannot obtain the bounded shared mutation lock, the cache writes a digest-keyed
deny marker beside the file and later lookups honor it before using positive
evidence. If a negative write fails after taking the lock, the disposable cache
is removed so stale positive evidence cannot remain reusable.

This evidence may be stale if Allow Off changes before another eligible AV read
or an Off write disproves it. Observation timestamps prevent delayed older reads
from overwriting newer reads, with a negative result winning equal timestamps.
If an accepted Off write backed by fresh or cached positive evidence finishes
with a definitive non-Off state, the CLI deletes that positive observation. It
does not create a negative tombstone: only an eligible AV availability read that
omits Off can do that. A rejected write, timeout, failed read, or unknown final
state leaves the observation in place.

A cache-authorized HAL mismatch reports `no-op` with the actual final state and
does not retry through AV, infer a Transparency fallback, or choose a second
cycle target. As with every listening-mode readback, a match is macOS-reported
state, not a direct AirPods acknowledgement.

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

`status` reads the listening mode, Conversation Awareness state, and whether
each compatible device is selected as the macOS audio output or input. It does
not report battery levels, device metadata beyond the name required to identify
each record, or other settings. Compatibility metadata and consented write tests
remain the separate responsibility of `support-report`.

`status` starts with the public `kAudioHardwarePropertyDevices` list. To become
a record, an endpoint must be ordinary and nonaggregate, use classic Bluetooth,
be alive, have an input or output stream, and map through
`IOBluetoothAudioManager.bluetoothDevice:` to an `IOBluetoothDevice`. An
undocumented HAL property identifies Apple audio hardware. If that property is
unavailable, `status` checks an allowlisted Apple or Beats manufacturer. An
endpoint is skipped when a required property or mapping cannot be established
safely.

AirPods and Beats can expose separate input and output Core Audio endpoints.
`status` combines those endpoints when their mapped Bluetooth objects compare
equal in both directions. If both exist, the output endpoint supplies the
preferred name. That Core Audio name is used for display and `--device`
matching, not to join endpoints or determine selection. Record order is
consistent within one inventory but is not a stable interface.

"Selected" means that the record's mapped Bluetooth object matches macOS's
ordinary default output or input after that endpoint passes through the same
mapper. Input and output are checked separately. Playing audio, recording, app
routes, the system-alert route, and aggregate or multi-output membership do not
count. Selection does not use names, model identifiers, Bluetooth addresses,
Core Audio UIDs, private route identifiers, or discovery order.

Without `--device`, the command prints every eligible AirPods or Beats record.
The inventory does not depend on either default, so a device selected only for
input, or for neither direction, still appears.

With `--device`, the command emits one record for the unique case-insensitive
whole-name match. A missing or ambiguous name fails with `no-device`; it never
selects one of several matches. Every plain-text record has a heading, including
a selected singleton:

```console
$ airpods-control status
My AirPods Pro:
  Listening mode: transparency
  Conversation Awareness: on
  Selected as audio output: yes
  Selected as audio input: no

Studio Beats:
  Listening mode: adaptive
  Conversation Awareness: unknown
  Selected as audio output: no
  Selected as audio input: no
```

Device headings retain ordinary printable Unicode but render backslash, newline,
carriage return, and tab as `\\`, `\n`, `\r`, and `\t`. Other control characters
and the Unicode line and paragraph separators use `\u{XXXX}` form, so a device
name cannot alter the record layout. This applies only to the plain heading.
JSON retains the original name and uses normal JSON string escaping. Plain
fields appear beneath the heading in Listening mode, Conversation Awareness,
Selected as audio output, Selected as audio input, and Read errors order.
Inapplicable feature lines are omitted, and records are separated by one blank
line. JSON object keys remain alphabetically sorted and carry no semantic order.

Listening mode is read from three sources in order. The active AV endpoint comes
first, followed by one consistent HAL value from the mapped endpoints. The
mapped Bluetooth object is the last fallback. The HAL property can report the
mode while a device is inactive.

A source must return a recognized value. An unknown active AV value stops the
lookup. A future HAL value or conflicting HAL values do the same. The mapped
object is tried only when HAL is unavailable, neutral, or failed. A failed HAL
read is retained, so `Listening mode` appears under Read errors if the fallback
also fails to resolve the mode.

Conversation Awareness requires the active AV endpoint to remain stable, bind
to the default Core Audio output, and map to the record's Bluetooth object.
Without that join, the value is `unknown`. A name or another endpoint is not
used as a substitute.

A feature field is omitted only when the device is known not to support that
feature. An unresolved listening-mode or Conversation Awareness read appears as
`unknown`. The same fallback is retained for a genuine read failure. Each case
is JSON `null`, with its canonical key still present. This differs from an
individual Conversation Awareness command, whose unsupported fallback remains
`unsupported`.

The selection lines are always present. Plain values are `yes`, `no`, or
`unknown`. JSON records contain `isSelectedAudioOutput` and
`isSelectedAudioInput` as Boolean or `null` values. `no` requires proof that the
device is not selected. A composite default does not select any member, and a
known unrelated transport cannot select a Bluetooth record, so both produce
`no`.

Only a classic-Bluetooth default is sent to the system mapper. A match is `yes`;
a different mapped Bluetooth device is `no`. Bluetooth LE, USB, unknown or
unsupported transports, missing selectors or properties, an unavailable mapper,
or a nil mapping produce `unknown`. A failed default-route, class, transport, or
mapper read is a read error and keeps the same `unknown` fallback. Input and
output failures are independent.

A genuine read failure keeps the field's unresolved fallback and also adds a
plain summary such as `Read errors: Listening mode, Audio input selection`,
indented by two spaces, or an `errors` object in that device's JSON record.
Errored labels use the fixed field order Listening mode, Conversation Awareness,
Audio output selection, Audio input selection. One failed field does not hide a
successfully read field or stop the remaining fields and devices from being
sampled. Input and output selection failures are isolated from each other.

For example, when both feature reads and the input-selection read genuinely
fail, the record retains their fallback states and names all three errors:

```text
My AirPods Pro:
  Listening mode: unknown
  Conversation Awareness: unknown
  Selected as audio output: yes
  Selected as audio input: unknown
  Read errors: Listening mode, Conversation Awareness, Audio input selection
```

A record whose two feature fields are both proven unsupported still includes
its two selection observations.

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

Each `status` invocation reads the available Core Audio inventory once and
shares the same default-route observations across its records. Input and output
are read independently, so the pair is not an atomic system-wide snapshot. The
selected defaults do not affect inventory or deduplication.

An `AudioDeviceID` is an opaque Core Audio handle. `status` passes it unchanged
to Core Audio and the system mapper. Its numeric value is not parsed, logged,
printed, or compared as identity. Inventory and selection do not read raw Core
Audio UIDs, Bluetooth/MAC addresses, serial numbers, or private route IDs. HAL
property values are converted to bounded capability and state values, but the
raw values are not logged or printed.

Active-output enrichment is the exception that reads route identifiers. It asks
Core Audio to translate `AVOutputContext.associatedAudioDeviceID`, then compares
the resulting handle with the stable default output. The default's mapped
Bluetooth object must also match the record. The probe samples the private
`AVOutputDevice.deviceID` before and after to reject an endpoint change. These
identifiers stay inside the process and never appear in output, diagnostics, or
a support report. Enrichment failure does not change input or output selection.

## Contributor compatibility report

Compatibility varies by device, firmware, and macOS version, and a product name
alone does not establish support. See the [device compatibility
matrix](compatibility.md) for current per-device, per-command results. Reports
are welcome, and the matrix tracks each command separately.

Connect exactly one compatible AirPods or Beats device as a macOS output device,
then run:

```console
$ airpods-control support-report
Write tests
────────────────────────────────────────────
Plan
  Listening modes          adaptive, transparency, off (about 2s each)
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
does not enumerate the Core Audio status inventory, query the selected input or
output route, call the selection mapper, run active-output enrichment, or read
or report routing identifiers. It never uses the clipboard, sends telemetry, or
submits anything. A read-only report does not change device settings or
intentionally interrupt audio; consented write tests temporarily change the
settings in the captured plan.

`support-report` does not read customizable names or accept `--device`, so it
requires exactly one compatible output device. With zero or multiple compatible
devices it prints local instructions and exits `1` before a report, prompt, or
write.

### Consented write tests

When at least one write test can be planned safely, an interactive
`support-report` run (standard input connected to a terminal, or TTY) captures
the initial settings and advertised capabilities, displays that plan, and asks
for consent. The default answer is no. Declining
produces the read-only report, marked `Write tests: not run`. The captured plan
does not change after it is disclosed. If a setting changes while consent is
pending, that setting is skipped rather than replaced with a different write.

The listening-mode plan contains the advertised modes recognized by this CLI. It
probes them in reverse canonical order (`noise-cancellation`, `adaptive`,
`transparency`, then `off`) so an Off write that falls back to Transparency
cannot make the Transparency probe already-current. The captured initial mode
is included in that sequence when it is not already first. If the state
changed, the captured initial mode is restored last. All listening-mode writes
are skipped if the setter is missing, the initial mode is unreadable or not
advertised, or there is no alternate recognized advertised mode to test.

Conversation Awareness is toggled away from the captured initial state and back.
It is skipped if its setter or initial state is unavailable. Both features use
the same bounded readback verification as their operational commands.

The tests may be disruptive: mode switches are audible, noise control changes
while the device is worn, and Conversation Awareness toggles briefly. Do not run
them during a call. Consent only if you accept this.

After normal completion or a setter error, the command makes one restoration
attempt if needed. An accepted write that cannot be verified is a `no-op` and
does not stop the remaining tests. A `setter error` stops the remaining tests
for that setting. Probe order is chosen so a disabled Off mode, which falls
back to Transparency, is tested last and does not hide a Transparency
transition. A write whose target already matches the state read immediately
before it still cannot demonstrate a transition and is
`inconclusive (already in this state; no transition demonstrated)`, not
`verified`. That verdict is a safety net for unexpected already-current
writes; it does not establish support.

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
  Noise cancellation       VERIFIED
  Adaptive                 VERIFIED
  Transparency             VERIFIED
  Off                      NO-OP
  Conversation Awareness   VERIFIED
  CA restoration           VERIFIED
  Summary                  5 verified · 1 no-op
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

Without `--device`, listening-mode commands automatically use the selected
AirPods output or one unique eligible HAL target. When no selected HAL target
exists and multiple HAL targets remain, a fully interactive terminal presents a
numbered chooser; multiple selected HAL targets fail closed. Automated and JSON
invocations fail with `ambiguous-device`. Conversation
Awareness retains the first compatible AV output behavior. `status` reports
every eligible canonical device derived from the currently available Core Audio
endpoint list, regardless of which device is the selected output. To select one
explicitly:

```console
$ airpods-control --device "My AirPods Pro" listening-mode get
transparency
```

Unlike operational commands, `support-report` does not read device names or
accept `--device`. It requires exactly one compatible output device.

`status` and HAL-backed listening-mode commands match the preferred Core Audio
display name after exact endpoint deduplication; AV-backed commands match their
AV output-device names. Matches are exact but case-insensitive. Substrings are
not accepted, so `--device "My"` will not silently select `"My AirPods Pro"`. If
two devices have the same name ignoring case, a listening-mode command fails
with `ambiguous-device` before reading or changing either one. Other commands
retain their existing `no-device` ambiguity result. Name matching targets an
existing record; it is not device identity or correlation. A name passed on the
command line must not begin with `-`; this prevents an option token from being
consumed as a missing `--device` value.

Allow Off cache correlation is a separate, downstream step for an already
selected output endpoint. It never changes name matching, target selection,
endpoint deduplication, or provider routing. Failure to correlate exactly one
endpoint is a silent cache miss.

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
{"devices":[{"conversationAwareness":"on","device":"My AirPods Pro","isSelectedAudioInput":false,"isSelectedAudioOutput":true,"listeningMode":"transparency"}],"result":"ok"}
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

$ airpods-control listening-mode get --json
{"device":null,"error":"ambiguous-device","listeningMode":null,"result":"error"}
```

The second shape applies only when multiple eligible listening-mode targets
remain; JSON never opens the interactive chooser.

`listening-mode list` also returns `supportedListeningModes`. An unverified
write uses `"result":"no-op"` and exits `3`. The response contains the final
canonical state read during the bounded settling window, the Transparency
fallback, or JSON `null` when neither applies. Version JSON follows the same
result convention: `{"result":"ok","version":"0.1.0"}`.

When a listening-mode command actually consumes cached AV evidence to make Off
available through HAL, its JSON response also contains
`allowOffAvailability`. The object reports `source` as
`"cached-av-observation"`, plus RFC 3339 `observedAt` and `expiresAt`
timestamps. Live AV evidence, HAL behavior that did not need the observation,
and cache misses omit the object. Plain output never changes because of cache
provenance.

`status` always returns a top-level `devices` array, including when `--device`
selects a single device. Each record has `device`; applicable canonical resource
keys `listeningMode` and `conversationAwareness`; and the always-present Boolean
or `null` keys `isSelectedAudioOutput` and `isSelectedAudioInput`. Aliases such
as `lm` and `ca` never appear in JSON. A resource key is omitted for a
proven-unsupported feature and present with JSON `null` for an unresolved read.
An unresolved selection is also JSON `null`, but its key is never omitted. A
genuine read failure additionally adds an `errors` map whose affected canonical
field key maps to `"read-error"`; selection errors use
`isSelectedAudioOutput` and `isSelectedAudioInput`. The map is absent when no
genuine read error occurred. Objects are serialized with sorted keys. For
example, this mixed scan still succeeds:

```json
{
  "devices": [
    {
      "conversationAwareness": null,
      "device": "My AirPods Pro",
      "errors": {"conversationAwareness": "read-error"},
      "isSelectedAudioInput": false,
      "isSelectedAudioOutput": true,
      "listeningMode": "transparency"
    },
    {
      "device": "Studio Beats",
      "isSelectedAudioInput": null,
      "isSelectedAudioOutput": false,
      "listeningMode": "adaptive"
    }
  ],
  "result": "ok"
}
```

If every selected device produces only genuine read errors, the same records are
returned with `"error":"read-error"`, `"result":"error"`, and exit `5`:

```json
{"devices":[{"conversationAwareness":null,"device":"My AirPods Pro","errors":{"conversationAwareness":"read-error","isSelectedAudioInput":"read-error","isSelectedAudioOutput":"read-error","listeningMode":"read-error"},"isSelectedAudioInput":null,"isSelectedAudioOutput":null,"listeningMode":null}],"error":"read-error","result":"error"}
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
info: listening_mode.transport="av"
transparency
```

Debug output covers discovery, selection, reads, writes, and the entitlement
bypass. Status logs the result of each inventory and selection gate, using terms
such as `mapped`, `composite`, and `unresolved`. It does not log Core Audio
handles, raw HAL values, addresses, UIDs, or private route IDs. The enrichment
probe also keeps `associatedAudioDeviceID`, its translated handle, and the
private endpoint `deviceID` out of the log. Operational HAL diagnostics may
include bounded numeric property values and OSStatus codes (numeric status
codes returned by macOS), but never the Core Audio device ID, UID, Bluetooth
address, serial, or object description.
Operational diagnostics may include the displayed device name, but names are
not used as identity. Allow Off cache diagnostics are limited to hit or miss and
record age; they never include the Core Audio UID, cache digest, salt, key, or
contents. `--debug` does not change stdout, JSON, or the exit code.

`support-report` also accepts `--debug`. Its diagnostics omit the customizable
device name, though a source build can expose a home directory through the
installed dylib path. The command does not use the Core Audio status inventory,
selection mapping, or enrichment path. Operational diagnostics can contain a
selected device name, but not raw routing identifiers. Review the output before
pasting it into an issue.

## Write verification

Listening-mode writes use a bounded same-provider readback window while the
device settles. A matching readback means the selected macOS AV or HAL control
surface reports the requested state; it is not a direct protocol-level
acknowledgement from the AirPods.

When the setter accepts `off` but the change cannot be verified and the device
advertises Transparency, `set off` and explicit cycles into `off` report `no-op`
with `listeningMode: "transparency"`. This is the expected eventual fallback
when Off Listening Mode is disabled, not an observed final sample. For rejected
writes or devices without Transparency, the response contains the final observed
canonical mode or `null`.

A cache-authorized HAL Off write uses the stricter cache contract instead. If
its definitive final read is a known non-Off mode, that actual mode is returned
with `no-op` and the positive observation is deleted. The command does not use
the inferred Transparency fallback, retry through AV, or select another cycle
target. Rejection, timeout, read failure, or an unknown final state does not
delete the observation.

## Exit codes

| Code | Meaning     | When                                                       |
| ---- | ----------- | ---------------------------------------------------------- |
| `0`  | ok          | Command succeeded, including writes with matching macOS readback. |
| `1`  | selection  | No target, an ambiguous target, chooser cancellation, or no unique identifiable report device. |
| `2`  | bad-args    | Arguments are missing or malformed.                        |
| `3`  | no-op       | A write was not verified in the bounded window, or write tests could not restore the initial state. |
| `4`  | unsupported | The mode or feature is not available on the selected device. |
| `5`  | read-error  | Every selected status record contains only genuine read errors. |
| `129` | hangup | An externally delivered SIGHUP was caught during the tests and restoration was attempted. |
| `130` | interrupted | An externally delivered SIGINT was caught during the tests and restoration was attempted. |
| `143` | terminated | An externally delivered SIGTERM was caught during the tests and restoration was attempted. |

Individual-resource plain stdout uses a single token such as `ok`, `no-op`,
`no-device`, `ambiguous-device`, `cancelled`, `unsupported`, or a mode name.
`status` emits headed device records, and `support-report` emits its
terminal-native compatibility report or local guidance. Scripts can branch on
the exit code.
