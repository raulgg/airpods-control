# Security

`airpods-control` reaches a private Apple audio API by forging one entitlement
inside its own process. The interpose is limited to that entitlement, and the
project distributes source rather than binaries.

## What the interpose does

AVFoundation calls `SecTaskCopyValueForEntitlement` in-process before it
provides the *shared system audio context*, which exposes AirPods listening
modes. It checks for the private
`com.apple.avfoundation.allow-system-wide-context` entitlement.

The library [`Sources/AVBypass/bypass.c`](Sources/AVBypass/bypass.c)
interposes that function. It returns "present" for
`com.apple.avfoundation.allow-system-wide-context` and sends every other query
to the real system implementation unchanged. `DYLD_INSERT_LIBRARIES` loads the
interpose only into the short-lived `airpods-control` helper process. The
library is not installed system-wide and stops running when the process exits.

## What it does not do

- The interpose does not elevate to root or another user. It grants no
  administrator rights, cross-user access, or access to another machine.
- The forged entitlement exists only inside the `airpods-control` process. It
  does not affect another process, user, or session, and it writes nothing to a
  shared location.
- SIP, Gatekeeper, code signing, the sandbox, and library validation remain
  enabled system-wide.
- The tool makes no network connections and accesses no user data or
  configuration files. It loads its executable, the bundled dylib, and Apple
  system frameworks before reading or setting an audio value.

## Supply chain and trust model

The project distributes no prebuilt binaries. The interpose requires an
ad-hoc-signed binary. A notarized binary with the hardened runtime enforces
library validation and blocks the inserted library.

- You clone the repository and compile it locally with your own Command Line
  Tools toolchain.
- The runtime source consists of the entitlement interpose in
  [`Sources/AVBypass/bypass.c`](Sources/AVBypass/bypass.c), the termination
  monitor under [`Sources/SignalMonitor`](Sources/SignalMonitor), and the Swift
  files under [`Sources/AirPodsControl`](Sources/AirPodsControl). Review them
  before building. The executable comes from the source you compile.
- The Homebrew formula downloads a source tarball and runs the same `make`.

To verify the dylib, read `Sources/AVBypass/bypass.c`. It should compare
against one entitlement string and delegate every other case to
`SecTaskCopyValueForEntitlement`. Report any behavior beyond that scope.

## Reporting a vulnerability

Report suspected vulnerabilities through
[GitHub private vulnerability reporting](https://github.com/raulgg/airpods-control/security/advisories/new).
Do not include sensitive vulnerability details in a public issue.

Include the affected macOS version, the `airpods-control` version or commit,
the expected behavior, and enough reproduction detail to investigate. Redact
device names and other personal information from debug output.

If private vulnerability reporting is unavailable, open a public issue without
sensitive details and ask the maintainer to arrange a private channel.
