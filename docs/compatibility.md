# Device compatibility

Support can vary by device, firmware, and macOS version. This project uses a
private Apple API that Apple does not document, so a product name alone cannot
tell us whether every command will work.

Use the matrix below to track compatibility per device and capability.

## Status

- **Verified**: tested on real hardware.
- **Partially verified**: some capabilities are verified, but broader device
  coverage is still pending.
- **Pending**: waiting for a hardware test.
- **Exploratory**: reports are welcome, but support has not been established.
- **Unavailable**: macOS reports that the device does not expose the capability.

## Capability matrix

| Capability | AirPods Pro 3 | AirPods Pro 2 (Lightning) | Other AirPods candidates | Beats candidates |
| --- | --- | --- | --- | --- |
| Device discovery | Verified | Pending | Pending | Exploratory |
| One-earbud discovery and control | Verified | Pending | Pending | Exploratory |
| `status` | Pending | Pending | Pending | Exploratory |
| Left/right ear placement | Pending | Pending | Pending | Exploratory |
| Selected audio output observation | Pending | Pending | Pending | Exploratory |
| Selected audio input observation | Pending | Pending | Pending | Exploratory |
| `listening-mode get` | Verified | Verified | Pending | Exploratory |
| `listening-mode list` | Verified | Verified | Pending | Exploratory |
| `listening-mode set` | Verified | Verified | Pending | Exploratory |
| `listening-mode cycle` | Verified | Pending | Pending | Exploratory |
| `conversation-awareness get` | Verified | Verified | Pending | Exploratory |
| `conversation-awareness set` | Verified | Verified | Pending | Exploratory |
| `support-report` metadata | Pending | Verified | Pending | Exploratory |

The matrix tracks individual resource commands, the aggregate `status` command,
selected input/output observations, one-earbud behavior, and `support-report`
metadata separately because they exercise different private macOS paths.
Selection verification requires all four output-only, input-only, both, and
neither cases in the
[hardware-testing guide](hardware-testing.md#selected-audio-inputoutput-release-check).

`status` starts with the public list of available Core Audio devices, not the
selected output. An endpoint must be ordinary and nonaggregate, use classic
Bluetooth, be alive and ready, have an audio stream, and map to an
`IOBluetoothDevice`. A runtime-gated HAL property is the primary Apple audio
compatibility signal. An allowlisted Apple or Beats manufacturer is used only
when that property is unavailable.
Input and output endpoints form one record when their mapped objects compare
equal in both directions, with the output endpoint preferred. The Core Audio
name is used only for display and `--device` matching.

Selection is checked separately for input and output. A classic-Bluetooth
default passes through the same mapper and must match the record's mapped
object. Aggregate routes and known unrelated transports produce `no`. Bluetooth
LE, USB, unknown transports, missing properties, and unavailable mappings
produce `unknown`. A failed route, class, transport, or mapper read is a read
error. Core Audio handles pass unchanged to macOS and never appear in logs or
output. Inventory and selection do not read Bluetooth addresses, Core Audio
UIDs, or private route identifiers.

Runtime-gated HAL properties can report listening mode for inactive endpoints.
The active AV value has priority, followed by one consistent HAL value from the
mapped endpoints. An unknown active AV value stops the lookup. A future or
unknown nonzero HAL value, or conflicting HAL values, does the same. The mapped
Bluetooth object is tried only when HAL is unavailable or neutral, or when a
HAL read fails. That failure is retained. If the fallback cannot resolve the
mode, the field is `unknown` with a read error.

The optional active-output probe asks Core Audio to translate the bounded AV
context `associatedAudioDeviceID` and compares the result with the stable
default output. The default's mapped Bluetooth object must also match the
record. The probe samples the private endpoint `deviceID` before and after only
to reject an endpoint change. Conversation Awareness is `unknown` without this
join. These identifiers and raw HAL values are never logged or reported, and
they do not determine Bluetooth identity or selection.

`support-report` remains a separate private-output compatibility path. It does
not enumerate the Core Audio status inventory, inspect default routes, call the
selection mapper, or run active-output enrichment.

The status adapter can read left and right ear placement from three
runtime-gated HAL properties (`iesb`, `pris`, and `iede`) when macOS exposes
them. It reports `in-ear`, `out-of-ear`, or `in-case` without changing settings.
Missing or disabled properties are unsupported; unknown or conflicting evidence
is unresolved. This implementation does not use BLE advertisements as a
fallback, because a scan cannot safely join a rotating advertisement to the
already-resolved `IOBluetoothDevice` without heuristic identity matching.

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
| AirPods Pro 2 (Lightning) | A2931, A2699, A2698 | 0x2014 | ANC, Transparency, Adaptive Audio, Conversation Awareness | [Partially verified](https://github.com/raulgg/airpods-control/issues/34) |
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
establish support. Write tests probe listening modes from noise cancellation
toward Off so a disabled Off mode that falls back to Transparency cannot make
the Transparency probe already-current. An
`inconclusive (already in this state; no transition demonstrated)` verdict
means the device already reported the target before the write, so the matching
readback does not prove that the setter worked.

If the report says the model is not recognized by this CLI version, the model
identifier line still carries the decoded Bluetooth product ID whenever the
identifier is in the `BTHeadphones` form; otherwise it carries only the
identifier itself. Either way, include the product name in your issue so we can
extend the mapping.
