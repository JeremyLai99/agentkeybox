import XCTest

@testable import AgentKeyBoxCore

final class ApprovalActivityPresentationTests: XCTestCase {
  override func setUp() {
    super.setUp()
    Localization.setOverride(.english)
  }

  override func tearDown() {
    Localization.setOverride(nil)
    super.tearDown()
  }

  private func request() -> AgentRequest {
    AgentRequest(
      agentID: "fixture", agentDisplayName: "Fixture Agent", projectPath: "/fixture",
      credentialIdentifier: UUID().uuidString)
  }

  private func presentation(
    _ request: AgentRequest?, executing: UUID? = nil, authenticating: Bool = false,
    label: String? = "Demo Key"
  ) -> ApprovalActivityPresentation {
    ApprovalActivityPresentation(
      pendingRequest: request, executingRequestID: executing, decisionInProgress: authenticating,
      credentialLabel: label)
  }

  func testWaitingAndAuthenticatingKeepPromptVisibleUntilExecutionIsReady() {
    let request = request()
    let waiting = presentation(request)
    XCTAssertEqual(waiting.phase, .awaitingApproval)
    XCTAssertTrue(waiting.showsApprovalPrompt)
    XCTAssertFalse(waiting.isExecuting)
    XCTAssertEqual(waiting.statusText, "Fixture Agent wants access")

    let authenticating = presentation(request, authenticating: true)
    XCTAssertEqual(authenticating.phase, .authenticating)
    XCTAssertTrue(authenticating.showsApprovalPrompt)
    XCTAssertFalse(authenticating.isExecuting)
    XCTAssertEqual(authenticating.statusText, waiting.statusText)

    let running = presentation(request, executing: request.id, authenticating: true)
    XCTAssertEqual(running.phase, .executing)
    XCTAssertFalse(running.showsApprovalPrompt)
    XCTAssertTrue(running.isExecuting)
    XCTAssertEqual(running.statusText, "Running: Fixture Agent using Demo Key…")
  }

  func testExecutionIDOnlyHidesItsOwnRequest() {
    let current = request()
    let stale = presentation(current, executing: UUID(), authenticating: true)
    XCTAssertTrue(stale.showsApprovalPrompt)
    XCTAssertEqual(stale.phase, .authenticating)
    XCTAssertEqual(stale.statusText, "Fixture Agent wants access")
  }

  private func assertFinished(file: StaticString = #filePath, line: UInt = #line) {
    // finishPrompt clears pendingRequest first. A stale UI ID must not keep progress alive
    // or re-open a panel during cleanup, regardless of the terminal outcome.
    for executing in [nil, UUID()] {
      for deciding in [false, true] {
        let state = presentation(nil, executing: executing, authenticating: deciding)
        XCTAssertEqual(state.phase, .idle, file: file, line: line)
        XCTAssertFalse(state.showsApprovalPrompt, file: file, line: line)
        XCTAssertFalse(state.isExecuting, file: file, line: line)
        XCTAssertNil(state.statusText, file: file, line: line)
      }
    }
  }

  func testCompletedRequestDoesNotShowPromptOrProgress() { assertFinished() }
  func testDeniedRequestDoesNotShowPromptOrProgress() { assertFinished() }
  func testTimedOutRequestDoesNotShowPromptOrProgress() { assertFinished() }
  func testCancelledRequestDoesNotShowPromptOrProgress() { assertFinished() }

  func testProgressUsesOnlyDisplayNamesForEveryOperation() {
    var request = request()
    request.purpose = "PRIVATE_PURPOSE"
    request.operation = "PRIVATE_OPERATION"
    request.executablePath = "/PRIVATE_PROGRAM"
    request.arguments = ["PRIVATE_ARGUMENT"]
    request.url = "https://example.invalid/?token=PRIVATE_QUERY"
    request.bodyPreview = "PRIVATE_BODY"
    request.headerNames = ["PRIVATE_HEADER"]
    request.environmentVariables = ["PRIVATE_VARIABLE", "PRIVATE_VARIABLE_2"]
    let kinds: [AgentRequestKind] = [
      .command, .httpRequest, .environment, .sensitiveSubmission,
      .browserLogin, .browserFollow, .browserRecovery,
    ]
    for kind in kinds {
      request.kind = kind
      let state = presentation(request, executing: request.id)
      XCTAssertFalse(state.showsApprovalPrompt)
      XCTAssertEqual(state.phase, .executing)
      XCTAssertEqual(
        state.statusText,
        kind == .environment
          ? "Running: Fixture Agent using 2 key(s)…" : "Running: Fixture Agent using Demo Key…")
      XCTAssertFalse(state.statusText?.contains("PRIVATE") ?? true)
    }
  }

  func testProgressNamesAreBoundedAndFlattened() {
    var request = request()
    request.agentDisplayName = "Fixture\nAgent\t\u{00} name"
    let short = presentation(request, executing: request.id, label: "Demo\r\nKey")
    XCTAssertEqual(short.statusText, "Running: Fixture Agent name using Demo Key…")

    request.agentDisplayName = String(repeating: "A", count: 200)
    let long = presentation(
      request, executing: request.id, label: String(repeating: "K", count: 200))
    XCTAssertEqual(
      long.statusText,
      "Running: " + String(repeating: "A", count: 39) + "… using "
        + String(repeating: "K", count: 59) + "……")
  }

  func testMissingItemMetadataStillShowsProgress() {
    let request = request()
    XCTAssertEqual(
      presentation(request, executing: request.id, label: nil).statusText,
      "Running: Fixture Agent using credential…")
  }

  func testTraditionalChineseProgress() {
    Localization.setOverride(.traditionalChinese)
    var request = request()
    XCTAssertEqual(
      presentation(request, executing: request.id).statusText, "正在執行：Fixture Agent 使用 Demo Key…")
    request.kind = .environment
    request.environmentVariables = ["DEMO_KEY"]
    XCTAssertEqual(
      presentation(request, executing: request.id).statusText, "正在執行：Fixture Agent 使用 1 把金鑰…")
  }
}
