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

During code review, confirm that status starts with public
`kAudioHardwarePropertyDevices`. It may admit only an ordinary, nonaggregate
classic-Bluetooth endpoint that is alive and ready, has an audio stream, and
maps through `IOBluetoothAudioManager.bluetoothDevice:` to an
`IOBluetoothDevice`. The HAL Apple-audio property is the primary compatibility
check. An allowlisted Apple or Beats manufacturer is allowed only when that
property is unavailable.

Input and output endpoints may form one record only when their mapped objects
compare equal in both directions. Prefer the output endpoint. A Core Audio name
may be used for display and exact `--device` matching, but never for identity or
deduplication.

The active AV endpoint supplies the highest-priority listening mode. Otherwise,
use one consistent recognized HAL mode from the mapped endpoints. A future or
unknown active AV or HAL value, and conflicting HAL values, must leave the mode
`unknown` and block a lower-priority fallback. The mapped Bluetooth object is a
fallback only when HAL is unavailable or neutral, or when a HAL read fails. Keep
that failure: if the fallback does not resolve the mode, report `unknown` with a
Listening mode read error. Never log or print raw HAL values.

For each selection direction, read the ordinary default Core Audio endpoint.
Reject aggregate and multi-output routes, classify the transport, and map only a
classic-Bluetooth default. Compare mapped objects in both directions. Known
unrelated transports must produce `no`. Bluetooth LE, USB, unknown transports,
missing properties, and unavailable or nil mappings must produce `unknown` (JSON
`null`). A failed default-route, class, transport, or mapper read must be a
field-specific read error.

Core Audio handles may pass unchanged to property APIs and the mapper, but they
must never be parsed, logged, or printed. Inventory and selection must not use
names, model identifiers, Bluetooth/MAC addresses, Core Audio UIDs, private
route identifiers, or discovery order as identity. If either direction requires
heuristic correlation, it must remain `unknown`. An `unknown` result on the
AirPods Pro 3 baseline in any row above means the feature is incomplete.

The optional active-output feature probe may ask Core Audio to translate the AV
context's bounded `associatedAudioDeviceID` and compare the result only with the
stable default output. The default's mapped Bluetooth object must also match the
record. The probe may sample the private endpoint `deviceID` before and after
only to reject an endpoint change. Its active AV mode has priority when
available. These identifiers must not determine Bluetooth identity or selection,
and they must never be logged, printed, or included in a support report. Without
the exact join, Conversation Awareness must remain `unknown`. Listening mode may
still come from HAL or the mapped Bluetooth object, but never from another
device.

The captures contain the customizable device name and can contain source-build
or home paths. Review and redact them before sharing, then delete the private
capture directory after recording the Boolean outcomes.

## Left/right ear placement status check

This check verifies that HAL wins and that BLE fills in when HAL cannot. It is
read-only and does not require the AirPods to be the selected audio output.
Build once with `make`, then run the only command allowed to request Bluetooth
permission:

```sh
build/airpods-control bluetooth setup
build/airpods-control bluetooth status --json
```

Test Terminal, a source shell, Homebrew installation, and any supported
automation launch context separately. Record authorized, denied, restricted,
powered-off, and not-determined behavior. `status` must not show a permission
prompt. Then run `status` in each state below:

| State | Left bud | Right bud |
| --- | --- | --- |
| Both worn | in ear | in ear |
| Left removed | out of ear or in case | in ear |
| Right removed | in ear | out of ear or in case |
| Both removed | out of ear | out of ear |
| Both in case, lid open | HAL: in case; BLE: unknown or stale | HAL: in case; BLE: unknown or stale |
| Both in case, lid closed | HAL: in case; BLE: unknown | HAL: in case; BLE: unknown |

Capture plain and JSON output for every state, allowing a short pause after
each placement change for macOS to publish the state:

```sh
build/airpods-control status --device "My AirPods" \
  >"$capture_dir/placement-both.txt"
build/airpods-control status --device "My AirPods" --json \
  >"$capture_dir/placement-both.json"
```

Replace the suffix for the remaining states. HAL may use `in-case`. BLE may
use only `in-ear` or `out-of-ear`. Closed-case silence, a single frame,
conflicts, and missing identity must be `unknown`. Repeat the matrix with
AirPods selected for output, selected for input only, selected for neither,
while playing audio, and after Core Audio drops the endpoints. An enrolled
accessory seen in the current scan can create a record without an endpoint.
Route and listening-mode fields on that record must stay `unknown`.

Also check primary-side flips, one-bud transitions, open and closed case,
reconnect, sleep/wake, reboot, and Bluetooth privacy-address rotation. The same
public CoreBluetooth identifier should still select the same enrolled accessory.
With two same-model accessories nearby, automatic learning must stay incomplete
rather than guess. BLE frames can carry stale sensor state, so wait after each
transition and record stale bits separately from a missing second callback. Do
not record raw frames, identifiers, UID digests, Core Audio handles, or
Bluetooth addresses in the capture or issue.

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
