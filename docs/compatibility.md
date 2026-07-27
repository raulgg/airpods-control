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
| `listening-mode get` | Verified | Pending | Exploratory |
| `listening-mode list` | Verified | Pending | Exploratory |
| `listening-mode set` | Verified | Pending | Exploratory |
| `listening-mode cycle` | Verified | Pending | Exploratory |
| `conversation-awareness get` | Verified | Pending | Exploratory |
| `conversation-awareness set` | Verified | Pending | Exploratory |
| `support-report` metadata | Pending | Pending | Exploratory |

We have tested the existing CLI commands on AirPods Pro 3. We have not yet run
`support-report` with connected hardware.

## Candidates pending verification

These devices are worth testing because Apple or Beats documents listening
modes similar to those used by the CLI. We do not yet know whether macOS
exposes those controls through the same private API.

### AirPods

AirPods come first on the test list. Apple gives some hardware variants
different model identifiers, so we track them separately in case macOS exposes
them differently.

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
[AirPods identification guide](https://support.apple.com/en-in/109525).
Its documentation also lists the models with
[ANC and Transparency](https://support.apple.com/en-us/108918), along with the
models that add
[Adaptive Audio and Conversation Awareness](https://support.apple.com/en-ie/104979).
We have left out AirPods 1 through 3 and AirPods 4 without ANC because Apple
does not document listening modes or Conversation Awareness for them.

The Bluetooth product ID connects a `support-report` to a row in this table.
macOS reports the model as `BTHeadphones<vendor>,<product>` with both numbers
in decimal; `76,8231` is vendor `0x004C` (Apple) and product `0x2027` (AirPods
Pro 3). The CLI decodes this and prints the model name in the report. The
product IDs come from community projects that speak the Apple Accessory
Protocol, primarily
[MagicPodsCore](https://github.com/steam3d/MagicPodsCore), cross-checked
against AirPodsDesktop, librepods, and The Apple Wiki. Apple does not publish
them, so a report from real hardware is also a check of this mapping.

### Beats

Every Beats model in this list is exploratory. We have not tested any of them
with the CLI, and Beats does not document Conversation Awareness for them.
The identifiers are the public A-series hardware model numbers. We still need
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

The first round of testing does not include models without documented listening
modes, such as AirPods 1 through 3, AirPods 4 without ANC, Beats Solo 4, Beats
Solo Buds, and Powerbeats Pro 1. If macOS unexpectedly exposes compatible
controls for one of them, its report is still useful.

The CLI currently selects only devices for which macOS reports available
listening modes and a current mode. It checks Conversation Awareness after
discovery but does not require it. Some candidates may expose only part of the
interface. The CLI reports missing data as unavailable and does not infer it.

## Contributing a result

Connect exactly one compatible AirPods or Beats device as a macOS output
device, then run:

```sh
airpods-control support-report
```

The report deliberately does not read customizable device names or accept
`--device`. It therefore requires exactly one compatible output device and
stops before prompting or writing when selection is ambiguous.

Read the report before opening the GitHub issue. A read-only report uses
passive reads, so it can report setter exposure but cannot verify a command
that changes a setting. With consent, the captured plan tests the advertised
listening-mode targets recognized by this CLI and toggles Conversation
Awareness away from the captured initial state and back. The plan does not
change after it is disclosed.

A setting is skipped without writing if its initial state cannot be read and
restored safely, or if that state changes while consent is pending.
Listening-mode tests also require the captured initial mode to be advertised
and at least one alternate recognized advertised mode to test. After normal
completion or a setter error, the command makes a best-effort restoration
attempt. A failed restoration is reported locally and exits `3`. An externally
delivered SIGINT or SIGTERM caught during the tests attempts restoration first,
then exits `130` or `143`, respectively.

Mark a write capability as **Verified** only from an individual `verified`
verdict, not a `no-op` or `setter error`, or after testing the command manually
on real hardware and recording the device and macOS version. Named
listening-mode verdicts and restoration status stay in terminal output; the
prefilled issue records only that those tests ran, so the captured initial mode
cannot be inferred from result order or a missing row.

If the report says the model is not recognized by this CLI version, the model
identifier line still carries the decoded Bluetooth product ID whenever the
identifier is in the `BTHeadphones` form; otherwise it carries only the
identifier itself. Either way, include the product name in your issue so we
can extend the mapping.
