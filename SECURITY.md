# Security

`airpods-control` uses a small interpose library to make one private entitlement
appear present inside its own process. This gives the process access to a
private Apple audio API without granting privileges outside it. The project
installs by compiling source on the user's Mac, either through Homebrew or
`make install`.

## What the interpose does

AVFoundation calls `SecTaskCopyValueForEntitlement` in-process before it
provides the *shared system audio context*, which exposes AirPods listening
modes. It checks for the private
`com.apple.avfoundation.allow-system-wide-context` entitlement.

The library [`Sources/AVBypass/bypass.c`](Sources/AVBypass/bypass.c) interposes
that function. It returns "present" for
`com.apple.avfoundation.allow-system-wide-context` and sends every other query
to the real system implementation unchanged.

`DYLD_INSERT_LIBRARIES` loads the interpose only into the short-lived
`airpods-control` process. A local build stores the library beside the
executable in the build directory; `make install` copies both files under
`PREFIX/libexec/airpods-control`. The installed library is not injected into
other processes, and its code stops running when `airpods-control` exits.

After the re-exec, the executable's
[`Sources/BypassProbe/bypass_probe.c`](Sources/BypassProbe/bypass_probe.c) asks
Security for the same entitlement and reports whether interposition is active.
This confirms that one query was intercepted; it does not establish that a
shared system audio context or compatible device is available.

## What it does not do

- The interpose does not elevate to root or another user. It grants no
  administrator rights, cross-user access, or access to another machine.
- The entitlement result exists only inside the `airpods-control` process. It
  does not affect another process, user, or session, and the interpose does not
  write to a shared location.
- SIP, Gatekeeper, code signing, the sandbox, and library validation remain
  enabled system-wide.

## Data and network behavior

Individual listening-mode and Conversation Awareness commands read the chosen AV
output device's customizable name and requested audio state; setters can change
that state. `status` starts with the public list of available Core Audio
devices. For each candidate, it checks that the endpoint is ordinary and
nonaggregate, then reads the transport, alive and ready state, stream presence,
name, and runtime-gated HAL Apple-audio, listening-mode, and ear-placement
properties. It checks the manufacturer against an allowlist only when the HAL
Apple-audio property is unavailable. Eligible classic-Bluetooth handles pass
unchanged to macOS's audio-to-Bluetooth mapper.

`status` checks the mapped object's type and combines endpoints only when their
objects compare equal in both directions. A name is used for display and exact
`--device` matching, never as identity. Raw HAL values are not logged or
printed. A future or unknown nonzero HAL mode, or conflicting HAL modes, leaves
Listening mode `unknown` and prevents a lower-priority fallback.

`status` also reads the ordinary default input and output routes and passes an
eligible classic-Bluetooth default through the same mapper for exact selection
comparison. Opaque Core Audio object handles are never parsed, logged, or
emitted. Inventory and selection do not read raw Bluetooth/MAC addresses,
private route identifiers, serial numbers, or other private identifier
properties.

The optional BLE placement fallback reads public CoreBluetooth identifiers and
public Core Audio model and device UIDs only after `bluetooth setup` enables the
integration and macOS has granted Bluetooth permission. It stores the public
CoreBluetooth identifier and salted SHA-256 digests of Core Audio UIDs in an
owner-only Application Support file. It never reads or stores IRKs, pairing
keys, Bluetooth addresses, AAP data, raw advertisements, RSSI, battery, or
status history. These identifiers, digests, and salts never appear in command
output or debug logs. A regular `status` command never prompts for permission.

The optional active-output feature probe is separate from selection. Its bounded
`associatedAudioDeviceID`, translated Core Audio handle, and private endpoint
`deviceID` stay inside the process. They are not logged, rendered, or used as
Bluetooth identity. The HAL can supply listening mode for an inactive endpoint,
with the mapped Bluetooth object as a fallback. Conversation Awareness requires
the exact active-output join. Debug output can contain customizable device names
and source-build paths, so review it before sharing.

`support-report` uses a separate name-free discovery path. It does not read the
customizable device name, enumerate the Core Audio status inventory, query the
selected input or output routes, call the selection mapper, or run the optional
enrichment probe. Its privacy rules are documented in the [CLI
reference](docs/cli.md#contributor-compatibility-report).

The CLI itself makes no network requests, sends no telemetry, and does not
submit reports. If you accept the prompt to open a compatibility issue, it asks
macOS to open a prefilled GitHub form in your default browser. You still review
and submit the issue yourself.

## Supply chain and trust model

Both supported install paths compile on your Mac with Command Line Tools and
ad-hoc-sign the executable and companion dylib. Homebrew is the recommended
path: the formula downloads the tagged source archive, pins its SHA-256, and
builds the native architecture. A local `make install` is the same compile
from a clone or tagged tree. The optional source script compiles a tagged git
checkout, a weaker pin than Homebrew's SHA-256.

This project does not publish compiled binaries. GitHub Releases are the
source tag and notes. Trusting an install means reviewing the source,
especially the interpose, and trusting the compiler on your machine.

- The runtime source consists of the entitlement interpose in
  [`Sources/AVBypass/bypass.c`](Sources/AVBypass/bypass.c), the termination
  monitor under [`Sources/SignalMonitor`](Sources/SignalMonitor), the direct
  entitlement probe under [`Sources/BypassProbe`](Sources/BypassProbe), and the
  Swift files under [`Sources/AirPodsControl`](Sources/AirPodsControl). Review
  them before building.
- The dylib still loads only into `airpods-control`. Ad-hoc signing does not
  expand its runtime scope or grant the forged private entitlement to other
  processes.

To verify the dylib, read `Sources/AVBypass/bypass.c`. It should compare against
one entitlement string and delegate every other case to
`SecTaskCopyValueForEntitlement`. Report any behavior beyond that scope.

## Reporting a vulnerability

Report suspected vulnerabilities through
[GitHub private vulnerability reporting](https://github.com/raulgg/airpods-control/security/advisories/new).
Do not include sensitive vulnerability details in a public issue.

Include the affected macOS version, the `airpods-control` version or commit, the
expected behavior, and enough reproduction detail to investigate. Redact device
names and other personal information from debug output.

If private vulnerability reporting is unavailable, open a public issue without
sensitive details and ask the maintainer to arrange a private channel.
