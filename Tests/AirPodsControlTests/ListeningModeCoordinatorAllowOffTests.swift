import CoreAudio
import Foundation

private func allowOffCacheFixture(
  backend: FakeHALRoutingBackend,
  now: @escaping () -> Date,
  targetID: AudioDeviceID = 42,
  collisionIDs: [AudioDeviceID] = [42]
) -> (
  cache: InMemoryListeningModeAllowOffCache,
  correlation: ListeningModeAllowOffCorrelation,
  transport: HALListeningModeTransport
) {
  let cache = InMemoryListeningModeAllowOffCache(
    salt: Data(repeating: 0xA5, count: 32),
    now: now
  )!
  backend.deviceUIDs[targetID] = .value("uid-\(targetID)")
  let correlation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: targetID,
    collisionAudioDeviceIDs: collisionIDs,
    backend: backend,
    cache: cache,
    logger: DebugLogger(enabled: false),
    now: now
  )
  let transport = HALListeningModeTransport(
    name: "Cached AirPods",
    audioDeviceID: targetID,
    bluetoothDevice: NSObject(),
    backend: backend,
    logger: DebugLogger(enabled: false),
    wait: { _ in }
  )
  return (cache, correlation, transport)
}
func testListeningModeAllowOffCacheConsumptionAndPrivacyMetadata() {
  var clock = Date(timeIntervalSince1970: 2_000_000_000)
  let backend = FakeHALRoutingBackend()
  backend.rawModeRead = .value(2)
  let fixture = allowOffCacheFixture(backend: backend, now: { clock })
  _ = fixture.cache.applyObservation(
    rawDeviceUID: "uid-42",
    allowsOff: true,
    observedAt: clock
  )

  let halCandidate = ListeningModeCandidate(
    displayName: "Cached AirPods",
    selectableNames: ["Cached AirPods"],
    avTransport: nil,
    halTransport: fixture.transport,
    route: .notSelected,
    allowOffCorrelation: fixture.correlation
  )
  let cachedList = coordinatorOutcome(
    ["lm", "list", "--json"],
    candidates: [halCandidate]
  )
  check(
    cachedList.plain == "off,transparency,adaptive,noise-cancellation",
    "a HAL list consumes positive evidence and adds Off"
  )
  let metadata = cachedList.payload["allowOffAvailability"] as? [String: Any]
  check(
    metadata?["source"] as? String == "cached-av-observation",
    "cached HAL output identifies only its safe provenance"
  )
  check(
    metadata?["observedAt"] as? String == "2033-05-18T03:33:20.000Z"
      && metadata?["expiresAt"] as? String == "2033-05-25T03:33:20.000Z",
    "cached HAL output reports the observation and fixed expiry timestamps"
  )
  let serialized = String(
    data: try! JSONSerialization.data(withJSONObject: cachedList.payload),
    encoding: .utf8
  )!
  check(!serialized.contains("uid-42"), "cache JSON never includes the Core Audio UID")
  check(!serialized.contains("a5a5"), "cache JSON never includes cache key material")

  let debugCorrelation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: 42,
    collisionAudioDeviceIDs: [42],
    backend: backend,
    cache: fixture.cache,
    logger: DebugLogger(enabled: true),
    now: { clock }
  )
  let debugOutput = capturingStandardError {
    _ = debugCorrelation.cachedAuthorization()
  }
  check(
    debugOutput?.contains("debug: allow_off_cache=\"hit\"") == true
      && debugOutput?.contains("debug: allow_off_cache.age_seconds=0") == true,
    "cache debug output is limited to hit and bounded age"
  )
  check(
    debugOutput?.contains("uid-42") == false
      && debugOutput?.contains("a5a5") == false,
    "cache debug output never contains correlation material"
  )

  let uidReadsAfterList = backend.deviceUIDReads.count
  let getOutcome = coordinatorOutcome(["lm", "get"], candidates: [halCandidate])
  check(getOutcome.plain == "noise-cancellation", "HAL get retains current-mode behavior")
  check(
    backend.deviceUIDReads.count == uidReadsAfterList,
    "HAL get never consumes cached Allow Off evidence"
  )
  check(
    getOutcome.payload["allowOffAvailability"] == nil,
    "HAL get has no cache provenance even when current state is Off-capable"
  )

  clock.addTimeInterval(PersistentListeningModeAllowOffCache.defaultTTL)
  let expired = coordinatorOutcome(["lm", "list"], candidates: [halCandidate])
  check(
    expired.plain == "transparency,adaptive,noise-cancellation",
    "evidence expires after a non-sliding seven-day TTL"
  )
}

func testListeningModeAllowOffProbeAndCycleWorkflow() {
  let clock = Date(timeIntervalSince1970: 2_000_000_125)

  func fixture(
    transport: FakeListeningModeTransport
  ) -> (
    cache: InMemoryListeningModeAllowOffCache,
    candidate: ListeningModeCandidate
  ) {
    let backend = FakeHALRoutingBackend()
    let correlated = allowOffCacheFixture(backend: backend, now: { clock })
    return (
      correlated.cache,
      candidate(
        name: transport.name ?? "Probe AirPods",
        hal: transport,
        route: .notSelected,
        allowOffCorrelation: correlated.correlation
      )
    )
  }

  let successfulTransport = FakeListeningModeTransport(
    name: "Successful Probe AirPods",
    kind: .hal,
    modes: [.transparency, .adaptive, .noiseCancellation],
    current: .noiseCancellation
  )
  let successful = fixture(transport: successfulTransport)
  let successfulOutcome = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [successful.candidate]
  )
  check(successfulOutcome.plain == "ok", "a definitive Off probe succeeds")
  check(successfulTransport.allowOffWrites == [true], "an explicit Off miss probes once")
  if case .allowed = successful.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "a successful correlated probe stores positive evidence")
  } else {
    check(false, "a successful correlated probe stores positive evidence")
  }

  successfulTransport.current = .noiseCancellation
  let defaultCycle = coordinatorOutcome(
    ["lm", "cycle"],
    candidates: [successful.candidate]
  )
  successfulTransport.current = .noiseCancellation
  let explicitCycle = coordinatorOutcome(
    ["lm", "cycle", "--modes", "off,noise-cancellation"],
    candidates: [successful.candidate]
  )
  check(defaultCycle.plain == "transparency", "the default cycle remains non-Off")
  check(explicitCycle.plain == "off", "an explicit Off cycle consumes cached evidence")
  check(
    successfulTransport.allowOffWrites == [true, false, true],
    "only explicit Off writes use the Allow Off path"
  )

  let deniedTransport = FakeListeningModeTransport(
    name: "Denied Probe AirPods",
    kind: .hal,
    modes: [.transparency, .adaptive, .noiseCancellation],
    current: .noiseCancellation,
    appliesWrites: false
  )
  let denied = fixture(transport: deniedTransport)
  let deniedOutcome = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [denied.candidate]
  )
  check(deniedOutcome.plain == "unsupported", "definitive non-Off probe is unsupported")
  if case .denied = denied.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "definitive non-Off probe stores denial evidence")
  } else {
    check(false, "definitive non-Off probe stores denial evidence")
  }
  _ = coordinatorOutcome(["lm", "set", "off"], candidates: [denied.candidate])
  check(deniedTransport.setterTargets == [.off], "cached denial prevents a repeated probe")

  let rejectedTransport = FakeListeningModeTransport(
    name: "Rejected Probe AirPods",
    kind: .hal,
    modes: [.transparency, .adaptive, .noiseCancellation],
    current: .noiseCancellation,
    acceptsWrites: false,
    appliesWrites: false
  )
  let rejected = fixture(transport: rejectedTransport)
  let rejectedOutcome = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [rejected.candidate]
  )
  check(rejectedOutcome.plain == "unavailable", "a rejected probe setter is unavailable")
  check(rejected.cache.lookup(rawDeviceUID: "uid-42") == .miss, "rejection stores no denial")

  let unreadableTransport = FakeListeningModeTransport(
    name: "Unreadable Probe AirPods",
    kind: .hal,
    modes: [.transparency, .adaptive, .noiseCancellation],
    current: .noiseCancellation,
    appliesWrites: false
  )
  unreadableTransport.dropsWriteReadback = true
  let unreadable = fixture(transport: unreadableTransport)
  let unreadableOutcome = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [unreadable.candidate]
  )
  check(unreadableOutcome.plain == "no-op", "an unreadable accepted probe is no-op")
  check(unreadable.cache.lookup(rawDeviceUID: "uid-42") == .miss, "unreadable final state stores no denial")
}

func testListeningModeWritePlanOwnsHALAllowOffPolicy() {
  let clock = Date(timeIntervalSince1970: 2_000_000_150)
  let backend = FakeHALRoutingBackend()
  let fixture = allowOffCacheFixture(backend: backend, now: { clock })
  _ = fixture.cache.applyObservation(
    rawDeviceUID: "uid-42",
    allowsOff: true,
    observedAt: clock
  )
  let hal = FakeListeningModeTransport(
    name: "Planned AirPods",
    kind: .hal,
    modes: [.transparency, .adaptive, .noiseCancellation],
    current: .noiseCancellation
  )
  let halCandidate = candidate(
    name: "Planned AirPods",
    hal: hal,
    route: .notSelected,
    allowOffCorrelation: fixture.correlation
  )

  let accepted = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [halCandidate]
  )
  check(accepted.plain == "ok", "the write plan authorizes HAL Off")
  check(
    hal.allowOffWrites == [true],
    "HAL authorization reaches a non-concrete transport without an executor cast"
  )

  hal.current = .noiseCancellation
  hal.appliesWrites = false
  hal.dropsWriteReadback = true
  let unknownReadback = coordinatorOutcome(
    ["lm", "set", "off", "--json"],
    candidates: [halCandidate]
  )
  check(unknownReadback.plain == "no-op", "authorized HAL Off needs a verified readback")
  check(
    unknownReadback.payload["listeningMode"] is NSNull,
    "authorized HAL Off never invents a Transparency fallback"
  )

  let av = FakeListeningModeTransport(
    name: "Planned AirPods",
    kind: .av,
    current: .noiseCancellation
  )
  let avOutcome = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [candidate(name: "Planned AirPods", av: av, route: .selected)]
  )
  check(avOutcome.plain == "ok", "live AV Off remains writable")
  check(av.allowOffWrites == [false], "AV writes do not consume HAL authorization")

  let ordinaryHAL = OrdinaryHALListeningModeTransport(
    wrapped: FakeListeningModeTransport(
      name: "Ordinary HAL AirPods",
      kind: .hal,
      modes: [.off],
      current: .noiseCancellation
    )
  )
  let ordinaryPlan = ListeningModeWritePlan(
    transport: ordinaryHAL,
    availableModes: [.off],
    allowOffAuthorization: .live(cache: nil, record: nil)
  )
  check(
    !ordinaryPlan.canWrite(.off),
    "a HAL write plan requires the explicit Allow Off capability"
  )
}

func testListeningModeAllowOffMismatchEvictsAcceptedDefinitiveEvidence() {
  var clock = Date(timeIntervalSince1970: 2_000_000_200)
  let backend = FakeHALRoutingBackend()
  backend.rawModeRead = .value(2)
  backend.appliesWrite = false
  let fixture = allowOffCacheFixture(backend: backend, now: { clock })
  _ = fixture.cache.applyObservation(
    rawDeviceUID: "uid-42",
    allowsOff: true,
    observedAt: clock
  )
  let halCandidate = ListeningModeCandidate(
    displayName: "Cached AirPods",
    selectableNames: ["Cached AirPods"],
    avTransport: nil,
    halTransport: fixture.transport,
    route: .notSelected,
    allowOffCorrelation: fixture.correlation
  )

  let mismatch = coordinatorOutcome(
    ["lm", "set", "off", "--json"],
    candidates: [halCandidate]
  )
  check(mismatch.plain == "no-op", "definitive non-Off HAL readback is a no-op")
  check(
    mismatch.payload["listeningMode"] as? String == "noise-cancellation",
    "cache-authorized mismatch reports the actual final mode"
  )
  check(
    mismatch.payload["allowOffAvailability"] != nil,
    "mismatch reports the cached evidence consumed by that invocation"
  )
  if case .denied = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "accepted definitive mismatch records denial evidence")
  } else {
    check(false, "accepted definitive mismatch records denial evidence")
  }

  clock.addTimeInterval(1)
  _ = fixture.cache.applyObservation(
    rawDeviceUID: "uid-42",
    allowsOff: true,
    observedAt: clock
  )
  backend.writeResult = .notSettable
  let rejected = coordinatorOutcome(["lm", "set", "off"], candidates: [halCandidate])
  check(rejected.plain == "unavailable", "a provider rejection is unavailable")
  if case .allowed = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "setter rejection leaves positive evidence unchanged")
  } else {
    check(false, "setter rejection leaves positive evidence unchanged")
  }

  let av = FakeListeningModeTransport(
    name: "Cached AirPods",
    kind: .av,
    current: .transparency,
    appliesWrites: false
  )
  let avMismatch = coordinatorOutcome(
    ["lm", "set", "off", "--json"],
    candidates: [
      candidate(
        name: "Cached AirPods",
        av: av,
        route: .selected,
        allowOffCorrelation: fixture.correlation
      )
    ]
  )
  check(avMismatch.plain == "no-op", "a definitive non-Off AV readback is a no-op")
  check(
    avMismatch.payload["listeningMode"] as? String == "transparency",
    "an AV mismatch reports the definitive final mode"
  )
  if case .denied = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "an accepted definitive AV mismatch records denial evidence")
  } else {
    check(false, "an accepted definitive AV mismatch records denial evidence")
  }

  backend.writeResult = .success
  backend.resetWrites()
  let listAfterMismatch = coordinatorOutcome(
    ["lm", "list", "--json"],
    candidates: [halCandidate]
  )
  check(
    (listAfterMismatch.payload["supportedListeningModes"] as? [String])?.contains("off")
      == false,
    "HAL list fails closed after an AV mismatch evicts positive evidence"
  )

  let setAfterMismatch = coordinatorOutcome(
    ["lm", "set", "off", "--json"],
    candidates: [halCandidate]
  )
  check(setAfterMismatch.plain == "unsupported", "cached denial makes HAL Off unsupported")
  check(backend.writtenValues.isEmpty, "cached denial prevents another HAL probe")
}

func testListeningModeAllowOffAVMismatchPreservesEvidenceWhenAmbiguous() {
  let clock = Date(timeIntervalSince1970: 2_000_000_250)
  let backend = FakeHALRoutingBackend()
  let fixture = allowOffCacheFixture(backend: backend, now: { clock })
  let av = FakeListeningModeTransport(
    name: "Ambiguous AirPods",
    kind: .av,
    current: .transparency,
    acceptsWrites: false,
    appliesWrites: false
  )
  let avCandidate = candidate(
    name: "Ambiguous AirPods",
    av: av,
    route: .selected,
    allowOffCorrelation: fixture.correlation
  )

  let rejected = coordinatorOutcome(
    ["lm", "set", "off", "--json"],
    candidates: [avCandidate]
  )
  check(rejected.plain == "unavailable", "a rejected AV Off setter is unavailable")
  if case .allowed = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "a rejected AV setter preserves fresh positive evidence")
  } else {
    check(false, "a rejected AV setter preserves fresh positive evidence")
  }

  av.acceptsWrites = true
  av.dropsWriteReadback = true
  let unknown = coordinatorOutcome(
    ["lm", "set", "off", "--json"],
    candidates: [avCandidate]
  )
  check(unknown.plain == "no-op", "an unknown AV Off readback remains a no-op")
  if case .allowed = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "an unknown AV readback preserves fresh positive evidence")
  } else {
    check(false, "an unknown AV readback preserves fresh positive evidence")
  }
}

func testListeningModeAllowOffAVEvidenceLifecycle() {
  var clock = Date(timeIntervalSince1970: 2_000_000_300)
  let backend = FakeHALRoutingBackend()
  backend.rawModeRead = .value(2)
  let fixture = allowOffCacheFixture(backend: backend, now: { clock })
  let firstObservationTime = clock
  backend.onDeviceUIDRead = { clock.addTimeInterval(1) }
  let av = FakeListeningModeTransport(
    name: "Cached AirPods",
    kind: .av,
    modes: ListeningMode.allCases,
    current: .transparency
  )
  let joined = candidate(
    name: "Cached AirPods",
    av: av,
    route: .selected,
    allowOffCorrelation: fixture.correlation
  )
  _ = coordinatorOutcome(["lm", "list"], candidates: [joined])
  backend.onDeviceUIDRead = nil
  if case .allowed = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "successful AV availability with Off refreshes positive evidence")
    if case .allowed(let record) = fixture.cache.lookup(rawDeviceUID: "uid-42") {
      check(
        record.evidence.observedAt == firstObservationTime,
        "AV observation time is captured before UID correlation"
      )
    }
  } else {
    check(false, "successful AV availability with Off refreshes positive evidence")
  }

  av.modes = [.transparency, .adaptive, .noiseCancellation]
  _ = coordinatorOutcome(["lm", "list"], candidates: [joined])
  if case .miss = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "successful AV availability without Off deletes evidence")
  } else {
    check(false, "successful AV availability without Off deletes evidence")
  }

  clock.addTimeInterval(1)
  av.current = .off
  let readsBeforeGet = av.readModesCount
  _ = coordinatorOutcome(["lm", "get"], candidates: [joined])
  check(av.readModesCount == readsBeforeGet, "AV get does not add an availability read")
  if case .allowed = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "a live AV get that returns Off refreshes positive evidence")
  } else {
    check(false, "a live AV get that returns Off refreshes positive evidence")
  }

  av.availabilityObservation = .unavailable
  _ = coordinatorOutcome(["lm", "list"], candidates: [joined])
  if case .allowed = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "AV selector/read failure leaves evidence unchanged")
  } else {
    check(false, "AV selector/read failure leaves evidence unchanged")
  }

  _ = fixture.cache.applyObservation(
    rawDeviceUID: "uid-42",
    allowsOff: false,
    observedAt: clock
  )
  av.availabilityObservation = nil
  av.current = .off
  _ = coordinatorOutcome(["lm", "set", "adaptive"], candidates: [joined])
  if case .denied = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "a non-Off operation preserves existing denial evidence")
  } else {
    check(false, "a non-Off operation preserves existing denial evidence")
  }

  clock.addTimeInterval(1)
  av.availabilityObservation = .value([
    .transparency,
    .adaptive,
    .noiseCancellation,
  ])
  _ = coordinatorOutcome(["lm", "list"], candidates: [joined])
  check(
    {
      if case .denied = fixture.cache.lookup(rawDeviceUID: "uid-42") { return true }
      return false
    }(),
    "an AV omission preserves an unexpired denial"
  )

  backend.resetWrites()
  let deniedHAL = ListeningModeCandidate(
    displayName: "Cached AirPods",
    selectableNames: ["Cached AirPods"],
    avTransport: nil,
    halTransport: fixture.transport,
    route: .notSelected,
    allowOffCorrelation: fixture.correlation
  )
  let deniedHALOutcome = coordinatorOutcome(
    ["lm", "set", "off", "--json"],
    candidates: [deniedHAL]
  )
  check(
    deniedHALOutcome.plain == "unsupported",
    "an AV omission keeps HAL Off unsupported after denial"
  )
  check(
    backend.writtenValues.isEmpty,
    "cached denial after AV omission avoids another HAL setter call"
  )
}

func testListeningModeAllowOffAmbiguousCorrelation() {
  let clock = Date(timeIntervalSince1970: 2_000_000_300)
  let ambiguousBackend = FakeHALRoutingBackend()
  ambiguousBackend.rawModeRead = .value(2)
  ambiguousBackend.deviceUIDs[42] = .value("same-uid")
  ambiguousBackend.deviceUIDs[43] = .value("same-uid")
  let ambiguousCache = InMemoryListeningModeAllowOffCache(
    salt: Data(repeating: 0xB6, count: 32),
    now: { clock }
  )!
  _ = ambiguousCache.applyObservation(
    rawDeviceUID: "same-uid",
    allowsOff: true,
    observedAt: clock
  )
  let ambiguousCorrelation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: 42,
    collisionAudioDeviceIDs: [42, 43],
    backend: ambiguousBackend,
    cache: ambiguousCache,
    logger: DebugLogger(enabled: false),
    now: { clock }
  )
  let ambiguousTransport = HALListeningModeTransport(
    name: "Ambiguous AirPods",
    audioDeviceID: 42,
    bluetoothDevice: NSObject(),
    backend: ambiguousBackend,
    logger: DebugLogger(enabled: false),
    wait: { _ in }
  )
  let ambiguousOutcome = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [
      ListeningModeCandidate(
        displayName: "Ambiguous AirPods",
        selectableNames: ["Ambiguous AirPods"],
        avTransport: nil,
        halTransport: ambiguousTransport,
        route: .notSelected,
        allowOffCorrelation: ambiguousCorrelation
      )
    ]
  )
  check(ambiguousOutcome.plain == "ok", "ambiguous UID correlation does not prevent a live probe")
  check(
    ambiguousBackend.writtenValues == [1],
    "an explicit probe does not require cache correlation"
  )
}

func testListeningModeAllowOffLiveFallback() {
  let liveBackend = FakeHALRoutingBackend()
  liveBackend.rawModeRead = .value(2)
  let liveHAL = HALListeningModeTransport(
    name: "Live Evidence AirPods",
    audioDeviceID: 52,
    bluetoothDevice: NSObject(),
    backend: liveBackend,
    logger: DebugLogger(enabled: false),
    wait: { _ in }
  )
  let incompleteLiveAV = FakeListeningModeTransport(
    name: "Live Evidence AirPods",
    kind: .av,
    modes: ListeningMode.allCases,
    current: .noiseCancellation,
    settable: false
  )
  let liveFallback = coordinatorOutcome(
    ["lm", "set", "off", "--json"],
    candidates: [
      ListeningModeCandidate(
        displayName: "Live Evidence AirPods",
        selectableNames: ["Live Evidence AirPods"],
        avTransport: incompleteLiveAV,
        halTransport: liveHAL,
        route: .unknown
      )
    ]
  )
  check(liveFallback.plain == "ok", "fresh AV Off evidence authorizes same-command HAL fallback")
  check(liveBackend.writtenValues == [1], "fresh evidence does not require cache persistence")
  check(
    liveFallback.payload["allowOffAvailability"] == nil,
    "fresh live evidence is never mislabeled as cached provenance"
  )
}
