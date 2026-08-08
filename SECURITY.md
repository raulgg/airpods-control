# Security

`airpods-control` uses a small interpose library to make one private entitlement
appear present inside its own process. This gives the process access to a
private Apple audio API without granting privileges outside it. The project
distributes source instead of prebuilt binaries.

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
that state. `status` enumerates the public list of currently available Core
Audio device objects. To decide which entries can become records, it reads only
their class, transport, alive/readiness state, stream presence, runtime-gated
system HAL Apple-audio/listening capabilities and state, and human-readable
name. Only when the HAL Apple-audio capability is unavailable does it read the
manufacturer and compare it with an allowlist. It then passes each eligible
classic-Bluetooth object's opaque handle unchanged to macOS's audio-to-Bluetooth
mapper. The HAL capability is the primary admission signal; the manufacturer is
only a fallback.
`status` validates the returned object type and deduplicates records only by
symmetric exact object equality. The name is used for display and exact
`--device` matching; it is never identity or correlation evidence. Raw HAL
property values are not logged or emitted. Only recognized canonical listening
modes are rendered. If HAL evidence contains a future or unrecognized nonzero
current-mode value, or conflicting recognized values from exactly deduplicated
endpoints, Listening mode remains `unknown` and lower-priority inference is
suppressed.

`status` also reads the ordinary default input and output routes and passes an
eligible classic-Bluetooth default through the same mapper for exact selection
comparison. Opaque Core Audio object handles are never parsed, logged, or
emitted. Inventory and selection do not read raw Bluetooth/MAC addresses, Core
Audio UIDs, private route identifiers, serial numbers, or other identifier
properties.

The optional active-output feature-enrichment probe is deliberately separate.
It keeps its bounded `associatedAudioDeviceID`, translated Core Audio device
handle, and private endpoint `deviceID` inside the process; none is logged or
rendered, and none is used as Bluetooth identity or selection evidence. The HAL
can supply listening-mode state for inactive endpoints, with a recognized value
from the mapped system Bluetooth object as fallback, while Conversation
Awareness remains unavailable without the exact active-output enrichment. Debug
output can contain customizable device names and source-build paths, so review
it before sharing.

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

The interpose requires an ad-hoc-signed binary. A notarized binary with the
hardened runtime enforces library validation and blocks the inserted library.

- You clone the repository and compile it locally with your own Command Line
  Tools toolchain.
- The runtime source consists of the entitlement interpose in
  [`Sources/AVBypass/bypass.c`](Sources/AVBypass/bypass.c), the termination
  monitor under [`Sources/SignalMonitor`](Sources/SignalMonitor), and the Swift
  files under [`Sources/AirPodsControl`](Sources/AirPodsControl). Review them
  before building; the executable comes from the source you compile.
- The Homebrew formula downloads a source tarball and runs the same `make`.

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
