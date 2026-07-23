# Security

`airpods-control` reaches a private Apple audio API by forging one entitlement inside its own process. That is an unusual thing to run, so this document states plainly what the mechanism does, what it does not do, and how the build-from-source model protects you.

## What the interpose does

To acquire the *shared system audio context* (the object that exposes AirPods listening modes), AVFoundation checks in-process for a private entitlement, `com.apple.avfoundation.allow-system-wide-context`, by calling `SecTaskCopyValueForEntitlement`.

The library [`native/bypass.c`](native/bypass.c) interposes that one function. When the entitlement being queried is `com.apple.avfoundation.allow-system-wide-context`, it returns "present." For **every other** entitlement, it calls straight through to the real system implementation and returns whatever that returns. The interpose is loaded only into the short-lived `airpods-control` helper process via `DYLD_INSERT_LIBRARIES`; it is not installed system-wide and does not persist after the process exits.

## What it does not do

- **Not a privilege escalation.** The forged entitlement is an *audio* gate, not a security boundary. You already own your Mac's audio hardware and could set these modes by pressing an AirPod stem. The interpose only lets a third-party tool reach a first-party API — it grants no capability over the machine that you do not already have as its user, and it gives no one else any access.
- **No risk to other users or processes.** The change lives entirely inside the `airpods-control` process for its lifetime. No other process, user, or session is affected. Nothing is written to a shared location.
- **Disables no protections.** It does not turn off System Integrity Protection (SIP), Gatekeeper, code signing, the sandbox, or library validation anywhere on the system. It changes one function's answer inside one process.
- **No network, no files.** The tool makes no network connections and reads or writes no files. It reads/sets an audio setting and exits.

## Supply chain and trust model

**No prebuilt binaries are distributed.** There is nothing to download and trust blindly. The interpose technique requires an ad-hoc-signed binary, which cannot be notarized (a hardened runtime enforces library validation and would block the inserted library), so shipping a signed download is not even possible. Instead:

- You clone the repository and compile it locally with your own Command Line Tools toolchain.
- The complete runtime source is [`native/bypass.c`](native/bypass.c) — around 40 lines of C — plus [`native/main.swift`](native/main.swift), [`native/CLI.swift`](native/CLI.swift), [`native/CommandExecution.swift`](native/CommandExecution.swift), and [`native/PrivateAudio.swift`](native/PrivateAudio.swift). **Read them before you build.** The whole trust surface is small enough to audit in a few minutes, and what runs is what you compiled.
- The Homebrew formula also builds from source; it downloads a source tarball, not a binary, and runs the same `make`.

If you want to verify the dylib does only what is claimed, read `native/bypass.c`: it should compare against exactly the one entitlement string and delegate every other case to `SecTaskCopyValueForEntitlement`. Anything beyond that would be a red flag worth reporting.

## Reporting an issue

If you find a security problem — for example, the interpose affecting an entitlement other than the documented one, or any unexpected file/network activity — please open an issue at https://github.com/raulg/airpods-control-cli/issues with steps to reproduce. For anything you would rather not disclose publicly, note that in the issue and a private contact can be arranged.
