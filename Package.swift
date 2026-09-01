// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "airpods-control-tests",
  platforms: [.macOS(.v14)],
  targets: [
    .target(
      name: "SignalMonitor",
      path: "Sources/SignalMonitor",
      publicHeadersPath: "include"
    ),
    .target(
      name: "AirPodsControlCore",
      dependencies: ["SignalMonitor"],
      path: "Sources/AirPodsControl",
      exclude: ["main.swift"],
      linkerSettings: [
        .linkedFramework("CoreAudio"),
        .linkedFramework("Security"),
      ]
    ),
    .testTarget(
      name: "AirPodsControlTests",
      dependencies: ["AirPodsControlCore"],
      path: "Tests/AirPodsControlSwiftTests"
    ),
  ],
  swiftLanguageModes: [.v5]
)
