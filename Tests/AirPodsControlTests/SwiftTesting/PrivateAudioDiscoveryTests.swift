import Foundation
import Testing

@testable import AirPodsControlCore

@Suite("Private audio discovery")
struct PrivateAudioDiscoveryTests {
  @Test
  func privateContextSelectorDiscovery() throws {
    let logger = DebugLogger(enabled: false)
    let modern = FakeContext(devices: [])
    let legacy = FakeContext(devices: [])
  
    let legacyProvider = FakeLegacyContextProvider(context: legacy)
    #expect(
      PrivateAudioDiscovery.sharedContext(from: legacyProvider, logger: logger) === legacy,
      "legacy sharedSystemAudio selector is supported"
    )
  
    let dualProvider = FakeDualContextProvider(modern: modern, legacy: legacy)
    #expect(
      PrivateAudioDiscovery.sharedContext(from: dualProvider, logger: logger) === modern,
      "modern context selector is preferred"
    )
  
    let missingProvider = NSObject()
    #expect(
      PrivateAudioDiscovery.sharedContext(from: missingProvider, logger: logger) == nil,
      "missing context selectors return nil"
    )
    #expect(
      PrivateAudioDiscovery.outputDevices(from: missingProvider, logger: logger) == nil,
      "missing outputDevices selector returns nil"
    )
    #expect(
      PrivateAudioDiscovery.outputDevice(from: missingProvider, logger: logger) == nil,
      "missing outputDevice selector returns nil"
    )
  
    let device = FakeRawDevice(name: "My AirPods Pro")
    let context = FakeContext(devices: [device], currentDevice: device)
    #expect(
      PrivateAudioDiscovery.outputDevices(from: context, logger: logger)?.first === device,
      "plural outputDevices is discovered safely"
    )
    #expect(
      PrivateAudioDiscovery.outputDevice(from: context, logger: logger) === device,
      "singular outputDevice is discovered independently"
    )
  }
  
  @Test
  func contextEndpointsPreservePluralOrderAndMultiplicity() throws {
    let first = FakeRawDevice(name: "First AirPods")
    let second = FakeRawDevice(name: "Second AirPods")
    let context = FakeContext(devices: [first, second, first], currentDevice: second)
  
    let endpoints = PrivateAudioDiscovery.contextEndpoints(
      from: context,
      logger: DebugLogger(enabled: false)
    )
  
    #expect(endpoints.plural.count == 3, "plural endpoint multiplicity is preserved")
    #expect(
      endpoints.plural[0] === first
        && endpoints.plural[1] === second
        && endpoints.plural[2] === first,
      "plural endpoint order is preserved exactly"
    )
    #expect(endpoints.singular === second, "the singular current endpoint is retained separately")
  }
  
  @Test
  func sameIdentifierSingularAuthorityRejectsWithdrawnMode() throws {
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
  
    #expect(
      selected?.availableListeningModes() == [.transparency],
      "the singular current endpoint governs advertised eligibility"
    )
    let outcome = CommandExecution.execute(try parseInvocation(["lm", "set", "anc"])) {
      _, _ in selected
    }
    #expect(
      outcome.plain == "unsupported",
      "a mode withdrawn by the singular endpoint is unsupported"
    )
    #expect(
      singular.listeningModeSetCount == 0 && plural.listeningModeSetCount == 0,
      "a withdrawn mode reaches neither singular nor stale plural setter"
    )
  }
  
  @Test
  func readOnlySingularNeverFallsBackToPluralSetter() throws {
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
  
    #expect(selected?.name == "Current AirPods", "the read-only singular wrapper stays authoritative")
    #expect(
      selected?.canSetListeningMode() == false,
      "the singular wrapper's missing setter is honored"
    )
    let outcome = CommandExecution.execute(try parseInvocation(["lm", "set", "adaptive"])) {
      _, _ in selected
    }
    #expect(outcome.plain == "unavailable", "a read-only singular endpoint reports unavailable")
    #expect(plural.listeningModeSetCount == 0, "the stale plural setter is never used as fallback")
  }
  
  @Test
  func supportReportContextDiscoveryIsPluralOnlyAndPrivate() throws {
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
  
    #expect(selected != nil, "support-report selects one compatible plural endpoint")
    #expect(context.outputDeviceReadCount == 0, "support-report never reads singular outputDevice")
    #expect(
      plural.nameReadCount == 0 && singular.nameReadCount == 0,
      "support-report reads no customizable endpoint names"
    )
    #expect(
      plural.deviceIDReadCount == 0 && singular.deviceIDReadCount == 0,
      "support-report reads no private endpoint identifiers"
    )
  }
  
  @Test
  func supportReportPluralMultiplicityRequiresUniqueness() throws {
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
  
    #expect(selected == nil, "support-report requires one unique compatible plural endpoint")
    #expect(context.outputDeviceReadCount == 0, "plural uniqueness does not enter singular discovery")
    #expect(
      repeated.nameReadCount == 0 && repeated.deviceIDReadCount == 0,
      "plural uniqueness remains name- and identifier-free"
    )
    #expect(
      singular.nameReadCount == 0 && singular.deviceIDReadCount == 0,
      "the unused singular endpoint remains completely unread"
    )
  }
  
  @Test
  func incompatibleUnidentifiedPluralDoesNotBlockValidSingular() throws {
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
      Issue.record("a filtered no-ID plural does not hide the valid singular endpoint")
      return
    }
  
    let observation = selected.setListeningModeAndReadBack(.adaptive, wait: { _ in })
    #expect(observation.observed == .adaptive, "the valid no-ID singular endpoint remains writable")
    #expect(singular.listeningModeSetCount == 1, "the write reaches the singular endpoint")
    #expect(
      singular.deviceIDReadCount == 0,
      "a filtered plural requires no speculative singular identifier read"
    )
  }
  
  @Test
  func compatibleUnidentifiedPluralIsSuppressedBySingularAuthority() throws {
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
  
    #expect(resolved?.count == 1, "unresolved plural aliases produce one current status record")
    #expect(selected?.name == "Current AirPods", "the singular endpoint wins unresolved alias risk")
    let observation = selected?.setListeningModeAndReadBack(.adaptive, wait: { _ in })
    #expect(observation?.observed == .adaptive, "the authoritative singular endpoint is writable")
    #expect(
      singular.listeningModeSetCount == 1
        && firstPlural.listeningModeSetCount == 0
        && secondPlural.listeningModeSetCount == 0,
      "unidentified plural wrappers never receive the write"
    )
  }
  
  @Test
  func unidentifiedPluralIsNotUsedWhenSingularIsIncompatible() throws {
    let plural = FakeRawDevice(name: "Stale AirPods", deviceIdentifier: "")
    let selected = PrivateAudioController(
      endpoints: PrivateAudioContextEndpoints(
        plural: [plural],
        singular: FakeIncompleteRawDevice()
      ),
      logger: DebugLogger(enabled: false)
    ).selectDevice(named: nil)
  
    #expect(selected == nil, "unresolved plural identity fails closed without a valid singular")
    #expect(plural.listeningModeSetCount == 0, "a stale unidentified plural receives no write")
  }
  
  @Test
  func statusPreservesRoutingOrderAndUsesSingularCurrentWrapper() throws {
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
      Issue.record("status resolves the combined routing endpoints")
      return
    }
  
    #expect(
      devices.map(\.name) == ["First AirPods", "Current AirPods", "Last Beats"],
      "status keeps routing order while replacing the current plural alias"
    )
    #expect(
      devices.count == 3
        && devices[0].object === first
        && devices[1].object === singular
        && devices[2].object === last,
      "status reads the singular wrapper once at the plural alias position"
    )
    let outcome = StatusCommand.outcome(devices: devices)
    let records = outcome.payload["devices"] as? [[String: Any]]
    #expect(
      records?[1]["listeningMode"] as? String == "transparency",
      "status reports the singular current capability snapshot"
    )
    #expect(
      pluralCurrent.listeningModeSetCount == 0 && singular.listeningModeSetCount == 0,
      "aggregate status never invokes either wrapper's setter"
    )
  }
  
  @Test
  func singularOnlyEndpointRemainsDirectlyControllable() throws {
    let singular = FakeRawDevice(name: "Singular AirPods")
    guard let selected = PrivateAudioController(
      endpoints: PrivateAudioContextEndpoints(plural: [], singular: singular),
      logger: DebugLogger(enabled: false)
    ).selectDevice(named: nil) else {
      Issue.record("the singular current endpoint survives an empty plural list")
      return
    }
  
    let modeWrite = selected.setListeningModeAndReadBack(.adaptive, wait: { _ in })
    #expect(modeWrite.observed == .adaptive, "singular listening-mode control remains direct")
    let awarenessWrite = selected.setConversationAwarenessAndReadBack(true, wait: { _ in })
    #expect(awarenessWrite.observed == true, "singular Conversation Awareness control remains direct")
    #expect(
      singular.listeningModeSetCount == 1 && singular.conversationAwarenessSetCount == 1,
      "both settings are written through the singular endpoint"
    )
  }
  
  @Test
  func statusReadsCAOnlySingularEndpointWithoutWrites() throws {
    let singular = FakeCAOnlyCurrentRawDevice()
    let controller = PrivateAudioController(
      endpoints: PrivateAudioContextEndpoints(plural: [], singular: singular),
      logger: DebugLogger(enabled: false)
    )
    guard let devices = controller.selectDevices(named: nil, policy: .allOrExact) else {
      Issue.record("status discovers the CA-only singular current endpoint")
      return
    }
  
    let outcome = StatusCommand.outcome(devices: devices)
    let record = (outcome.payload["devices"] as? [[String: Any]])?.first
    #expect(record?["conversationAwareness"] as? String == "off", "status reads singular CA")
    #expect(record?["listeningMode"] is NSNull, "the missing singular mode read remains null")
    #expect(
      (record?["errors"] as? [String: String]) == ["listeningMode": "read-error"],
      "status records the singular listening-mode read error"
    )
    #expect(
      singular.conversationAwarenessSetCount == 0,
      "status never writes the CA-only singular endpoint"
    )
  }
  
  @Test
  func singularEmptyModesRetainCurrentModeAndConversationAwarenessControl() throws {
    let singular = FakeRawDevice(name: "One-bud AirPods", modes: [])
    let selected = PrivateAudioController(
      endpoints: PrivateAudioContextEndpoints(plural: [], singular: singular),
      logger: DebugLogger(enabled: false)
    ).selectDevice(named: nil)
  
    #expect(selected != nil, "a singular endpoint with a live control signal survives empty modes")
    #expect(selected?.availableListeningModes().isEmpty == true, "empty modes remain truthful")
    let modeGet = CommandExecution.execute(try parseInvocation(["lm", "get"])) {
      _, _ in selected
    }
    #expect(
      modeGet.plain == "transparency",
      "the current listening mode remains readable while modes are empty"
    )
    let modeSet = CommandExecution.execute(try parseInvocation(["lm", "set", "adaptive"])) {
      _, _ in selected
    }
    #expect(modeSet.plain == "unsupported", "an unadvertised listening mode remains unsupported")
    #expect(singular.listeningModeSetCount == 0, "empty modes cannot bypass command eligibility")
  
    _ = CommandExecution.execute(try parseInvocation(["ca", "set", "on"])) {
      _, _ in selected
    }
    #expect(
      singular.conversationAwarenessSetCount == 1,
      "Conversation Awareness writes through the singular endpoint"
    )
  }
  
  @Test
  func catalogedPluralOnlyEmptyModesIsRejected() throws {
    let catalogedPlural = FakeReadOnlyRawDevice(
      name: "Cataloged stale AirPods",
      modes: [],
      modelIdentifier: "BTHeadphones76,8231"
    )
    let selected = PrivateAudioController(
      rawDevices: [catalogedPlural],
      logger: DebugLogger(enabled: false)
    ).selectDevice(named: nil)
  
    #expect(selected == nil, "product catalog membership never proves runtime control capability")
  }
  
  @Test
  func catalogedEmptyPluralDoesNotBlockControllableEmptyModeSingular() throws {
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
  
    #expect(selected?.object === singular, "the controllable singular endpoint is selected")
    let observation = selected?.setConversationAwarenessAndReadBack(true, wait: { _ in })
    #expect(observation?.observed == true, "the empty-mode singular keeps direct CA control")
    #expect(
      singular.conversationAwarenessSetCount == 1,
      "the cataloged non-controllable plural never shadows the singular setter"
    )
  }
  
  
}
