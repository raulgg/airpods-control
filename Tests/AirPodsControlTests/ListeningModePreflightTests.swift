import Testing

@testable import AirPodsControlCore

@Suite("Listening mode preflight policy")
struct ListeningModePreflightTests {
  @Test("Normalizes availability, Off permission, cache eligibility, and cycles")
  func preflightPolicyForAvailabilityOffPermissionAndCycles() {
    let advertised: [ListeningMode] = [.noiseCancellation, .off, .transparency]
    let canonical: [ListeningMode] = [.off, .transparency, .noiseCancellation]
    #expect(
      ListeningModePreflightPolicy.normalizedModes(from: .value(advertised)) == canonical,
      "complete availability uses canonical output order"
    )
    #expect(
      ListeningModePreflightPolicy.normalizedModes(from: .partial(advertised)) == canonical,
      "partial availability retains recognized modes"
    )
    #expect(
      ListeningModePreflightPolicy.normalizedModes(from: .unavailable).isEmpty
        && ListeningModePreflightPolicy.normalizedModes(from: .readError).isEmpty,
      "unavailable and read-error availability expose no modes"
    )

    let avOmission = ListeningModeAvailabilityObservation.value([.transparency, .adaptive])
    #expect(
      ListeningModePreflightPolicy.availabilityBlocksCachedAllowOff(
        avOmission,
        transportKind: .av,
        command: .list
      ),
      "an AV complete Off omission blocks cached list evidence"
    )
    #expect(
      !ListeningModePreflightPolicy.availabilityBlocksCachedAllowOff(
        .value([.off, .transparency]),
        transportKind: .av,
        command: .list
      ),
      "an advertised Off does not block cached list evidence"
    )
    #expect(
      !ListeningModePreflightPolicy.availabilityBlocksCachedAllowOff(
        .partial([.transparency, .adaptive]),
        transportKind: .av,
        command: .list
      )
        && !ListeningModePreflightPolicy.availabilityBlocksCachedAllowOff(
          avOmission,
          transportKind: .hal,
          command: .list
        )
        && !ListeningModePreflightPolicy.availabilityBlocksCachedAllowOff(
          avOmission,
          transportKind: .av,
          command: .set(.adaptive)
        )
        && !ListeningModePreflightPolicy.availabilityBlocksCachedAllowOff(
          avOmission,
          transportKind: .av,
          command: .cycle(nil)
        ),
      "partial AV, HAL, non-Off set, and the default cycle leave cache evidence unblocked"
    )
    #expect(
      ListeningModePreflightPolicy.availabilityBlocksCachedAllowOff(
        avOmission,
        transportKind: .av,
        command: .set(.off)
      )
        && ListeningModePreflightPolicy.availabilityBlocksCachedAllowOff(
          avOmission,
          transportKind: .av,
          command: .cycle([.transparency, .off])
        ),
      "explicit Off set and cycle still honor the AV complete-omission block"
    )

    let available: [ListeningMode] = [.transparency, .adaptive]
    let withOff: [ListeningMode] = [.off, .transparency, .adaptive]
    #expect(
      ListeningModePreflightPolicy.effectiveModes(
        availableModes: available,
        offPermission: nil
      ) == available,
      "unknown Off permission leaves Off excluded"
    )
    #expect(
      ListeningModePreflightPolicy.effectiveModes(
        availableModes: available,
        offPermission: .probe
      ) == withOff
        && ListeningModePreflightPolicy.effectiveModes(
          availableModes: available,
          offPermission: .authorized(.live(cache: nil, record: nil))
        ) == withOff,
      "probe and authorization permissions add Off"
    )
    #expect(
      ListeningModePreflightPolicy.effectiveModes(
        availableModes: withOff,
        offPermission: .probe
      ) == withOff,
      "advertised Off is not duplicated or reordered"
    )
    #expect(
      ListeningModePreflightPolicy.effectiveModes(
        availableModes: [],
        offPermission: .authorized(.live(cache: nil, record: nil))
      ) == [.off],
      "a permission offers Off even when nothing else is advertised"
    )

    let allModes = ListeningMode.allCases
    #expect(
      ListeningModeCyclePolicy.supportedModes(requested: nil, available: allModes)
        == [.transparency, .adaptive, .noiseCancellation],
      "the default cycle excludes Off"
    )
    #expect(
      ListeningModeCyclePolicy.supportedModes(
        requested: [.noiseCancellation, .off, .transparency],
        available: allModes
      ) == [.noiseCancellation, .off, .transparency],
      "an explicit cycle preserves its requested order"
    )
    #expect(
      ListeningModeCyclePolicy.supportedModes(
        requested: [.noiseCancellation, .off, .transparency],
        available: [.off, .transparency]
      ) == [.off, .transparency],
      "unsupported explicit modes are filtered in place"
    )

    #expect(
      !ListeningModePreflightPolicy.commandExplicitlyTargetsOff(.list)
        && ListeningModePreflightPolicy.commandMayUseAllowOffCache(.list),
      "list surfaces cached Allow Off evidence without opting into a probe"
    )
    #expect(
      ListeningModePreflightPolicy.commandExplicitlyTargetsOff(.set(.off))
        && ListeningModePreflightPolicy.commandMayUseAllowOffCache(.set(.off))
        && ListeningModePreflightPolicy.commandExplicitlyTargetsOff(
          .cycle([.transparency, .off])
        )
        && ListeningModePreflightPolicy.commandMayUseAllowOffCache(
          .cycle([.transparency, .off])
        ),
      "explicit Off set and cycle both target Off and may use cache evidence"
    )
    #expect(
      !ListeningModePreflightPolicy.commandExplicitlyTargetsOff(.set(.adaptive))
        && !ListeningModePreflightPolicy.commandMayUseAllowOffCache(.set(.adaptive))
        && !ListeningModePreflightPolicy.commandExplicitlyTargetsOff(.get)
        && !ListeningModePreflightPolicy.commandMayUseAllowOffCache(.get)
        && !ListeningModePreflightPolicy.commandExplicitlyTargetsOff(.cycle(nil))
        && !ListeningModePreflightPolicy.commandMayUseAllowOffCache(.cycle(nil)),
      "non-Off set, get, and the default cycle neither target Off nor use cache evidence"
    )
  }
}
