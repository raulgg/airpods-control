# Domain context

## Glossary

**Command execution**
: Evaluates a parsed CLI invocation and produces a command outcome. It requests
  compatible audio devices from the runtime adapter only when the command needs
  them. Individual resource commands retain first-or-exact selection; aggregate
  status uses all-or-exact selection. Execution does not parse arguments, render
  output, or terminate the process.

**Command outcome**
: Everything produced by command execution: plain output, exit code, and the
  structured JSON payload.

**Status snapshot**
: One read-only, one-pass observation of audio-device selection,
  listening mode, and Conversation Awareness for a compatible audio device.
  The command first takes one currently available Core Audio device inventory,
  builds compatible status records from eligible endpoints, then every
  device snapshot shares the same direction-specific default-route observations.
  Each field is typed as a value, proven unsupported where applicable,
  unresolved, or a read error; unresolved fields and read errors retain their
  `unknown` fallback state, while read errors also carry a field-keyed error.
  Proven-unsupported feature fields are omitted. A status command outcome
  contains snapshots in deterministic adapter order after exact Bluetooth-
  device deduplication and output-endpoint preference; record order is not a
  stable user-facing contract.

**Status device inventory**
: The status-only inventory built from public `kAudioHardwarePropertyDevices`.
  A candidate must be an ordinary, nonaggregate classic-Bluetooth endpoint that
  is alive and ready, has at least one audio stream, and maps through
  `IOBluetoothAudioManager.bluetoothDevice:` to a canonical
  `IOBluetoothDevice`. A runtime-gated system HAL Apple-audio capability
  property is the primary compatibility admission signal; an allowlisted Apple
  or Beats manufacturer is used only when that property is unavailable. Multiple
  endpoints become one status record only when their canonical objects are
  symmetrically exactly equal; the output endpoint is preferred
  deterministically. A Core Audio name supplies the record heading and
  `--device` target only. It is never device identity or correlation evidence.
  Because this inventory is independent of the selected defaults, an eligible
  device remains visible when selected only for input or for neither direction.

**Selected audio device**
: A device whose identity exactly matches the macOS default route for ordinary
  audio input or output at the moment of a status snapshot; membership in a
  composite route does not qualify. Selection excludes the system-alert output
  route and does not imply active playback or recording.
  Avoid: current audio device, active audio device, system output device.

**Audio-device selection observation**
: A selected, not-selected, unresolved, or read-error status fact for one device
  and one audio direction. Not-selected requires positive evidence of
  non-selection: a composite route, a known unrelated transport, or a mapped
  different classic Bluetooth device. Bluetooth LE, USB, an unknown or
  unsupported transport, an unavailable selector or property, and an
  unavailable or nil endpoint-to-Bluetooth-device mapping are unresolved. An
  actual failure while reading the default route, device class, or transport, or
  while performing an available mapping operation, is a read error. Unresolved
  and read-error observations retain the unknown fallback, while a read error
  also carries a field-keyed error.

**Endpoint-to-Bluetooth-device mapping**
: The system operation used for an ordinary classic-Bluetooth Core Audio
  endpoint. Inventory uses the returned canonical `IOBluetoothDevice` to form
  and deduplicate records. Selection maps the direction's ordinary default
  endpoint through the same operation, then compares symmetric exact object
  equality. Neither path parses or compares a display name, model,
  Bluetooth/MAC address, Core Audio UID, private route ID, or discovery
  position. Aggregate and multi-output endpoints do not qualify; known
  unrelated default transports prove non-selection. Bluetooth LE, USB, unknown
  or unsupported default transports, unavailable selectors or properties, and
  unavailable or nil selection mapping remain unresolved. An error from an
  available selection-mapper operation is a read error rather than an unresolved
  mapping.

**Active-output feature enrichment**
: An optional, status-only probe that joins the active AV output endpoint to the
  exact inventoried Bluetooth device through the stable default Core Audio
  output for Conversation Awareness and active listening-mode enrichment. The
  status adapter separately reads a runtime-gated system HAL current-mode
  property, so an inactive endpoint can still report its listening mode when
  that property is available; a recognized value
  exposed by the mapped system Bluetooth object is a fallback. Exact active
  enrichment takes precedence for mode. The enrichment probe obtains
  `AVOutputContext.associatedAudioDeviceID` as a bounded UID, asks Core Audio to
  translate it to a device ID, and compares only that translated value with the
  default output device ID. The endpoint's private `AVOutputDevice.deviceID` is
  sampled before and after solely to reject a probe whose endpoint changed.
  None of these identifiers is Bluetooth identity or audio-selection evidence;
  none is logged, rendered, or included in a support report. Conversation
  Awareness remains unresolved without an exact active-output enrichment.
  Listening-mode resolution is priority ordered: a recognized exact active AV
  value wins; otherwise one consistent recognized HAL current mode wins. An
  exposed but unrecognized active AV value stops resolution as unresolved. HAL
  evidence containing a future or unrecognized nonzero mode, or conflicting
  recognized modes, likewise remains unresolved and suppresses lower-priority
  inference. Only unavailable or neutral HAL evidence, or a HAL read failure
  while fallback is still safe, permits a recognized value from the exact mapped
  Bluetooth object. A retained HAL read failure becomes a Listening mode read
  error with the `unknown` fallback when that fallback does not resolve.

**Listening mode**
: A canonical user-facing AirPods state: `off`, `transparency`, `adaptive`, or
  `noise-cancellation`. Parsing, ordering, aliases, cycling, and write-result
  interpretation use this vocabulary. Raw private AVFoundation or system HAL
  values are not listening modes until their adapter translates them.

**Compatible audio device**
: The device interface used by command execution. It provides typed status-field
  observations, supported features, current canonical states, and observed write
  results without exposing Objective-C selectors or private AVFoundation values.
  It also provides the device name unless the adapter was asked not to read it.

**Private Audio adapter**
: The production adapter used by individual resource commands and compatibility
  reporting. It discovers AVFoundation objects, translates private values,
  invokes selectors, and observes asynchronous writes through the main run
  loop.

**Status Core Audio adapter**
: The production status adapter. It builds records from eligible entries in the
  public currently available Core Audio device list, maps classic-Bluetooth
  endpoints to canonical `IOBluetoothDevice` objects, and deduplicates only by
  symmetric exact object equality. A runtime-gated system HAL Apple-audio
  capability is its primary compatibility signal, with an allowlisted
  manufacturer fallback only when that property is unavailable; HAL
  listening-mode state can populate inactive records, with recognized
  mapped-system-object values as a fallback. Separately for input
  and output, it reads the ordinary Core Audio default and its transport,
  rejects composite routes, rules out known unrelated transports, and performs
  the same mapping before an exact identity comparison. Bluetooth LE, USB,
  unknown or unsupported default transports, unavailable selectors or
  properties, and unavailable or nil mappings remain unresolved. Failed route,
  class, or transport reads and failed available-mapper operations are read
  errors. It can use exact active-output feature enrichment without changing
  selection. The adapter does not expose raw HAL values, routing identifiers,
  or Bluetooth identifiers to command execution.

**Support report document**
: Compatibility data built from a pre-write device snapshot and optional
  write-test results. It contains one result row per attempted write and omits
  unresolved values instead of turning them into prose. The terminal and GitHub
  renderers format the document and choose how to describe absent values; they
  do not inspect raw device or write-test behavior.

**Device write observation**
: What a compatible audio device reports after a write attempt: whether the
  underlying setter accepted the request and which final state was observed
  within the bounded settling window.
