import Foundation

struct SupportReportIssueDraft {
  let title: String
  let report: String
}

enum SupportReportIssue {
  static let repositoryIssuesURL =
    URL(string: "https://github.com/raulgg/airpods-control/issues/new")!
  // The empty form, with no prefilled fields. Printed when the CLI cannot
  // identify the device, and the fallback when composition fails.
  static let formURL = URL(
    string: "https://github.com/raulgg/airpods-control/issues/new"
      + "?template=compatibility-report.yml"
  )!
  static let templateName = "compatibility-report.yml"
  static let reportFieldID = "report"
  static let maximumPrefilledURLLength = 6_000

  static func url(
    for draft: SupportReportIssueDraft,
    includeReport: Bool
  ) -> URL? {
    var components = URLComponents(
      url: repositoryIssuesURL,
      resolvingAgainstBaseURL: false
    )
    var queryItems = [
      URLQueryItem(name: "template", value: templateName),
      URLQueryItem(name: "title", value: draft.title),
    ]
    if includeReport {
      queryItems.append(URLQueryItem(name: reportFieldID, value: draft.report))
    }
    components?.queryItems = queryItems
    let encodedQuery = components?.percentEncodedQuery
    components?.percentEncodedQuery = encodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    return components?.url
  }

  static func safeURL(for draft: SupportReportIssueDraft) -> (url: URL, prefilled: Bool) {
    if let prefilled = url(for: draft, includeReport: true),
       prefilled.absoluteString.count <= maximumPrefilledURLLength
    {
      return (prefilled, true)
    }
    return (url(for: draft, includeReport: false) ?? formURL, false)
  }
}
