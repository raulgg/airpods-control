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

Operational commands read the selected device's customizable name and audio
state, and setters can change that state. `support-report` uses a separate
name-free discovery path and never reads the customizable device name. Its
privacy rules are documented in the
[CLI reference](docs/cli.md#contributor-compatibility-report).

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
