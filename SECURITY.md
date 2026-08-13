# Security

`airpods-control` uses a small interpose library to make one private entitlement
appear present inside its own process. This gives the process access to a
private Apple audio API without granting privileges outside it. The project
primarily distributes source and also publishes a short-lived experimental CI
bundle for testing.

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
name, and runtime-gated HAL Apple-audio and listening-mode properties. It checks
the manufacturer against an allowlist only when the HAL Apple-audio property is
unavailable. Eligible classic-Bluetooth handles pass unchanged to macOS's
audio-to-Bluetooth mapper.

`status` checks the mapped object's type and combines endpoints only when their
objects compare equal in both directions. A name is used for display and exact
`--device` matching, never as identity. Raw HAL values are not logged or
printed. A future or unknown nonzero HAL mode, or conflicting HAL modes, leaves
Listening mode `unknown` and prevents a lower-priority fallback.

`status` also reads the ordinary default input and output routes and passes an
eligible classic-Bluetooth default through the same mapper for exact selection
comparison. Opaque Core Audio object handles are never parsed, logged, or
emitted. Inventory and selection do not read raw Bluetooth/MAC addresses, Core
Audio UIDs, private route identifiers, serial numbers, or other identifier
properties.

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

The source and experimental build paths use ad-hoc signatures. A normal
notarized hardened-runtime binary enforces library validation and blocks the
inserted library.

- A source install compiles locally with your own Command Line Tools toolchain.
- The Homebrew formula downloads a source tarball and runs the same `make`.
- The experimental workflow publishes a seven-day universal archive from each
  native GitHub-hosted runner. It is not Developer ID signed, notarized, or a
  release asset. Trusting it means trusting the identified repository workflow,
  checked-out commit, runner, and toolchain rather than compiling the reviewed
  source yourself. `BUILD.txt` records that identity; `SHA256SUMS` checks
  integrity within the artifact but does not authenticate its publisher.
- The runtime source consists of the entitlement interpose in
  [`Sources/AVBypass/bypass.c`](Sources/AVBypass/bypass.c), the termination
  monitor under [`Sources/SignalMonitor`](Sources/SignalMonitor), the direct
  entitlement probe under [`Sources/BypassProbe`](Sources/BypassProbe), and the
  Swift files under [`Sources/AirPodsControl`](Sources/AirPodsControl). Review
  them before building or trusting a corresponding workflow artifact.

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
