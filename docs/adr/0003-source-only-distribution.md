---
status: accepted
---

# Distribute source only

This CLI uses private Apple audio APIs and an in-process entitlement interpose.
Shipping a Developer ID signed, notarized binary would put that under the Apple
Developer Program agreement. Attaching an ad-hoc zip would teach users to
bypass Gatekeeper. Homebrew and local `make install` already compile on the
user's Mac.

No GitHub release has ever attached a compiled binary (`v0.3.0` included).
There is nothing to migrate or deprecate. The binary-release and experimental
bundle workflows are unused machinery and are removed.

Homebrew is the recommended install. GitHub Releases stay a source tag plus
notes.