# Domain context

## Glossary

**Command execution**
: Evaluates a parsed CLI invocation, requests a compatible audio device from
  the runtime adapter only when the command needs one, and produces a command
  outcome. It does not parse arguments, render output, or terminate the
  process.

**Command outcome**
: The complete result of command execution: plain output, exit code, and the
  structured JSON payload.
