# Domain context

## Glossary

**Command execution**
: Evaluates a parsed CLI invocation and produces a command outcome. It requests compatible audio devices from the runtime adapter only when the command needs them. Individual resource commands retain first-or-exact selection; aggregate status uses all-or-exact selection. Execution does not parse arguments, render output, or terminate the process.

**Command outcome**
: Everything produced by command execution: plain output, exit code, and the structured JSON payload.

**Status snapshot**
: One read-only, one-pass observation of listening mode and Conversation Awareness for a compatible audio device. Each field is typed as a value, proven unsupported, unresolved, or a read error. Unsupported fields are absent. Unresolved fields and read errors retain the corresponding individual getter's fallback state, and read errors also carry a field-keyed error. A status command outcome contains snapshots in system audio-routing discovery order.

**Listening mode**
: A canonical user-facing AirPods state: `off`, `transparency`, `adaptive`, or `noise-cancellation`. Parsing, ordering, aliases, cycling, and write-result interpretation use this vocabulary. Private AVFoundation values are not listening modes until the Private Audio adapter translates them.

**Compatible audio device**
: The device interface used by command execution. It provides typed status-field observations, supported features, current canonical states, and observed write results without exposing Objective-C selectors or private AVFoundation values. It also provides the device name unless the adapter was asked not to read it.

**Private Audio adapter**
: The production adapter for a compatible audio device. It discovers AVFoundation objects, translates private values, invokes selectors, and observes asynchronous writes through the main run loop.

**Support report document**
: Compatibility data built from a pre-write device snapshot and optional write-test results. It contains one result row per attempted write and omits unresolved values instead of turning them into prose. The terminal and GitHub renderers format the document and choose how to describe absent values; they do not inspect raw device or write-test behavior.

**Device write observation**
: What a compatible audio device reports after a write attempt: whether the underlying setter accepted the request and which final state was observed within the bounded settling window.
