# Swift Testing migration ledger

This ledger tracks the move from the custom Swift test runner to Swift Testing.
For each Swift group:

- move its tests to the SwiftPM test target;
- remove its call from `TestRunner` in the same change;
- preserve explicit privacy and no-write assertions; and
- run `make clean && make test` before marking it migrated.

The migration is complete only when every Swift group is migrated and the
non-Swift contracts still run under `make test`.

## Legacy Swift groups

- [ ] `runCLIParsingTests` (`CLIParsingTests.swift`)
- [ ] `runInteractiveDeviceChooserTests`
  (`InteractiveDeviceChooserTests.swift`)
- [ ] `runListeningModeTests` (`ListeningModeTests.swift`)
- [ ] `runListeningModeAllowOffCacheTests`
  (`ListeningModeAllowOffCacheTests.swift`)
- [ ] `runListeningModeCoordinatorTests`
  (`ListeningModeCoordinatorTests.swift`)
- [ ] `runCommandExecutionTests` (`CommandExecutionTests.swift`)
- [ ] `runPrivateAudioDiscoveryTests` (`PrivateAudioDiscoveryTests.swift`)
- [ ] `runCoreAudioListeningModePropertyTests`
  (`CoreAudioListeningModePropertyTests.swift`)
- [ ] `runCoreAudioInEarPlacementPropertyTests`
  (`CoreAudioInEarPlacementPropertyTests.swift`)
- [ ] `runHALListeningModeCandidateTests`
  (`HALListeningModeCandidateTests.swift`)
- [ ] `runAudioRoutingTests` (`AudioRoutingTests.swift`)
- [ ] `runStatusCommandTests` (`StatusCommandTests.swift`)
- [ ] `runPrivateAudioTests` (`PrivateAudioTests.swift`)
- [ ] `runAppleAudioProductsTests` (`AppleAudioProductsTests.swift`)
- [ ] `runSupportReportTests` (`SupportReportTests.swift`)
- [ ] `runSupportReportWriteFlowTests` (`SupportReportWriteFlowTests.swift`)
- [ ] `runSupportReportWriteTesterTests`
  (`SupportReportWriteTesterTests.swift`)
- [ ] `runSupportReportProgressTests` (`SupportReportProgressTests.swift`)

## Contracts that remain outside Swift Testing

Keep these checks in `make test` throughout the migration:

- `Tests/ReleasePleaseTests/release-pr-body.sh` checks release pull request
  body parsing.
- `Tests/ResolvePrefixTests/resolve-prefix.sh` checks install-prefix rules.
- `Tests/InstallFromSourceTests/install-from-source.sh` checks source install
  behavior.
- `Tests/CLIContractTests/cli.sh` checks the built executable's output, exit
  codes, version, and read-only command behavior.
- `Tests/SignalMonitorTests/signal_monitor_race_test.c` checks cross-thread
  signal teardown directly in C.

`verify-runtime`, `verify-catalog`, and hardware checks stay outside
`make test` because they depend on the host or connected devices.
