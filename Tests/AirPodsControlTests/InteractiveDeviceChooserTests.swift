import Foundation

func testInteractiveDeviceChooserEligibility() {
  let ineligibleCases = [
    InteractiveDeviceChooser.Eligibility(
      inputIsTerminal: false,
      errorIsTerminal: true,
      jsonOutput: false
    ),
    InteractiveDeviceChooser.Eligibility(
      inputIsTerminal: true,
      errorIsTerminal: false,
      jsonOutput: false
    ),
    InteractiveDeviceChooser.Eligibility(
      inputIsTerminal: true,
      errorIsTerminal: true,
      jsonOutput: true
    ),
  ]

  for eligibility in ineligibleCases {
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

    check(outcome == .cancelled, "an ineligible chooser cancels")
    check(readCount == 0, "an ineligible chooser does not read standard input")
    check(output.isEmpty, "an ineligible chooser does not write a prompt")
  }
}

func testInteractiveDeviceChooserPreservesDiscoveryOrder() {
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
  check(output.hasPrefix(expectedMenu), "device names preserve deterministic discovery order")
  check(outcome == .selected(index: 1), "displayed number maps directly to discovery index")
}

func testInteractiveDeviceChooserRepromptsForOnlyDisplayedNumbers() {
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

  check(outcome == .selected(index: 1), "a displayed number selects its discovery candidate")
  check(
    output.components(separatedBy: "Invalid selection.").count - 1 == 4,
    "zero, out-of-range, noncanonical, and named answers are rejected"
  )
  check(
    output.components(separatedBy: "Select a device").count - 1 == 5,
    "every invalid answer is reprompted"
  )
}

func testInteractiveDeviceChooserCancellation() {
  let eligibility = InteractiveDeviceChooser.Eligibility(
    inputIsTerminal: true,
    errorIsTerminal: true,
    jsonOutput: false
  )
  let cancellations: [String?] = ["", " \t", "q", " Q ", nil]

  for response in cancellations {
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
    check(outcome == .cancelled, "blank, q, and EOF cancel selection")
    check(readCount == 1, "cancellation consumes exactly one response")
  }
}

func testInteractiveDeviceChooserRequiresAmbiguity() {
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

  check(outcome == .cancelled, "a chooser with fewer than two candidates cancels")
  check(readCount == 0, "a nonambiguous chooser does not read")
  check(output.isEmpty, "a nonambiguous chooser does not write")
}

func runInteractiveDeviceChooserTests() {
  testInteractiveDeviceChooserEligibility()
  testInteractiveDeviceChooserPreservesDiscoveryOrder()
  testInteractiveDeviceChooserRepromptsForOnlyDisplayedNumbers()
  testInteractiveDeviceChooserCancellation()
  testInteractiveDeviceChooserRequiresAmbiguity()
}
