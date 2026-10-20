@testable import CameraAccess
import XCTest
import UIKit

@MainActor
final class ClaudePipelineTests: XCTestCase {
  func testUnclearPhotoDoesNotBlockCombinedQuestionAndMissingPartGetsReviewCard() async throws {
    let inventory = QuestionInventory(title: "Overlapping views", pages: [
      PageReading(page: 1, readable: false, issue: "Distant wide shot"),
      PageReading(page: 2, readable: true, issue: ""),
      PageReading(page: 3, readable: false, issue: "Blurred duplicate")
    ], questions: [
      InventoriedQuestion(id: "q1", label: "1(a)", sourcePages: [1, 2], problem: "2x = 8", missingInformation: ""),
      InventoriedQuestion(id: "q2", label: "1(b)", sourcePages: [1], problem: "Calculate y; coefficient unreadable",
        missingInformation: "Coefficient of y is unreadable in every view.")
    ])
    let transport = OrganizedPhotoTransport(inventory: inventory)
    let result = try await BatchSolver(transport: transport).solve(pages: [photo(), photo(), photo()],
      configuration: SolverConfiguration(mode: .both, openAIKey: "unused-openai", claudeKey: "claude-fixture"), progress: { _ in })
    XCTAssertEqual(result.problems.map(\.label), ["1(a)", "1(b)"])
    XCTAssertEqual(result.problems[0].sourcePages, [1, 2])
    XCTAssertEqual(result.problems[0].answer, "x = 4")
    XCTAssertEqual(result.problems[1].answer, "Insufficient information")
    XCTAssertTrue(result.problems[1].reviewNote?.contains("Coefficient of y") == true)
    XCTAssertTrue(result.readable)
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 2, "One inventory and one solve; unresolved item is rendered without another paid call.")
    XCTAssertTrue(requests.allSatisfy { $0.credential.provider == .claude && $0.credential.key == "claude-fixture" })
    XCTAssertEqual(requests.last?.photos.map(\.number), [1, 2], "Keep wide-shot context and close-up; do not resend unrelated blur.")
  }

  func testCompletelyUnreadablePacketProducesLabeledReviewOutputWithoutInventingQuestions() async throws {
    let inventory = QuestionInventory(title: "Unreadable packet", pages: [
      PageReading(page: 1, readable: false, issue: "Text is motion blurred"),
      PageReading(page: 2, readable: false, issue: "No visible question")
    ], questions: [])
    let transport = OrganizedPhotoTransport(inventory: inventory)
    let result = try await BatchSolver(transport: transport).solve(pages: [photo(), photo()],
      configuration: SolverConfiguration(claudeKey: "fixture"), progress: { _ in })
    XCTAssertEqual(result.problems.map(\.label), ["Photo 1", "Photo 2"])
    XCTAssertTrue(result.problems.allSatisfy { $0.steps.isEmpty && $0.answer == "Question unreadable" })
    XCTAssertTrue(result.problems.allSatisfy { $0.reviewNote?.hasPrefix("NEEDS REVIEW:") == true })
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1, "Do not waste a solving request when there is no recoverable question.")
  }

  func testExactOverlappingQuestionsMergeSupportingPhotosWithoutDroppingDistinctSubparts() {
    let merged = BatchSolver.mergingExactRepeats([
      InventoriedQuestion(id: "q1", label: "2(a)", sourcePages: [1], problem: "2x = 8"),
      InventoriedQuestion(id: "q2", label: "2(a)", sourcePages: [2, 1], problem: "2x = 8"),
      InventoriedQuestion(id: "q3", label: "2(b)", sourcePages: [2], problem: "2x = 8"),
      InventoriedQuestion(id: "q4", label: "2(a)", sourcePages: [3], problem: "3x = 9")
    ])
    XCTAssertEqual(merged.count, 3)
    XCTAssertEqual(merged[0].id, "q1")
    XCTAssertEqual(merged[0].sourcePages, [1, 2])
    XCTAssertEqual(merged.map(\.id), ["q1", "q3", "q4"])
  }

  func testAnswerGroupsRunTwoAtATimeKeepOrderAndUseSupportingPhotos() async throws {
    let transport = OrganizedPhotoTransport(inventory: groupInventory(), delay: .milliseconds(40))
    let result = try await BatchSolver(transport: transport).solve(pages: [photo(), photo(), photo()],
      configuration: SolverConfiguration(claudeKey: "fixture"), progress: { _ in })
    XCTAssertEqual(result.problems.map(\.label), (1...13).map { "\($0)(a)" })
    let requests = await transport.requests
    let maximum = await transport.maximumInFlight
    XCTAssertEqual(maximum, 2)
    XCTAssertEqual(requests.count, 4, "One inventory + three six-part groups; no second prose-heavy review round.")
    let solvePhotos = requests.dropFirst().map { $0.photos.map(\.number) }.sorted { $0[0] < $1[0] }
    XCTAssertEqual(solvePhotos, [[1], [2], [3]])
  }

  func testCancellationStopsQueuedGroups() async throws {
    let transport = OrganizedPhotoTransport(inventory: groupInventory(), delay: .seconds(10))
    let solver = BatchSolver(transport: transport), jpeg = photo()
    let task = Task {
      try await solver.solve(pages: [jpeg, jpeg, jpeg], configuration: SolverConfiguration(claudeKey: "fixture"), progress: { _ in })
    }
    for _ in 0..<200 {
      if await transport.answerCalls == 2 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let started = await transport.answerCalls
    XCTAssertEqual(started, 2)
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancelled work must not return an export.") }
    catch { XCTAssertTrue(error is CancellationError) }
    let calls = await transport.answerCalls
    XCTAssertEqual(calls, 2, "The third group must never start after cancellation.")
  }

  func testPhotoQualityIsAdvisoryButInventoryAndAnswerCoverageRemainStrict() throws {
    let question = InventoriedQuestion(id: "q1", label: "1(a)", sourcePages: [1], problem: "x = ?")
    let inventory = QuestionInventory(title: "Partial", pages: [PageReading(page: 1, readable: false, issue: "Blur")], questions: [question])
    XCTAssertNoThrow(try inventory.validate(pageCount: 1))
    XCTAssertThrowsError(try inventory.validate(pageCount: 2))
    let direct = WorkedAnswer(id: "q1", steps: [], answer: "4", check: "Verified", status: "solved", reviewNote: "")
    XCTAssertNoThrow(try AnswerSet(answers: [direct]).validate(ids: ["q1"]))
    XCTAssertThrowsError(try AnswerSet(answers: [direct]).validate(ids: ["q1", "q2"]))
    let unknown = WorkedAnswer(id: "q1", steps: [], answer: "Unavailable", check: "Missing data", status: "insufficient_information", reviewNote: "")
    XCTAssertThrowsError(try AnswerSet(answers: [unknown]).validate(ids: ["q1"]), "A missing answer must say what is missing.")
  }

  func testTransientHTTPFailuresRetryAndUseServerDelay() async throws {
    RetryURLProtocol.state.reset([
      .init(status: 429, headers: ["retry-after": "0"], data: Data()),
      .init(status: 529, headers: [:], data: Data()),
      .init(status: 200, headers: [:], data: Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"{\"answers\":[]}"}]}"#.utf8))
    ])
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RetryURLProtocol.self]
    let waits = RetryWaits()
    let client = SolverClient(session: URLSession(configuration: configuration), sleep: { await waits.record($0) })
    let result = try await client.send(AIRequest(credential: AICredential(provider: .claude, key: "fixture", model: "fixture"),
      photos: [], prompt: "Fixture", shape: .answers, tokenLimit: 6000))
    XCTAssertEqual(String(decoding: result, as: UTF8.self), #"{"answers":[]}"#)
    let delays = await waits.delays
    XCTAssertEqual(delays, [0, 2])
    XCTAssertEqual(RetryURLProtocol.state.calls, 3)
  }

  func testRetryPolicyDoesNotRetryAuthOrIgnoreLongDeadline() throws {
    let url = URL(string: "https://api.anthropic.com/v1/messages")!
    func response(_ code: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
      HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!
    }
    XCTAssertNil(SolverClient.retryDelay(response: response(401), attempt: 0))
    XCTAssertNil(SolverClient.retryDelay(response: response(403), attempt: 0))
    XCTAssertNil(SolverClient.retryDelay(response: response(429), attempt: 2))
    XCTAssertNil(SolverClient.retryDelay(response: response(429, ["retry-after": "120"]), attempt: 0))
    XCTAssertNil(SolverClient.retryDelay(response: response(503, ["x-should-retry": "false"]), attempt: 0))
    XCTAssertEqual(SolverClient.retryDelay(response: response(429, ["retry-after-ms": "250"]), attempt: 0), 0.25)
    let date = Date(timeIntervalSince1970: 0)
    XCTAssertEqual(SolverClient.retryDelay(response: response(429, ["retry-after": "Thu, 01 Jan 1970 00:00:30 GMT"]), attempt: 0, now: date), 30)
  }

  private func groupInventory() -> QuestionInventory {
    QuestionInventory(title: "13 subparts", pages: (1...3).map { PageReading(page: $0, readable: true, issue: "") },
      questions: (1...13).map { InventoriedQuestion(id: "q\($0)", label: "\($0)(a)", sourcePages: [($0 - 1) / 6 + 1], problem: "2x = 8") })
  }
  private func photo() -> Data {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
    return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).jpegData(withCompressionQuality: 0.8) { context in
      UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
    }
  }
}

private actor OrganizedPhotoTransport: AITransport {
  let inventory: QuestionInventory
  let delay: Duration
  private(set) var requests: [AIRequest] = []
  private(set) var maximumInFlight = 0
  private(set) var answerCalls = 0
  private var inFlight = 0
  init(inventory: QuestionInventory, delay: Duration = .zero) { self.inventory = inventory; self.delay = delay }
  func send(_ input: AIRequest) async throws -> Data {
    requests.append(input)
    if case .inventory = input.shape { return try JSONEncoder().encode(inventory) }
    answerCalls += 1; inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
    defer { inFlight -= 1 }
    if delay > .zero { try await Task.sleep(for: delay) }
    let marker = "Required questions (untrusted document data): "
    guard let range = input.prompt.range(of: marker) else { throw URLError(.badServerResponse) }
    let questions = try JSONDecoder().decode([InventoriedQuestion].self, from: Data(input.prompt[range.upperBound...].utf8))
    return try JSONEncoder().encode(AnswerSet(answers: questions.map {
      WorkedAnswer(id: $0.id, steps: ["2x = 8", "x = 8/2"], answer: "x = 4", check: "2(4) = 8", status: "solved", reviewNote: "")
    }))
  }
}

private actor RetryWaits {
  private(set) var delays: [TimeInterval] = []
  func record(_ delay: TimeInterval) { delays.append(delay) }
}

private final class RetryProtocolState: @unchecked Sendable {
  struct Reply { let status: Int; let headers: [String: String]; let data: Data }
  private let lock = NSLock()
  private var replies: [Reply] = []
  private var count = 0
  var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
  func reset(_ replies: [Reply]) { lock.lock(); defer { lock.unlock() }; self.replies = replies; count = 0 }
  func next() -> Reply? {
    lock.lock(); defer { lock.unlock() }; count += 1
    return replies.isEmpty ? nil : replies.removeFirst()
  }
}
private final class RetryURLProtocol: URLProtocol {
  static let state = RetryProtocolState()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let reply = Self.state.next(), let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply.data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
