import Foundation

func testPrivateContextSelectorDiscovery() {
  let logger = DebugLogger(enabled: false)
  let modern = FakeContext(devices: [])
  let legacy = FakeContext(devices: [])

  let legacyProvider = FakeLegacyContextProvider(context: legacy)
  check(
    PrivateAudioDiscovery.sharedContext(from: legacyProvider, logger: logger) === legacy,
    "legacy sharedSystemAudio selector is supported"
  )

  let dualProvider = FakeDualContextProvider(modern: modern, legacy: legacy)
  check(
    PrivateAudioDiscovery.sharedContext(from: dualProvider, logger: logger) === modern,
    "modern context selector is preferred"
  )

  let missingProvider = NSObject()
  check(
    PrivateAudioDiscovery.sharedContext(from: missingProvider, logger: logger) == nil,
    "missing context selectors return nil"
  )
  check(
    PrivateAudioDiscovery.outputDevices(from: missingProvider, logger: logger) == nil,
    "missing outputDevices selector returns nil"
  )
  check(
    PrivateAudioDiscovery.outputDevice(from: missingProvider, logger: logger) == nil,
    "missing outputDevice selector returns nil"
  )

  let device = FakeRawDevice(name: "My AirPods Pro")
  let context = FakeContext(devices: [device], currentDevice: device)
  check(
    PrivateAudioDiscovery.outputDevices(from: context, logger: logger)?.first === device,
    "plural outputDevices is discovered safely"
  )
  check(
    PrivateAudioDiscovery.outputDevice(from: context, logger: logger) === device,
    "singular outputDevice is discovered independently"
  )
}

func testContextEndpointsPreservePluralOrderAndMultiplicity() {
  let first = FakeRawDevice(name: "First AirPods")
  let second = FakeRawDevice(name: "Second AirPods")
  let context = FakeContext(devices: [first, second, first], currentDevice: second)

  let endpoints = PrivateAudioDiscovery.contextEndpoints(
    from: context,
    logger: DebugLogger(enabled: false)
  )

  check(endpoints.plural.count == 3, "plural endpoint multiplicity is preserved")
  check(
    endpoints.plural[0] === first
      && endpoints.plural[1] === second
      && endpoints.plural[2] === first,
    "plural endpoint order is preserved exactly"
  )
  check(endpoints.singular === second, "the singular current endpoint is retained separately")
}

func testSameIdentifierSingularAuthorityRejectsWithdrawnMode() {
  let identifier = "current-wrapper-policy-endpoint"
  let plural = FakeRawDevice(
    name: "Policy AirPods",
    modes: Array(rawListeningModeValues.values),
    deviceIdentifier: identifier
  )
  let singular = FakeRawDevice(
    name: "Policy AirPods",
    modes: [rawListeningModeValues[.transparency]!],
    deviceIdentifier: identifier
  )
  let endpoints = PrivateAudioDiscovery.contextEndpoints(
    from: FakeContext(devices: [plural], currentDevice: singular),
    logger: DebugLogger(enabled: false)
  )
  let selected = PrivateAudioController(
    endpoints: endpoints,
    logger: DebugLogger(enabled: false)
  ).selectDevice(named: nil)

  check(
    selected?.availableListeningModes() == [.transparency],
    "the singular current endpoint governs advertised eligibility"
  )
  let outcome = CommandExecution.execute(try! parseInvocation(["lm", "set", "anc"])) {
    _, _ in selected
  }
  check(
    outcome.plain == "unsupported",
    "a mode withdrawn by the singular endpoint is unsupported"
  )
  check(
    singular.listeningModeSetCount == 0 && plural.listeningModeSetCount == 0,
    "a withdrawn mode reaches neither singular nor stale plural setter"
  )
}

func testReadOnlySingularNeverFallsBackToPluralSetter() {
  let identifier = "read-only-current-endpoint"
  let plural = FakeRawDevice(name: "Stale AirPods", deviceIdentifier: identifier)
  let singular = FakeReadOnlyRawDevice(
    name: "Current AirPods",
    deviceIdentifier: identifier
  )
  let endpoints = PrivateAudioDiscovery.contextEndpoints(
    from: FakeContext(devices: [plural], currentDevice: singular),
    logger: DebugLogger(enabled: false)
  )
  let selected = PrivateAudioController(
    endpoints: endpoints,
    logger: DebugLogger(enabled: false)
  ).selectDevice(named: nil)

  check(selected?.name == "Current AirPods", "the read-only singular wrapper stays authoritative")
  check(
    selected?.canSetListeningMode() == false,
    "the singular wrapper's missing setter is honored"
  )
  let outcome = CommandExecution.execute(try! parseInvocation(["lm", "set", "adaptive"])) {
    _, _ in selected
  }
  check(outcome.plain == "unavailable", "a read-only singular endpoint reports unavailable")
  check(plural.listeningModeSetCount == 0, "the stale plural setter is never used as fallback")
}

func testSupportReportContextDiscoveryIsPluralOnlyAndPrivate() {
  let plural = FakeRawDevice(
    name: "Private Plural AirPods",
    deviceIdentifier: "AA:BB:CC:DD:EE:FF"
  )
  let singular = FakeRawDevice(
    name: "Private Singular AirPods",
    deviceIdentifier: "11:22:33:44:55:66"
  )
  let context = FakeContext(devices: [plural], currentDevice: singular)
  var selected: PrivateAudioDevice?

  _ = capturingStandardError {
    let rawDevices = PrivateAudioDiscovery.outputDevices(
      from: context,
      logger: DebugLogger(enabled: true)
    ) ?? []
    selected = PrivateAudioController(
      rawDevices: rawDevices,
      logger: DebugLogger(enabled: true),
      includeDeviceNames: false
    ).selectDevice(named: nil)
  }

  check(selected != nil, "support-report selects one compatible plural endpoint")
  check(context.outputDeviceReadCount == 0, "support-report never reads singular outputDevice")
  check(
    plural.nameReadCount == 0 && singular.nameReadCount == 0,
    "support-report reads no customizable endpoint names"
  )
  check(
    plural.deviceIDReadCount == 0 && singular.deviceIDReadCount == 0,
    "support-report reads no private endpoint identifiers"
  )
}

func testSupportReportPluralMultiplicityRequiresUniqueness() {
  let repeated = FakeRawDevice(
    name: "Repeated AirPods",
    deviceIdentifier: "AA:BB:CC:DD:EE:FF"
  )
  let singular = FakeRawDevice(name: "Ignored Singular AirPods")
  let context = FakeContext(devices: [repeated, repeated], currentDevice: singular)
  let rawDevices = PrivateAudioDiscovery.outputDevices(
    from: context,
    logger: DebugLogger(enabled: false)
  ) ?? []
  let selected = PrivateAudioController(
    rawDevices: rawDevices,
    logger: DebugLogger(enabled: false),
    includeDeviceNames: false
  ).selectDevice(named: nil)

  check(selected == nil, "support-report requires one unique compatible plural endpoint")
  check(context.outputDeviceReadCount == 0, "plural uniqueness does not enter singular discovery")
  check(
    repeated.nameReadCount == 0 && repeated.deviceIDReadCount == 0,
    "plural uniqueness remains name- and identifier-free"
  )
  check(
    singular.nameReadCount == 0 && singular.deviceIDReadCount == 0,
    "the unused singular endpoint remains completely unread"
  )
}

func testIncompatibleUnidentifiedPluralDoesNotBlockValidSingular() {
  let singular = FakeRawDevice(
    name: "Current AirPods",
    deviceIdentifier: ""
  )
  let endpoints = PrivateAudioContextEndpoints(
    plural: [FakeIncompleteRawDevice()],
    singular: singular
  )
  guard let selected = PrivateAudioController(
    endpoints: endpoints,
    logger: DebugLogger(enabled: false)
  ).selectDevice(named: nil) else {
    check(false, "a filtered no-ID plural does not hide the valid singular endpoint")
    return
  }

  let observation = selected.setListeningModeAndReadBack(.adaptive, wait: { _ in })
  check(observation.observed == .adaptive, "the valid no-ID singular endpoint remains writable")
  check(singular.listeningModeSetCount == 1, "the write reaches the singular endpoint")
  check(
    singular.deviceIDReadCount == 0,
    "a filtered plural requires no speculative singular identifier read"
  )
}

func testCompatibleUnidentifiedPluralIsSuppressedBySingularAuthority() {
  let firstPlural = FakeRawDevice(name: "First stale AirPods", deviceIdentifier: "")
  let secondPlural = FakeRawDevice(name: "Second stale AirPods", deviceIdentifier: "")
  let singular = FakeRawDevice(name: "Current AirPods", deviceIdentifier: "")
  let controller = PrivateAudioController(
    endpoints: PrivateAudioContextEndpoints(
      plural: [firstPlural, secondPlural],
      singular: singular
    ),
    logger: DebugLogger(enabled: false)
  )
  let resolved = controller.selectDevices(named: nil, policy: .allOrExact)
  let selected = resolved?.first

  check(resolved?.count == 1, "unresolved plural aliases produce one current status record")
  check(selected?.name == "Current AirPods", "the singular endpoint wins unresolved alias risk")
  let observation = selected?.setListeningModeAndReadBack(.adaptive, wait: { _ in })
  check(observation?.observed == .adaptive, "the authoritative singular endpoint is writable")
  check(
    singular.listeningModeSetCount == 1
      && firstPlural.listeningModeSetCount == 0
      && secondPlural.listeningModeSetCount == 0,
    "unidentified plural wrappers never receive the write"
  )
}

func testUnidentifiedPluralIsNotUsedWhenSingularIsIncompatible() {
  let plural = FakeRawDevice(name: "Stale AirPods", deviceIdentifier: "")
  let selected = PrivateAudioController(
    endpoints: PrivateAudioContextEndpoints(
      plural: [plural],
      singular: FakeIncompleteRawDevice()
    ),
    logger: DebugLogger(enabled: false)
  ).selectDevice(named: nil)

  check(selected == nil, "unresolved plural identity fails closed without a valid singular")
  check(plural.listeningModeSetCount == 0, "a stale unidentified plural receives no write")
}

func testStatusPreservesRoutingOrderAndUsesSingularCurrentWrapper() {
  let first = FakeRawDevice(
    name: "First AirPods",
    deviceIdentifier: "status-first-endpoint"
  )
  let pluralCurrent = FakeRawDevice(
    name: "Stale Current AirPods",
    mode: rawListeningModeValues[.noiseCancellation]!,
    deviceIdentifier: "status-current-endpoint"
  )
  let last = FakeRawDevice(
    name: "Last Beats",
    modelIdentifier: "BeatsTest1,1",
    deviceIdentifier: "status-last-endpoint"
  )
  let singular = FakeRawDevice(
    name: "Current AirPods",
    modes: [rawListeningModeValues[.transparency]!],
    mode: rawListeningModeValues[.transparency]!,
    deviceIdentifier: "status-current-endpoint"
  )
  let controller = PrivateAudioController(
    endpoints: PrivateAudioContextEndpoints(
      plural: [first, pluralCurrent, last],
      singular: singular
    ),
    logger: DebugLogger(enabled: false)
  )
  guard let devices = controller.selectDevices(named: nil, policy: .allOrExact) else {
    check(false, "status resolves the combined routing endpoints")
    return
  }

  check(
    devices.map(\.name) == ["First AirPods", "Current AirPods", "Last Beats"],
    "status keeps routing order while replacing the current plural alias"
  )
  check(
    devices.count == 3
      && devices[0].object === first
      && devices[1].object === singular
      && devices[2].object === last,
    "status reads the singular wrapper once at the plural alias position"
  )
  let outcome = StatusCommand.outcome(devices: devices)
  let records = outcome.payload["devices"] as? [[String: Any]]
  check(
    records?[1]["listeningMode"] as? String == "transparency",
    "status reports the singular current capability snapshot"
  )
  check(
    pluralCurrent.listeningModeSetCount == 0 && singular.listeningModeSetCount == 0,
    "aggregate status never invokes either wrapper's setter"
  )
}

func testSingularOnlyEndpointRemainsDirectlyControllable() {
  let singular = FakeRawDevice(name: "Singular AirPods")
  guard let selected = PrivateAudioController(
    endpoints: PrivateAudioContextEndpoints(plural: [], singular: singular),
    logger: DebugLogger(enabled: false)
  ).selectDevice(named: nil) else {
    check(false, "the singular current endpoint survives an empty plural list")
    return
  }

  let modeWrite = selected.setListeningModeAndReadBack(.adaptive, wait: { _ in })
  check(modeWrite.observed == .adaptive, "singular listening-mode control remains direct")
  let awarenessWrite = selected.setConversationAwarenessAndReadBack(true, wait: { _ in })
  check(awarenessWrite.observed == true, "singular Conversation Awareness control remains direct")
  check(
    singular.listeningModeSetCount == 1 && singular.conversationAwarenessSetCount == 1,
    "both settings are written through the singular endpoint"
  )
}

func testStatusReadsCAOnlySingularEndpointWithoutWrites() {
  let singular = FakeCAOnlyCurrentRawDevice()
  let controller = PrivateAudioController(
    endpoints: PrivateAudioContextEndpoints(plural: [], singular: singular),
    logger: DebugLogger(enabled: false)
  )
  guard let devices = controller.selectDevices(named: nil, policy: .allOrExact) else {
    check(false, "status discovers the CA-only singular current endpoint")
    return
  }

  let outcome = StatusCommand.outcome(devices: devices)
  let record = (outcome.payload["devices"] as? [[String: Any]])?.first
  check(record?["conversationAwareness"] as? String == "off", "status reads singular CA")
  check(record?["listeningMode"] is NSNull, "the missing singular mode read remains null")
  check(
    (record?["errors"] as? [String: String]) == ["listeningMode": "read-error"],
    "status records the singular listening-mode read error"
  )
  check(
    singular.conversationAwarenessSetCount == 0,
    "status never writes the CA-only singular endpoint"
  )
}

func testSingularEmptyModesRetainCurrentModeAndConversationAwarenessControl() {
  let singular = FakeRawDevice(name: "One-bud AirPods", modes: [])
  let selected = PrivateAudioController(
    endpoints: PrivateAudioContextEndpoints(plural: [], singular: singular),
    logger: DebugLogger(enabled: false)
  ).selectDevice(named: nil)

  check(selected != nil, "a singular endpoint with a live control signal survives empty modes")
  check(selected?.availableListeningModes().isEmpty == true, "empty modes remain truthful")
  let modeGet = CommandExecution.execute(try! parseInvocation(["lm", "get"])) {
    _, _ in selected
  }
  check(
    modeGet.plain == "transparency",
    "the current listening mode remains readable while modes are empty"
  )
  let modeSet = CommandExecution.execute(try! parseInvocation(["lm", "set", "adaptive"])) {
    _, _ in selected
  }
  check(modeSet.plain == "unsupported", "an unadvertised listening mode remains unsupported")
  check(singular.listeningModeSetCount == 0, "empty modes cannot bypass command eligibility")

  _ = CommandExecution.execute(try! parseInvocation(["ca", "set", "on"])) {
    _, _ in selected
  }
  check(
    singular.conversationAwarenessSetCount == 1,
    "Conversation Awareness writes through the singular endpoint"
  )
}

func testCatalogedPluralOnlyEmptyModesIsRejected() {
  let catalogedPlural = FakeReadOnlyRawDevice(
    name: "Cataloged stale AirPods",
    modes: [],
    modelIdentifier: "BTHeadphones76,8231"
  )
  let selected = PrivateAudioController(
    rawDevices: [catalogedPlural],
    logger: DebugLogger(enabled: false)
  ).selectDevice(named: nil)

  check(selected == nil, "product catalog membership never proves runtime control capability")
}

func testCatalogedEmptyPluralDoesNotBlockControllableEmptyModeSingular() {
  let plural = FakeReadOnlyRawDevice(
    name: "Cataloged stale AirPods",
    modes: [],
    modelIdentifier: "BTHeadphones76,8231",
    deviceIdentifier: ""
  )
  let singular = FakeRawDevice(
    name: "One-bud current AirPods",
    modes: [],
    deviceIdentifier: ""
  )
  let selected = PrivateAudioController(
    endpoints: PrivateAudioContextEndpoints(plural: [plural], singular: singular),
    logger: DebugLogger(enabled: false)
  ).selectDevice(named: nil)

  check(selected?.object === singular, "the controllable singular endpoint is selected")
  let observation = selected?.setConversationAwarenessAndReadBack(true, wait: { _ in })
  check(observation?.observed == true, "the empty-mode singular keeps direct CA control")
  check(
    singular.conversationAwarenessSetCount == 1,
    "the cataloged non-controllable plural never shadows the singular setter"
  )
}

func runPrivateAudioDiscoveryTests() {
  testPrivateContextSelectorDiscovery()
  testContextEndpointsPreservePluralOrderAndMultiplicity()
  testSameIdentifierSingularAuthorityRejectsWithdrawnMode()
  testReadOnlySingularNeverFallsBackToPluralSetter()
  testSupportReportContextDiscoveryIsPluralOnlyAndPrivate()
  testSupportReportPluralMultiplicityRequiresUniqueness()
  testIncompatibleUnidentifiedPluralDoesNotBlockValidSingular()
  testCompatibleUnidentifiedPluralIsSuppressedBySingularAuthority()
  testUnidentifiedPluralIsNotUsedWhenSingularIsIncompatible()
  testStatusPreservesRoutingOrderAndUsesSingularCurrentWrapper()
  testSingularOnlyEndpointRemainsDirectlyControllable()
  testStatusReadsCAOnlySingularEndpointWithoutWrites()
  testSingularEmptyModesRetainCurrentModeAndConversationAwarenessControl()
  testCatalogedPluralOnlyEmptyModesIsRejected()
  testCatalogedEmptyPluralDoesNotBlockControllableEmptyModeSingular()
}
