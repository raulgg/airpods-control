import Foundation

enum InteractiveDeviceChooser {
  struct Eligibility {
    let inputIsTerminal: Bool
    let errorIsTerminal: Bool
    let jsonOutput: Bool

    fileprivate var allowsPrompt: Bool {
      inputIsTerminal && errorIsTerminal && !jsonOutput
    }
  }

  enum Outcome: Equatable {
    // Discovery order is display order, so the selected displayed number maps
    // directly back to the caller's deviceNames array.
    case selected(index: Int)
    case cancelled
  }

  static func choose(
    deviceNames: [String],
    eligibility: Eligibility,
    readResponse: () -> String?,
    writeError: (String) -> Void
  ) -> Outcome {
    guard eligibility.allowsPrompt, deviceNames.count > 1 else {
      return .cancelled
    }

    var menu = "Multiple compatible devices are connected:\n"
    for (displayIndex, deviceName) in deviceNames.enumerated() {
      menu += "  \(displayIndex + 1). \(SafeTerminalText.escaped(deviceName))\n"
    }
    writeError(menu)

    while true {
      writeError(
        "Select a device [1-\(deviceNames.count)] "
          + "(blank or q cancels): "
      )

      guard let rawResponse = readResponse() else {
        writeError("\n")
        return .cancelled
      }

      let response = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
      if response.isEmpty || response.lowercased() == "q" {
        return .cancelled
      }

      if let displayIndex = deviceNames.indices.first(
        where: { String($0 + 1) == response }
      ) {
        return .selected(index: displayIndex)
      }

      writeError(
        "Invalid selection. Enter one of the displayed numbers, "
          + "or q to cancel.\n"
      )
    }
  }
}
