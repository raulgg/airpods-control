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
: A read-only observation of selection, listening mode, and Conversation
  Awareness for one compatible device. One invocation reads the available Core
  Audio inventory and shares the same input and output route observations across
  all records. A field contains a value, proven-unsupported result, unresolved
  result, or read error. Unresolved fields and read errors are displayed as
  `unknown`; read errors also name the affected field. Unsupported feature
  fields are omitted. Records follow the adapter's deduplicated inventory order,
  with output endpoints preferred, but that order is not a stable interface.

**Status device inventory**
: The status-only inventory from public `kAudioHardwarePropertyDevices`. An
  endpoint must be ordinary and nonaggregate, use classic Bluetooth, be alive,
  have an audio stream, and map through
  `IOBluetoothAudioManager.bluetoothDevice:` to an `IOBluetoothDevice`. An
  undocumented HAL property identifies Apple audio hardware. An allowlisted
  Apple or Beats manufacturer is checked only when that property is unavailable.
  Endpoints form one record when their mapped objects compare equal in both
  directions. The output endpoint is preferred. A Core Audio name supplies the
  heading and `--device` target but is not used as identity. Because the
  inventory is independent of the selected defaults, input-only and unselected
  devices remain visible.

**Selected audio device**
: A device whose identity exactly matches the macOS default route for ordinary
  audio input or output at the moment of a status snapshot; membership in a
  composite route does not qualify. Selection excludes the system-alert output
  route and does not imply active playback or recording.
  Avoid: current audio device, active audio device, system output device.

**Audio-device selection observation**
: A selected, not-selected, unresolved, or read-error result for one device and
  one direction. Not-selected requires proof: a composite route, a known
  unrelated transport, or a different mapped classic-Bluetooth device.
  Bluetooth LE, USB, unknown transports, missing properties, and unavailable or
  nil mappings are unresolved. A failed default-route, class, transport, or
  mapper read is a read error. Both unresolved and read-error results display as
  `unknown`, but a read error also names the affected field.

**Endpoint-to-Bluetooth-device mapping**
: The system operation that maps an ordinary classic-Bluetooth Core Audio
  endpoint to an `IOBluetoothDevice`. Inventory uses the result to form records;
  selection maps the ordinary default and compares the two objects in both
  directions. Neither path compares a name, model, Bluetooth/MAC address, Core
  Audio UID, private route ID, or discovery position. Aggregate routes do not
  select their members, and a known unrelated transport proves non-selection.
  Bluetooth LE, USB, unknown transports, missing properties, and unavailable or
  nil mappings remain unresolved. A failed mapper call is a read error.

**Active-output feature enrichment**
: An optional status probe for Conversation Awareness and active listening mode.
  It joins the active AV endpoint to an inventoried device through the stable
  default Core Audio output. The probe asks Core Audio to translate the bounded
  `AVOutputContext.associatedAudioDeviceID`, then compares the result with the
  default output device ID. It samples the private `AVOutputDevice.deviceID`
  before and after to reject an endpoint change. These identifiers are not used
  as Bluetooth identity or selection evidence, and they are never logged,
  rendered, or included in a support report. Conversation Awareness remains
  unresolved without this exact join.

  Listening mode uses the first safe recognized value in this order: active AV,
  one consistent HAL current mode, then the mapped Bluetooth object. An unknown
  active AV value stops the lookup. A future or unknown nonzero HAL value, or
  conflicting HAL values, does the same. The mapped object is tried only when
  HAL is unavailable or neutral, or when a HAL read fails. That failure is
  retained. If the fallback cannot resolve the mode, the field is `unknown` with
  a Listening mode read error.

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
: The production adapter for status. It starts with the public list of available
  Core Audio devices, maps eligible classic-Bluetooth endpoints to
  `IOBluetoothDevice` objects, and deduplicates only when those objects compare
  equal in both directions. A runtime-gated HAL property is the primary Apple
  audio compatibility signal. An allowlisted manufacturer is used only when
  that property is unavailable. HAL current-mode state can populate inactive
  records, with the mapped Bluetooth object as a fallback.

  For each direction, the adapter reads the ordinary Core Audio default and its
  transport, rejects composite routes, rules out known unrelated transports,
  and compares the mapped default with the record. Bluetooth LE, USB, unknown
  transports, missing properties, and unavailable or nil mappings remain
  unresolved. Failed route, class, transport, or mapper reads are read errors.
  Active-output enrichment cannot change selection. The adapter does not expose
  raw HAL values or routing and Bluetooth identifiers to command execution.

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
