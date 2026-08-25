---
status: accepted
---

# Use route-aware AV and HAL listening-mode control

Operational listening-mode commands select one macOS-owned control transport
for one target: private `AVOutputDevice` APIs when the device is positively
selected as the ordinary default audio output, or Core Audio HAL properties
when an eligible device is positively known to be unselected. This lets the CLI
control connected AirPods without changing the audio route while retaining the
existing AV behavior for the selected output. In this decision, *transport*
means the AV or HAL control surface, not the underlying Bluetooth radio
transport.

## Decision

The route-aware architecture applies to operational `listening-mode get`,
`list`, `set`, and `cycle` commands. Aggregate `status`, Conversation Awareness,
and `support-report` keep their separate discovery and capability contracts.

The target and transport chooser follows these rules:

- A target proven to be the selected ordinary output tries AV first for that
  command. If AV lacks a required state, capability, or setter before any
  mutation, a HAL-supported operation may use HAL. An eligible target proven
  not to be that output uses HAL only. With unknown route evidence, AV is tried
  first and HAL may be used only after an AV preflight failure. Composite,
  conflicting, or changing route evidence does not silently classify a target
  as unselected.
- `--device` remains a case-insensitive whole-name targeting aid, not device
  identity. A match must resolve to one logical target before any operation.
- HAL target selection never concatenates uncorrelated AV records into its
  candidate list. An exact Core Audio/AV join attaches the selected AV
  transport. If that optional enrichment probe is unavailable, one selected
  HAL target and one singular active AV endpoint are also treated as one
  logical target and use AV first; names are never used for that correlation.
  If multiple HAL targets remain, an interactive chooser is permitted only
  when standard input and standard error are TTYs and JSON output was not
  requested. Other HAL-backed ambiguity fails with `ambiguous-device`;
  discovery order never selects one of those devices. A named AV-only target
  remains reachable when it has no HAL match. When HAL is entirely unavailable,
  the established AV-only behavior of choosing the first compatible AV output
  is retained for older macOS versions.
- Once preflight chooses a transport, it is sticky for the command. Capability
  reads, current-state reads, any setter call, and bounded readback all use that
  same transport. A disappearing property, route change, or failed read does not
  cause AV-to-HAL or HAL-to-AV fallback. A later invocation may choose again.

Each command uses the chosen transport as follows:

| Command | Same-transport operation |
| --- | --- |
| `get` | Read and translate the current mode. |
| `list` | Read the current mode and the transport's available-mode inventory. |
| `set` | Read current and available modes, reject an unavailable target, avoid an idempotent write, then write and perform bounded readback. |
| `cycle` | Read current and available modes, derive the canonical next target, then write and perform bounded readback. |

No command changes the default output, starts audio I/O, or plays silence to
make an AV endpoint appear. The CLI does not open a raw AACP/L2CAP session or
send AACP packets itself. macOS remains the owner of Bluetooth authentication,
session lifetime, serialization, and device communication; HAL-backed writes
go through the system audio stack.

## HAL contract

The HAL provider is runtime-gated on exact property presence, scope, element,
size, and writability. It uses global scope and the main element for both
properties:

| Selector | ABI | Meaning |
| --- | --- | --- |
| `lstm` (`0x6c73746d`) | Four-byte `UInt32`; readable and settable | Current listening mode. Raw `0` is unresolved, `1` is Off, `2` is Noise Cancellation, `3` is Transparency, and `4` is Adaptive. Unknown values fail closed. |
| `lsms` (`0x6c736d73`) | Four-byte read-only `UInt32` | Supported non-Off modes. Bit 0 is Noise Cancellation, bit 1 is Transparency, and bit 2 is Adaptive. Recognized bits remain usable when future unknown bits are also set; unknown bits are never interpreted as modes. |

For a Bluetooth device group with several Core Audio outputs, the HAL provider
targets an output that exposes `lstm`; that control endpoint may differ from the
named sibling used for display.

`lsms` is a bitmask, not a Boolean, and it does not describe whether Off is
enabled for the device. `lstm` may report raw `1` and is translated to the
canonical current mode `off`, but that observation does not add Off to the HAL
available-mode inventory.

The `lstm` getter reads BTAudioHAL's local cached value. Its setter updates that
cache and requests a property notification before dispatching the system
request; a successful `AudioObjectSetPropertyData` result is not an accessory
acknowledgement. A matching immediate or delayed HAL read can therefore be a
cache echo. Delayed polling and property listeners are useful for detecting a
later mismatch or disappearance, but they do not make a matching value
independent evidence of remote application.

## Operational readback

The existing bounded write-result contract is retained. A setter accepted by
the chosen transport followed by a matching same-transport readback is
sufficient operational evidence for `ok`; a nonmatching or unavailable final
read does not verify the operation and follows the existing `no-op` or read
failure contract. If the target was already current, the command remains
idempotent and issues no write.

This evidence means that the chosen macOS control surface accepted the request
and reports the requested state. It is intentionally not described as a
protocol acknowledgement from the AirPods. Cross-transport agreement is not
used as stronger evidence because the two surfaces can have different update
timing and caches.

## Interim Off limitation

The HAL mode inventory excludes Off because `lsms` has no Off bit. The separate
AirPods `AllowListeningModeOff` configuration (AACP configuration `0x13`) is not
exported through a proven ordinary-process HAL getter. Until a trustworthy,
per-target getter is available:

- HAL-backed `list` omits Off.
- The existing available-mode gate rejects HAL-backed `set off`.
- HAL-backed `cycle` cannot target Off, including through an explicit cycle
  set. It can still observe current Off through `lstm` and advance from it to a
  supported non-Off target.
- AV-backed commands continue to expose and use Off when AV advertises it.

Adding raw `1` as an unconditional HAL capability would conflate a current-mode
encoding with the user's configured available-mode set, so that shortcut is
rejected. Discovery of a safe Allow-Off getter is deferred and may revise only
this limitation without changing route-aware selection or transport stickiness.

## Consequences

The CLI gains route-independent listening-mode operations for unselected
devices without taking ownership of the Bluetooth protocol or disturbing the
audio route. The cost is a fail-closed target chooser, two private and
version-sensitive adapters, transport-specific capability differences, and
readback that is operational evidence rather than proof of device-level
acknowledgement.
