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
: A read-only observation of selection, listening mode, Conversation Awareness,
  and left/right ear placement for one compatible device. One invocation reads
  the available Core Audio inventory and shares the same input and output route
  observations across all records. A field contains a value,
  proven-unsupported result, unresolved result, or read error. Unresolved fields
  and read errors are displayed as `unknown`; read errors also name the affected
  field. Unsupported feature fields are omitted. Records follow the adapter's
  deduplicated inventory order, with output endpoints preferred, but that order
  is not a stable interface.

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
  raw HAL values or routing and Bluetooth identifiers to command execution. When
  macOS exposes the runtime-gated `iesb`, `pris`, and `iede` properties, it also
  captures a typed left/right ear-placement pair during status inventory. The
  placement observation is one-pass and read-only; missing or disabled
  properties are unsupported, while unknown or conflicting evidence remains
  unresolved. BLE advertisements are not used as an identity fallback.

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

## Persistence-cache discovery

**Allow Off availability observation**
: A successful observation that a device's active AV control surface did or did
  not advertise Off at a particular time. It is evidence about that observation
  time, not a perpetual statement of the device's current configuration.

**Cache-eligible AV observation**
: A successful live AV availability read for an availability list, `set off`,
  or a cycle whose explicit mode set contains Off, after the observation has
  been joined to the exact device. A successful live AV current-mode read is
  also eligible when, and only when, it returns Off; other current modes do not
  establish Allow Off availability. No operation adds an AV read solely to warm
  the cache.

**Allow Off evidence invalidation**
: An accepted Off write backed by fresh or cached positive AV-derived evidence
  invalidates that positive after a definitive non-Off bounded readback. Setter
  rejection, timeout, and read failure leave it unchanged; invalidation is not
  a negative availability observation.

**Cache-authorized Off mismatch**
: An accepted HAL Off write whose definitive final state is non-Off. The command
  reports the existing no-op result and exit status 3, includes the actual final
  mode in JSON, deletes the positive cache entry, and stops without retrying a
  provider, applying a fallback, or advancing a cycle again.

**Cached availability provenance**
: Metadata emitted only when cached Off evidence is consumed. Plain operational
  output remains unchanged. Additive JSON identifies the cache source and its
  observation and expiry times; debug output is limited to hit, miss, and age.
  The raw UID, digest, and salt are never rendered, logged, or included in a
  support report.

**Cached Allow Off availability**
: The last persisted Allow Off availability observation associated with one
  resolved device. A live observation outranks it, and absence of a usable cache
  entry leaves availability unknown. A positive observation remains usable for
  seven days from its observation time; cache reads never extend that deadline.
  macOS version changes neither invalidate nor extend that deadline.
  A successful cache-eligible AV observation refreshes the positive when Off is
  advertised and replaces it with a negative tombstone when Off is absent. The
  newest observation wins, and a negative observation wins equal timestamps, so
  an older in-flight positive read cannot restore stale evidence. A selector or
  read failure is not an observation and leaves the cache unchanged.
  If a negative update cannot obtain the bounded shared mutation lock, a
  digest-keyed deny marker is written beside the cache and honored by later
  lookups until newer positive evidence supersedes it. A failed negative write
  under the lock removes the disposable cache instead of retaining stale
  positive evidence.
  On a HAL-only path, a usable positive adds Off to listed availability and may
  authorize `set off` or a cycle whose explicit mode set contains Off. It never
  adds Off to the default cycle.
  _Avoid_: Current Allow Off state, cached capability

**Cache correlation key**
: A local pseudonymous value that associates a previously resolved device with
  its cache entry. It neither selects nor merges devices and is not device
  identity for routing or command targeting. Its settled representation is a
  per-cache salted, full SHA-256 digest of the exact joined output endpoint's
  case-sensitive Core Audio device UID. The raw UID exists only transiently for
  correlation and is never persisted, logged, or exposed.
  _Avoid_: Device identity, device name

**Ambiguous cache correlation**
: A non-unique or conflicting correlation between cache records and current
  exact device groups. It is treated only as a cache miss: HAL listing omits
  Off, cache evidence authorizes no write, and the CLI neither guesses, merges,
  selects a device, nor emits an ambiguity error solely because of the cache.
  Commands otherwise continue normally.

**Allow Off cache store**
: The deliberately disposable, per-user, backup-excluded file at
  `~/Library/Caches/io.github.raulgg.airpods-control/allow-off-v1.json`. Its
  absence or removal by cache cleanup is a cache miss, not an operational error.

**Stale availability gap**
: The interval after Allow Off changes outside this CLI and before a later live
  observation refreshes or invalidates the cached observation. During this gap,
  HAL-only behavior may reflect the last observation instead of current state.
