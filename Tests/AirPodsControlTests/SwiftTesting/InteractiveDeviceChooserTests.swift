import Foundation
import Testing

@testable import AirPodsControlCore

@Suite("Interactive device chooser")
struct InteractiveDeviceChooserTests {
  @Test(
    "Declines without reading or prompting when interactive input is ineligible",
    arguments: [(false, true, false), (true, false, false), (true, true, true)]
  )
  func declinesIneligibleInput(
    inputIsTerminal: Bool, errorIsTerminal: Bool, jsonOutput: Bool
  ) {
    let eligibility = InteractiveDeviceChooser.Eligibility(
      inputIsTerminal: inputIsTerminal,
      errorIsTerminal: errorIsTerminal,
      jsonOutput: jsonOutput
    )
    var readCount = 0
    var output = ""
    let outcome = InteractiveDeviceChooser.choose(
      deviceNames: ["Desk AirPods", "Travel AirPods"],
      eligibility: eligibility,
      readResponse: {
        readCount += 1
        return "1"
      },
      writeError: { output += $0 }
    )

    #expect(outcome == .declined, "an ineligible chooser is declined")
    #expect(readCount == 0, "an ineligible chooser does not read standard input")
    #expect(output.isEmpty, "an ineligible chooser does not write a prompt")
  }

  @Test("Preserves discovery order and selection indexes")
  func interactiveDeviceChooserPreservesDiscoveryOrder() {
    let eligibility = InteractiveDeviceChooser.Eligibility(
      inputIsTerminal: true,
      errorIsTerminal: true,
      jsonOutput: false
    )
    var output = ""
    let outcome = InteractiveDeviceChooser.choose(
      deviceNames: ["Zulu AirPods", "alpha AirPods", "Beats Studio"],
      eligibility: eligibility,
      readResponse: { "2" },
      writeError: { output += $0 }
    )

    let expectedMenu = """
      Multiple compatible devices are connected:
        1. Zulu AirPods
        2. alpha AirPods
        3. Beats Studio

      """
    #expect(output.hasPrefix(expectedMenu), "device names preserve deterministic discovery order")
    #expect(outcome == .selected(index: 1), "displayed number maps directly to discovery index")
  }

  @Test("Escapes terminal controls without changing selection")
  func interactiveDeviceChooserEscapesUnsafeDeviceNames() {
    let eligibility = InteractiveDeviceChooser.Eligibility(
      inputIsTerminal: true,
      errorIsTerminal: true,
      jsonOutput: false
    )
    let unsafeName = "Café 🎧\n\r\t\\\u{001B}\u{007F}\u{2028}\u{2029}"
    var output = ""
    let outcome = InteractiveDeviceChooser.choose(
      deviceNames: ["Desk AirPods", unsafeName],
      eligibility: eligibility,
      readResponse: { "2" },
      writeError: { output += $0 }
    )

    let expectedOutput =
      "Multiple compatible devices are connected:\n"
      + "  1. Desk AirPods\n"
      + "  2. Café 🎧\\n\\r\\t\\\\\\u{001B}\\u{007F}\\u{2028}\\u{2029}\n"
      + "Select a device [1-2] (blank or q declines): "
    #expect(
      output == expectedOutput,
      "chooser escapes record-breaking and terminal control characters"
    )
    #expect(outcome == .selected(index: 1), "escaping does not change the selected candidate index")
  }

  @Test("Escapes bidirectional controls without changing selection")
  func interactiveDeviceChooserEscapesBidirectionalControls() {
    let eligibility = InteractiveDeviceChooser.Eligibility(
      inputIsTerminal: true,
      errorIsTerminal: true,
      jsonOutput: false
    )
    let unsafeName =
      "AirPods\u{061C}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"
      + "\u{2066}\u{2067}\u{2068}\u{2069} Pro"
    var output = ""
    let outcome = InteractiveDeviceChooser.choose(
      deviceNames: ["Desk AirPods", unsafeName],
      eligibility: eligibility,
      readResponse: { "2" },
      writeError: { output += $0 }
    )

    let expectedName =
      "AirPods\\u{061C}\\u{200E}\\u{200F}\\u{202A}\\u{202B}\\u{202C}\\u{202D}\\u{202E}"
      + "\\u{2066}\\u{2067}\\u{2068}\\u{2069} Pro"
    #expect(output.contains("  2. \(expectedName)\n"), "chooser escapes bidirectional controls")
    #expect(outcome == .selected(index: 1), "escaping preserves the selected candidate index")
  }

  @Test("Reprompts until a displayed number is entered")
  func interactiveDeviceChooserRepromptsForOnlyDisplayedNumbers() {
    let eligibility = InteractiveDeviceChooser.Eligibility(
      inputIsTerminal: true,
      errorIsTerminal: true,
      jsonOutput: false
    )
    var responses: [String?] = ["0", "3", "01", "Desk AirPods", " 2 \n"]
    var output = ""
    let outcome = InteractiveDeviceChooser.choose(
      deviceNames: ["Travel AirPods", "Desk AirPods"],
      eligibility: eligibility,
      readResponse: { responses.removeFirst() },
      writeError: { output += $0 }
    )

    #expect(outcome == .selected(index: 1), "a displayed number selects its discovery candidate")
    #expect(
      output.components(separatedBy: "Invalid selection.").count - 1 == 4,
      "zero, out-of-range, noncanonical, and named answers are rejected"
    )
    #expect(
      output.components(separatedBy: "Select a device").count - 1 == 5,
      "every invalid answer is reprompted"
    )
  }

  @Test(
    "Declines after exactly one blank, quit, or EOF response",
    arguments: ["", " \t", "q", " Q ", nil] as [String?]
  )
  func declinesSelection(response: String?) {
    let eligibility = InteractiveDeviceChooser.Eligibility(
      inputIsTerminal: true,
      errorIsTerminal: true,
      jsonOutput: false
    )

    var readCount = 0
    let outcome = InteractiveDeviceChooser.choose(
      deviceNames: ["Desk AirPods", "Travel AirPods"],
      eligibility: eligibility,
      readResponse: {
        readCount += 1
        return response
      },
      writeError: { _ in }
    )
    #expect(outcome == .declined, "blank, q, and EOF decline selection")
    #expect(readCount == 1, "declining consumes exactly one response")
  }

  @Test("Does not prompt or read for an unambiguous device")
  func interactiveDeviceChooserRequiresAmbiguity() {
    let eligibility = InteractiveDeviceChooser.Eligibility(
      inputIsTerminal: true,
      errorIsTerminal: true,
      jsonOutput: false
    )
    var readCount = 0
    var output = ""
    let outcome = InteractiveDeviceChooser.choose(
      deviceNames: ["Only AirPods"],
      eligibility: eligibility,
      readResponse: {
        readCount += 1
        return "1"
      },
      writeError: { output += $0 }
    )

    #expect(outcome == .declined, "a chooser with fewer than two candidates declines")
    #expect(readCount == 0, "a nonambiguous chooser does not read")
    #expect(output.isEmpty, "a nonambiguous chooser does not write")
  }
}
