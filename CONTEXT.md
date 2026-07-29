# Domain context

## Glossary

**Command execution**
: Evaluates a parsed CLI invocation, requests a compatible audio device from
  the runtime adapter only when the command needs one, and produces a command
  outcome. It does not parse arguments, render output, or terminate the
  process.

**Command outcome**
: Everything produced by command execution: plain output, exit code, and the
  structured JSON payload.

**Listening mode**
: A canonical user-facing AirPods state: `off`, `transparency`, `adaptive`, or
  `noise-cancellation`. Parsing, ordering, aliases, cycling, and write-result
  interpretation use this vocabulary. Private AVFoundation values are not
  listening modes until the Private Audio adapter translates them.

**Compatible audio device**
: The device interface that command execution uses. It provides the device
  name, supported features, current canonical states, and observed write
  results without exposing Objective-C selectors or private AVFoundation
  values.

**Private Audio adapter**
: The production adapter for a compatible audio device. It discovers
  AVFoundation objects, translates private values, invokes selectors, and
  observes asynchronous writes through the main run loop.

**Support report document**
: Compatibility data built from a pre-write device snapshot and optional
  write-test results. It carries one result row per attempted write and leaves
  unresolved values absent rather than phrased. The terminal and GitHub
  renderers format this document and choose their own wording for what is
  absent; they do not inspect raw device or write-test behavior.

**Device write observation**
: What a compatible audio device reports after a write attempt: whether the
  underlying setter accepted the request and which final state was observed
  within the bounded settling window.
