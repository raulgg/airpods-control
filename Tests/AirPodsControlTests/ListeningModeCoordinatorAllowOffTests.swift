import CoreAudio
import Dispatch
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

  let listOutcome = coordinatorOutcome(
    ["lm", "list", "--json"],
    candidates: [
      candidate(
        name: "Cached AirPods",
        hal: nil,
        route: .notSelected,
        allowOffCorrelation: fixture.correlation
      )
    ]
  )
  // A correlation without a HAL provider cannot affect selection or output.
  check(listOutcome.plain == "no-device", "cache evidence never creates a device")

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
func testListeningModeAllowOffCacheAuthorizesExplicitHALWritesOnly() {
  let clock = Date(timeIntervalSince1970: 2_000_000_100)
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

  let setOff = coordinatorOutcome(["lm", "set", "off", "--json"], candidates: [halCandidate])
  check(setOff.plain == "ok", "cached AV evidence authorizes an explicit HAL Off write")
  check(backend.writtenValues == [1], "cache-authorized Off writes exact raw mode one")
  check(setOff.payload["listeningMode"] as? String == "off", "HAL reads Off back")
  check(
    setOff.payload["allowOffAvailability"] != nil,
    "cache-authorized Off write includes additive provenance"
  )

  backend.rawModeRead = .value(2)
  backend.resetWrites()
  let defaultCycle = coordinatorOutcome(["lm", "cycle"], candidates: [halCandidate])
  check(defaultCycle.plain == "transparency", "default cycle remains non-Off")
  check(backend.writtenValues == [3], "default cycle never targets cached Off")

  backend.rawModeRead = .value(2)
  backend.resetWrites()
  let explicitCycle = coordinatorOutcome(
    ["lm", "cycle", "--modes", "off,noise-cancellation"],
    candidates: [halCandidate]
  )
  check(explicitCycle.plain == "off", "an explicit Off cycle consumes the cache")
  check(backend.writtenValues == [1], "explicit Off cycle writes raw mode one")
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

func testListeningModeAllowOffHALMismatchEvictsOnlyAcceptedEvidence() {
  let clock = Date(timeIntervalSince1970: 2_000_000_200)
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
  check(mismatch.exitCode == 3, "definitive HAL mismatch exits three")
  check(
    mismatch.payload["listeningMode"] as? String == "noise-cancellation",
    "cache-authorized mismatch reports the actual final mode"
  )
  check(
    mismatch.payload["allowOffAvailability"] != nil,
    "mismatch reports the cached evidence consumed by that invocation"
  )
  if case .miss = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "accepted definitive mismatch evicts the positive evidence")
  } else {
    check(false, "accepted definitive mismatch evicts the positive evidence")
  }

  _ = fixture.cache.applyObservation(
    rawDeviceUID: "uid-42",
    allowsOff: true,
    observedAt: clock
  )
  backend.writeResult = .notSettable
  let rejected = coordinatorOutcome(["lm", "set", "off"], candidates: [halCandidate])
  check(rejected.plain == "no-op", "a provider rejection remains a no-op")
  if case .hit = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "setter rejection leaves positive evidence unchanged")
  } else {
    check(false, "setter rejection leaves positive evidence unchanged")
  }

  let av = FakeListeningModeTransport(
    name: "Cached AirPods",
    kind: .av,
    current: .noiseCancellation,
    appliesWrites: false
  )
  let avMismatch = coordinatorOutcome(
    ["lm", "set", "off"],
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
  if case .hit = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "an AV mismatch preserves its fresh availability evidence")
  } else {
    check(false, "an AV mismatch preserves its fresh availability evidence")
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
  if case .hit = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "successful AV availability with Off refreshes positive evidence")
    if case .hit(let record) = fixture.cache.lookup(rawDeviceUID: "uid-42") {
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
  if case .hit = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "a live AV get that returns Off refreshes positive evidence")
  } else {
    check(false, "a live AV get that returns Off refreshes positive evidence")
  }

  av.availabilityObservation = .unavailable
  _ = coordinatorOutcome(["lm", "list"], candidates: [joined])
  if case .hit = fixture.cache.lookup(rawDeviceUID: "uid-42") {
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
  if case .miss = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "a non-Off operation does not warm evidence from incidental reads")
  } else {
    check(false, "a non-Off operation does not warm evidence from incidental reads")
  }
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
  check(ambiguousOutcome.plain == "unsupported", "ambiguous UID correlation is a silent miss")
  check(
    ambiguousBackend.writtenValues.isEmpty,
    "ambiguous cache correlation never authorizes a write"
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

func testListeningModeAllowOffFreshNegativeEvidence() {
  let clock = Date(timeIntervalSince1970: 2_000_000_300)
  let staleBackend = FakeHALRoutingBackend()
  staleBackend.rawModeRead = .value(2)
  staleBackend.deviceUIDs[62] = .value("uid-62")
  let wrappedCache = InMemoryListeningModeAllowOffCache(
    salt: Data(repeating: 0xD8, count: 32),
    now: { clock }
  )!
  _ = wrappedCache.applyObservation(
    rawDeviceUID: "uid-62",
    allowsOff: true,
    observedAt: clock
  )
  let failingRemovalCache = FailingRemovalAllowOffCache(wrapped: wrappedCache)
  let staleCorrelation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: 62,
    collisionAudioDeviceIDs: [62],
    backend: staleBackend,
    cache: failingRemovalCache,
    logger: DebugLogger(enabled: false),
    now: { clock }
  )
  let staleHAL = HALListeningModeTransport(
    name: "Fresh Negative AirPods",
    audioDeviceID: 62,
    bluetoothDevice: NSObject(),
    backend: staleBackend,
    logger: DebugLogger(enabled: false),
    wait: { _ in }
  )
  let negativeAV = FakeListeningModeTransport(
    name: "Fresh Negative AirPods",
    kind: .av,
    modes: [.transparency, .adaptive, .noiseCancellation],
    current: .noiseCancellation
  )
  let freshNegative = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [
      ListeningModeCandidate(
        displayName: "Fresh Negative AirPods",
        selectableNames: ["Fresh Negative AirPods"],
        avTransport: negativeAV,
        halTransport: staleHAL,
        route: .unknown,
        allowOffCorrelation: staleCorrelation
      )
    ]
  )
  check(
    freshNegative.plain == "unsupported",
    "fresh AV negative evidence suppresses a stale cache hit even if deletion fails"
  )
  check(
    staleBackend.writtenValues.isEmpty,
    "failed negative-evidence persistence never reauthorizes HAL Off in the same command"
  )
}

func testListeningModeAllowOffStalePositiveAuthorization() {
  let clock = Date(timeIntervalSince1970: 2_000_000_300)
  let stalePositiveBackend = FakeHALRoutingBackend()
  stalePositiveBackend.rawModeRead = .value(2)
  stalePositiveBackend.deviceUIDs[72] = .value("uid-72")
  let stalePositiveCorrelation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: 72,
    collisionAudioDeviceIDs: [72],
    backend: stalePositiveBackend,
    cache: StalePositiveAllowOffCache(),
    logger: DebugLogger(enabled: false),
    now: { clock }
  )
  let stalePositiveAV = FakeListeningModeTransport(
    name: "Stale Positive AirPods",
    kind: .av,
    modes: ListeningMode.allCases,
    current: .noiseCancellation,
    settable: false
  )
  let stalePositiveHAL = HALListeningModeTransport(
    name: "Stale Positive AirPods",
    audioDeviceID: 72,
    bluetoothDevice: NSObject(),
    backend: stalePositiveBackend,
    logger: DebugLogger(enabled: false),
    wait: { _ in }
  )
  let stalePositiveOutcome = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [
      ListeningModeCandidate(
        displayName: "Stale Positive AirPods",
        selectableNames: ["Stale Positive AirPods"],
        avTransport: stalePositiveAV,
        halTransport: stalePositiveHAL,
        route: .unknown,
        allowOffCorrelation: stalePositiveCorrelation
      )
    ]
  )
  check(
    stalePositiveOutcome.plain == "unsupported",
    "a stale positive AV observation cannot authorize HAL Off"
  )
  check(
    stalePositiveBackend.writtenValues.isEmpty,
    "a rejected stale positive observation never reaches the HAL setter"
  )
}

func testListeningModeCoordinatorOrdersDelayedAVObservations() {
  let cache = InMemoryListeningModeAllowOffCache(
    salt: Data(repeating: 0xE1, count: 32)
  )!
  let oldReadStarted = DispatchSemaphore(value: 0)
  let releaseOldRead = DispatchSemaphore(value: 0)

  let oldBackend = FakeHALRoutingBackend()
  oldBackend.deviceUIDs[80] = .value("uid-80")
  let oldCorrelation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: 80,
    collisionAudioDeviceIDs: [80],
    backend: oldBackend,
    cache: cache,
    logger: DebugLogger(enabled: false),
    now: { Date(timeIntervalSince1970: 2_000_000_400) }
  )
  let oldAV = FakeListeningModeTransport(
    name: "Delayed AirPods",
    kind: .av,
    modes: ListeningMode.allCases
  )
  oldAV.onAvailabilityRead = {
    oldReadStarted.signal()
    _ = releaseOldRead.wait(timeout: .now() + 2)
  }
  let oldWork = DispatchWorkItem {
    _ = coordinatorOutcome(
      ["lm", "list"],
      candidates: [
        candidate(
          name: "Delayed AirPods",
          av: oldAV,
          route: .selected,
          allowOffCorrelation: oldCorrelation
        )
      ]
    )
  }
  DispatchQueue.global().async(execute: oldWork)
  let oldStarted = oldReadStarted.wait(timeout: .now() + 2) == .success
  check(oldStarted, "the older AV read reaches its controlled pause")

  let newBackend = FakeHALRoutingBackend()
  newBackend.deviceUIDs[80] = .value("uid-80")
  let newCorrelation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: 80,
    collisionAudioDeviceIDs: [80],
    backend: newBackend,
    cache: cache,
    logger: DebugLogger(enabled: false),
    now: { Date(timeIntervalSince1970: 2_000_000_500) }
  )
  let newAV = FakeListeningModeTransport(
    name: "Delayed AirPods",
    kind: .av,
    modes: [.transparency, .adaptive, .noiseCancellation]
  )
  let newOutcome = coordinatorOutcome(
    ["lm", "list"],
    candidates: [
      candidate(
        name: "Delayed AirPods",
        av: newAV,
        route: .selected,
        allowOffCorrelation: newCorrelation
      )
    ]
  )
  check(
    newOutcome.plain == "transparency,adaptive,noise-cancellation",
    "the newer negative AV observation completes while the older read is paused"
  )

  releaseOldRead.signal()
  check(
    oldWork.wait(timeout: .now() + 2) == .success,
    "the older AV observation completes after the newer one"
  )
  if case .miss = cache.lookup(rawDeviceUID: "uid-80") {
    check(true, "an older positive AV observation cannot replace a newer tombstone")
  } else {
    check(false, "an older positive AV observation cannot replace a newer tombstone")
  }

  let halBackend = FakeHALRoutingBackend()
  halBackend.rawModeRead = .value(2)
  halBackend.deviceUIDs[80] = .value("uid-80")
  let halCorrelation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: 80,
    collisionAudioDeviceIDs: [80],
    backend: halBackend,
    cache: cache,
    logger: DebugLogger(enabled: false),
    now: { Date(timeIntervalSince1970: 2_000_000_500) }
  )
  let hal = HALListeningModeTransport(
    name: "Delayed AirPods",
    audioDeviceID: 80,
    bluetoothDevice: NSObject(),
    backend: halBackend,
    logger: DebugLogger(enabled: false),
    wait: { _ in }
  )
  let offOutcome = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [
      ListeningModeCandidate(
        displayName: "Delayed AirPods",
        selectableNames: ["Delayed AirPods"],
        avTransport: nil,
        halTransport: hal,
        route: .notSelected,
        allowOffCorrelation: halCorrelation
      )
    ]
  )
  check(
    offOutcome.plain == "unsupported" && halBackend.writtenValues.isEmpty,
    "the newer negative tombstone blocks a later HAL Off write"
  )
}
