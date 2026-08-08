# Hardware testing

Use this guide to verify private-API behavior across an AirPods placement
change. Record the macOS version and device in the pull request, and update the
[device compatibility matrix](compatibility.md) when a check changes a device or
capability status.

## Selected audio input/output release check

This check is required before selected-audio-device status is considered
complete. Run it on the AirPods Pro 3 baseline hardware. Record the exact macOS
and CLI versions in the pull request, but do not record Core Audio, Bluetooth,
or private routing identifiers.

Use the built-in Mac speakers and microphone as the alternate endpoints when
possible. Do not use an aggregate or multi-output device for the four baseline
cases. Build once with `make`, connect the AirPods, and then test each row after
System Settings visibly shows both selections:

| Case | macOS output | macOS input | Plain output | JSON |
| --- | --- | --- | --- | --- |
| Output only | AirPods | Built-in microphone | `yes`, then `no` | output `true`, input `false` |
| Input only | Built-in speakers | AirPods | `no`, then `yes` | output `false`, input `true` |
| Both | AirPods | AirPods | `yes`, then `yes` | output `true`, input `true` |
| Neither | Built-in speakers | Built-in microphone | `no`, then `no` | output `false`, input `false` |

For each row, set `case_name` to `output-only`, `input-only`, `both`, or
`neither`, then capture both forms:

```sh
capture_parent="${TMPDIR:-/tmp}"
capture_previous_umask="$(umask)"
umask 077
capture_dir="$(
  mktemp -d "${capture_parent%/}/airpods-control-selection.XXXXXX"
)" || exit 1
chmod 700 "$capture_dir"

case_name=output-only
build/airpods-control status --device "My AirPods" \
  >"$capture_dir/$case_name.txt"
build/airpods-control status --device "My AirPods" --json --debug \
  >"$capture_dir/$case_name.json" \
  2>"$capture_dir/$case_name.debug.log"
```

Reuse the same private directory for the remaining rows. After the last capture,
restore the saved mask with `umask "$capture_previous_umask"`. If you stop
early, restore it before leaving the shell.

For every case, verify:

- The AirPods retain a status record in all four cases, including input-only and
  neither; the currently available Core Audio inventory must not depend on the
  selected output.
- Plain fields remain in Listening mode, Conversation Awareness, Selected as
  audio output, Selected as audio input, and Read errors order.
- JSON contains `isSelectedAudioOutput` and `isSelectedAudioInput` with the
  Boolean values in the table. Object keys may appear in sorted order.
- When the system HAL listening-mode properties yield one safe recognized mode,
  Listening mode stays canonical in input-only and neither instead of becoming
  unknown. Future, unrecognized, or conflicting HAL evidence must remain
  unknown; it must not borrow the mapped system Bluetooth object's mode. That
  mapped value is a fallback only for unavailable, neutral, or failed HAL
  evidence. Conversation Awareness may be unknown without the exact
  active-output join.
- Repeating the command without changing System Settings produces the same
  selection pair.
- Neither normal output nor debug output contains an opaque Core Audio device
  handle, Bluetooth/MAC address, Core Audio UID, private device identifier, or
  other routing identifier. Debug output may state only bounded inventory and
  routing results, plus numeric system error codes.

Code review must first confirm that status enumerates public
`kAudioHardwarePropertyDevices` and admits only ordinary, nonaggregate classic-
Bluetooth endpoints that are alive and ready, have at least one audio stream,
and map through `IOBluetoothAudioManager.bluetoothDevice:` to the expected
canonical `IOBluetoothDevice` type. The system HAL Apple-audio capability must
be the primary compatibility admission signal; an allowlisted Apple or Beats
manufacturer may be used only when that property is unavailable. Separate input
and output endpoints may be deduplicated only by symmetric exact object
equality, with the output endpoint preferred deterministically. The Core Audio
name may be used for display and exact `--device` targeting only, never for
correlation or deduplication. A system HAL current-mode property may populate
listening mode for inactive records, but its raw value must never be logged or
emitted. Resolution must prefer a safe recognized
exact active AV value, then one consistent recognized mode across the exactly
deduplicated HAL endpoints. If active AV exposes an unrecognized value, or HAL
evidence contains a future or unrecognized nonzero value or conflicting
recognized modes, Listening mode must remain `unknown` and lower-priority
inference must be suppressed. Only unavailable or neutral HAL evidence, or a HAL
read failure, may fall back to a recognized mode from the exact mapped system
Bluetooth object. A failed HAL read must be retained: if that fallback does not
resolve the mode, Listening mode is `unknown` with a read error.

For selection, each direction must read the ordinary default Core Audio
endpoint, reject aggregate and multi-output devices, classify the transport,
and map only a classic-Bluetooth endpoint through the same mapper before
comparing symmetric exact object equality. Known unrelated transports must
produce `no`; Bluetooth LE, USB, unknown or unsupported transports, unavailable
selectors or properties, and unavailable or nil mappings must produce `unknown`
(JSON `null`). An actual failure reading the default route, device class, or
transport, or performing an available mapper operation, must be a field-specific
read error. Opaque Core Audio handles may be passed unchanged to public property
APIs and the mapper, but must never be parsed, logged, or emitted. Inventory and
selection must not read or correlate display names, model identifiers,
Bluetooth/MAC addresses, Core Audio UIDs, private route identifiers, or
discovery order. If either direction can only be correlated heuristically, it
must remain `unknown`; if that happens on the AirPods Pro 3 baseline in any row
above, the feature is not complete.

Code review may find one separate, optional active-output feature-enrichment
probe. It may translate the AV output context's bounded
`associatedAudioDeviceID` through Core Audio and compare the resulting device
ID only with the stable default output ID. The default endpoint's mapped
Bluetooth object must also exactly equal the record's canonical object. The
probe may compare the private endpoint `deviceID` only before and after to reject
an endpoint change. Its exact active AV mode takes precedence when available.
None of these identifiers may be used as Bluetooth identity or selection
evidence, logged, printed, or included in a support report. Without this exact
join, Conversation Awareness must remain `unknown`. Listening mode may still
come from the record's HAL property or its mapped system Bluetooth object;
otherwise it too remains `unknown`, never borrowed from another device.

The captures contain the customizable device name and can contain source-build
or home paths. Review and redact them before sharing, then delete the private
capture directory after recording the Boolean outcomes.

## One-earbud feature-control regression check

Individual resource commands still use the private AV output context for feature
control. Their unit tests can model an AirPods endpoint whose listening-mode
capabilities disappear or whose plural routing list omits the current device.
Only connected hardware can verify that behavior across an earbud placement
change. Run this check on the same Mac and AirPods before merging a
feature-control discovery change. Status inventory is separate and must keep an
eligible record derived from the currently available Core Audio endpoints
independently of the active output.

1. Build once with `make`, wear both earbuds, and confirm the AirPods are the
   selected macOS input and output devices.
2. Create an owner-only capture directory, then capture a capability baseline.
   Run all commands in the same shell and replace `My AirPods` if the customized
   name differs:

   ```sh
   capture_parent="${TMPDIR:-/tmp}"
   capture_previous_umask="$(umask)"
   umask 077
   capture_dir="$(
     mktemp -d "${capture_parent%/}/airpods-control.XXXXXX"
   )" || exit 1
   chmod 700 "$capture_dir"
   printf 'Private capture directory: %s\n' "$capture_dir"

   build/airpods-control --device "My AirPods" \
     listening-mode get --json --debug \
     >"$capture_dir/both-listening-mode.json" \
     2>"$capture_dir/both.debug.log"
   build/airpods-control --device "My AirPods" \
     listening-mode list --json --debug \
     >"$capture_dir/both-listening-modes.json" \
     2>>"$capture_dir/both.debug.log"
   build/airpods-control --device "My AirPods" \
     conversation-awareness get --json --debug \
     >"$capture_dir/both-conversation-awareness.json" \
     2>>"$capture_dir/both.debug.log"
   ```

3. Remove one earbud without putting it in the case. Verify in System Settings
   that the AirPods remain both the selected input and selected output, then
   run:

   ```sh
   build/airpods-control --device "My AirPods" \
     listening-mode get --json --debug \
     >"$capture_dir/one-listening-mode.json" \
     2>"$capture_dir/one.debug.log"
   build/airpods-control --device "My AirPods" \
     listening-mode list --json --debug \
     >"$capture_dir/one-listening-modes.json" \
     2>>"$capture_dir/one.debug.log"
   build/airpods-control --device "My AirPods" \
     conversation-awareness get --json --debug \
     >"$capture_dir/one-conversation-awareness.json" \
     2>>"$capture_dir/one.debug.log"
   umask "$capture_previous_umask"
   ```

   If you stop before completing this block, restore the saved mask with
   `umask "$capture_previous_umask"`.
4. Compare the matching JSON files and these debug keys in `both.debug.log` and
   `one.debug.log`:

   - `discovery.context_plural_count`
   - `discovery.context_singular_present`
   - `discovery.candidate_*_sources`
   - `device.*.available_modes`
   - `device.*.transient_empty_modes`

5. If the one-earbud run selects the device, test only settings macOS currently
   permits. Toggle Conversation Awareness away from its initial value and back.
   Switch to Transparency and restore the initial listening mode. Test Noise
   Cancellation last: unless **Noise Cancellation with One AirPod** is enabled
   in Accessibility settings, a rejected or unverified ANC write is expected.

The regression check passes when the plural or singular system-audio context
retains the endpoint and the CLI can apply and read back every setting that
System Settings permits in the same state. Do not add another discovery backend
to the individual resource commands or make `--debug` change which devices are
discovered.

The debug logs can contain the customized device name and source-build or home
paths. Review and redact the capture before sharing it, then delete the private
capture directory when the comparison is complete.
