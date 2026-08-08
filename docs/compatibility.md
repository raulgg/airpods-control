# Device compatibility

Support can vary by device, firmware, and macOS version. This project uses a
private Apple API that Apple does not document, so a product name alone cannot
tell us whether every command will work.

So far, we have only tested the CLI on AirPods Pro 3.

## Status

- **Verified**: tested on real hardware.
- **Pending**: waiting for a hardware test.
- **Exploratory**: reports are welcome, but support has not been established.
- **Unavailable**: macOS reports that the device does not expose the capability.

## Capability matrix

| Capability | AirPods Pro 3 | Other AirPods candidates | Beats candidates |
| --- | --- | --- | --- |
| Device discovery | Verified | Pending | Exploratory |
| One-earbud discovery and control | Verified | Pending | Exploratory |
| `status` | Pending | Pending | Exploratory |
| Selected audio output observation | Pending | Pending | Exploratory |
| Selected audio input observation | Pending | Pending | Exploratory |
| `listening-mode get` | Verified | Pending | Exploratory |
| `listening-mode list` | Verified | Pending | Exploratory |
| `listening-mode set` | Verified | Pending | Exploratory |
| `listening-mode cycle` | Verified | Pending | Exploratory |
| `conversation-awareness get` | Verified | Pending | Exploratory |
| `conversation-awareness set` | Verified | Pending | Exploratory |
| `support-report` metadata | Pending | Pending | Exploratory |

We have tested the individual resource commands on AirPods Pro 3. The aggregate
`status` command, its selected input/output observations, and `support-report`
still require connected-hardware checks. Selection verification requires all
four output-only, input-only, both, and neither cases in the
[hardware-testing guide](hardware-testing.md#selected-audio-inputoutput-release-check).

`status` derives its records from the public list of currently available Core
Audio devices, independently of the selected output. It accepts only ordinary,
nonaggregate classic-Bluetooth endpoints that are alive and ready, have audio
streams, and map through the system audio-to-Bluetooth mapper to an expected
canonical `IOBluetoothDevice`. A runtime-gated system HAL Apple-audio capability
is the primary compatibility signal; an allowlisted Apple or Beats manufacturer
is used only when that property is unavailable. Separate input and output
endpoints become one record only when their canonical objects compare exactly
equal in both directions; the output endpoint is preferred deterministically.
The Core Audio name is only a display and `--device` target attribute, never
identity or correlation evidence.

Selection classifies each direction's ordinary default Core Audio endpoint,
passes only a classic-Bluetooth default through the same mapper, and requires an
exact canonical-object match. Aggregate and multi-output defaults do not select
their members, and known unrelated transports prove non-selection. Bluetooth
LE, USB, unknown or unsupported transports, unavailable selectors or
properties, and unavailable or nil mappings produce `unknown`. An actual
failure reading the default route, device class, or transport, or performing an
available mapper operation, is a read error. Inventory and selection do not read
or correlate raw Bluetooth/MAC addresses, Core Audio UIDs, or private route
identifiers; opaque Core Audio object handles are passed unchanged to macOS and
never logged or emitted.

Runtime-gated system HAL properties can supply current listening-mode state for
inactive endpoints. Mode resolution accepts the highest-
priority safe recognized value: exact active AV first, then one consistent mode
from the exactly deduplicated HAL endpoints. If active AV exposes an
unrecognized value, or HAL evidence contains a future or unrecognized nonzero
value or conflicting recognized modes, the field remains `unknown` and the
mapped-object fallback is suppressed. Only unavailable or neutral HAL evidence,
or a HAL read failure, permits a recognized value from the mapped system
Bluetooth object. If that retained failure has no resolving fallback, the mode
is `unknown` with a field-specific read error.

The optional active-output probe may translate the AV context's bounded
`associatedAudioDeviceID` through Core Audio and compare the resulting device
handle with the stable default output handle. It samples the private endpoint
`deviceID` before and after only to prove stability, and the default endpoint's
mapped Bluetooth object must exactly equal the record. Conversation Awareness
remains `unknown` without that exact join. None of these identifiers or raw HAL
values participates in Bluetooth identity or selection, and none is logged or
reported.

`support-report` remains a separate private-output compatibility path. It does
not enumerate the Core Audio status inventory, inspect default routes, call the
selection mapper, or run active-output enrichment.

## Candidates pending verification

Apple or Beats documents listening modes for these devices, but we do not know
whether macOS exposes the controls through the same private API.

### AirPods

Apple gives some AirPods hardware variants different model identifiers. The
table tracks them separately in case macOS exposes them differently.

| Model | Model identifiers | Bluetooth product ID | Documented capabilities | Status |
| --- | --- | --- | --- | --- |
| AirPods 4 (ANC) | A3056, A3055, A3057 | 0x201B | ANC, Transparency, Adaptive Audio, Conversation Awareness | Pending |
| AirPods Pro 1 | A2084, A2083 | 0x200E | ANC, Transparency | Pending |
| AirPods Pro 2 (Lightning) | A2931, A2699, A2698 | 0x2014 | ANC, Transparency, Adaptive Audio, Conversation Awareness | Pending |
| AirPods Pro 2 (USB-C) | A3047, A3048, A3049 | 0x2024 | ANC, Transparency, Adaptive Audio, Conversation Awareness | Pending |
| AirPods Pro 3 | A3063, A3064, A3065 | 0x2027 | ANC, Transparency, Adaptive Audio, Conversation Awareness | Verified baseline |
| AirPods Max 1 (Lightning) | A2096 | 0x200A | ANC, Transparency | Pending |
| AirPods Max 1 (USB-C) | A3184 | 0x201F | ANC, Transparency | Pending |
| AirPods Max 2 | A3454 | 0x202D | ANC, Transparency, Adaptive Audio, Conversation Awareness | Pending |

The model identifiers in the table come from Apple's
[AirPods identification guide](https://support.apple.com/en-in/109525). Its
documentation also lists the models with
[ANC and Transparency](https://support.apple.com/en-us/108918), along with the
models that add
[Adaptive Audio and Conversation Awareness](https://support.apple.com/en-ie/104979).
We have left out AirPods 1 through 3 and AirPods 4 without ANC because Apple
does not document listening modes or Conversation Awareness for them.

The Bluetooth product ID connects a `support-report` to a row in this table.
macOS reports the model as `BTHeadphones<vendor>,<product>` with both numbers in
decimal; `76,8231` is vendor `0x004C` (Apple) and product `0x2027` (AirPods Pro
3). The CLI decodes this and prints the model name in the report. The product
IDs come from community projects that speak the Apple Accessory Protocol,
primarily [MagicPodsCore](https://github.com/steam3d/MagicPodsCore),
cross-checked against AirPodsDesktop, librepods, and The Apple Wiki. Apple does
not publish them, so a report from real hardware is also a check of this
mapping.

### Beats

Every Beats model in this list is exploratory. We have not tested any of them
with the CLI, and Beats does not document Conversation Awareness for them. The
identifiers are the public A-series hardware model numbers. We still need
real-device reports to see what the private macOS interface returns.

| Model | Model identifiers | Bluetooth product ID | Why it is a candidate | Status |
| --- | --- | --- | --- | --- |
| Powerbeats Pro 2 | A3157, A3158, A3160 | 0x201D | Apple H2 chip; ANC and Transparency | Exploratory |
| Powerbeats Fit | A3476, A3477, A3479 | 0x202F | Apple H1 chip; ANC and Transparency | Exploratory |
| Beats Fit Pro | A2576, A2577, A2578 | 0x2012 | ANC and Transparency, controlled through iOS listening modes | Exploratory |
| Beats Solo Pro | A1881 | 0x200C | Noise Cancellation and Transparency listening modes | Exploratory |
| Beats Studio Pro | A2924 | 0x2017 | ANC and Transparency listening modes | Exploratory |
| Beats Studio Buds + | A2870, A2871, A2872 | 0x2016 | ANC and Transparency, controlled through iOS listening modes | Exploratory |
| Beats Studio Buds | A2512, A2513, A2514 | 0x2011 | ANC and Transparency listening modes | Exploratory |
| Beats Studio3 Wireless | A1914 | 0x2009 | Pure ANC can be switched on and off, but Transparency is not documented | Exploratory |

The table omits models without documented listening modes, such as AirPods 1
through 3, AirPods 4 without ANC, Beats Solo 4, Beats Solo Buds, and Powerbeats
Pro 1. A report is still useful if macOS exposes compatible controls for one of
them.

Runtime support comes from the capabilities macOS reports for the connected
device, not from its presence in these tables. Some devices expose only part of
the interface. The CLI reports missing or unresolved capabilities without
guessing a state; see the [CLI reference](cli.md) for each command's output
contract.

## Contributing a result

Connect exactly one compatible AirPods or Beats device as a macOS output device,
then run:

```sh
airpods-control support-report
```

Read the report before opening the GitHub issue form. Add only safe optional
notes and complete the privacy confirmation before submitting. Write tests run
only with explicit consent and can cause audible mode switches or change noise
control while the device is worn, so do not run them during a call. The
[CLI reference](cli.md#consented-write-tests) documents the consent flow, skip
rules, restoration, and exit codes.

A read-only report can show that macOS exposes a setter, but it cannot verify a
command that changes a setting. Only a consented run produces write-test
verdicts.

Mark a write capability as **Verified** only from an individual `verified`
verdict or from a manual test on real hardware that records the device and macOS
version. An `inconclusive`, `no-op`, or `setter error` verdict does not
establish support. In particular,
`inconclusive (already in this state; no transition demonstrated)` means the
device already reported the target before the write, so the matching readback
does not prove that the setter worked.

If the report says the model is not recognized by this CLI version, the model
identifier line still carries the decoded Bluetooth product ID whenever the
identifier is in the `BTHeadphones` form; otherwise it carries only the
identifier itself. Either way, include the product name in your issue so we can
extend the mapping.
