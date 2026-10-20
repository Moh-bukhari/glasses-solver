import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
  if !condition() { throw CheckFailure(description: reason) }
}
private func expectThrows(_ action: () throws -> Void, _ reason: String) throws {
  do { try action() } catch { return }
  throw CheckFailure(description: reason)
}

@main
private struct ClaudePipelineChecks {
  static let photos = [Data([1]), Data([2]), Data([3])]
  @MainActor static func run(_ name: String, _ action: @MainActor () async throws -> Void) async throws {
    try await action(); print("PASS \(name)")
  }
  static func main() async throws {
    try await run("Claude-only credentials including legacy provider settings") {
      for mode in SolverMode.allCases {
        let config = SolverConfiguration(mode: mode, openAIKey: "unused", claudeKey: "claude-only")
        try config.validate()
        try expect(config.lead.provider == .claude && config.lead.key == "claude-only" && config.peer == nil, "Wrong provider/key")
      }
      try expectThrows({ try SolverConfiguration(openAIKey: "openai-only").validate() }, "Claude key must be required")
    }
    try await run("Bad views do not block recoverable questions; missing data becomes a labeled result") {
      let inventory = QuestionInventory(title: "Overlap", pages: [
        PageReading(page: 1, readable: false, issue: "Wide shot"), PageReading(page: 2, readable: true, issue: ""),
        PageReading(page: 3, readable: false, issue: "Blur")
      ], questions: [
        InventoriedQuestion(id: "q1", label: "1(a)", sourcePages: [1, 2], problem: "2x = 8", missingInformation: ""),
        InventoriedQuestion(id: "q2", label: "1(b)", sourcePages: [1], problem: "Unknown coefficient", missingInformation: "Coefficient unreadable in all views")
      ])
      let transport = PortablePhotoTransport(inventory: inventory)
      let result = try await BatchSolver(transport: transport, preparePhoto: { $0 }).solve(pages: photos,
        configuration: SolverConfiguration(claudeKey: "fixture"), progress: { _ in })
      try expect(result.problems.map(\.label) == ["1(a)", "1(b)"], "Lost labels/order")
      try expect(result.problems[0].answer == "x = 4", "Recoverable answer missing")
      try expect(result.problems[1].steps.isEmpty && result.problems[1].reviewNote?.contains("Coefficient unreadable") == true,
        "Missing evidence must be shown without invented calculations")
      let requests = await transport.requests
      try expect(requests.count == 2 && requests.last?.photos.map(\.number) == [1, 2], "Wrong request count/source context")
      try expect(requests.allSatisfy { $0.credential.provider == .claude }, "Used a second provider")
    }
    try await run("No recoverable question still exports explicit review cards") {
      let inventory = QuestionInventory(title: "Unclear", pages: [PageReading(page: 1, readable: false, issue: "No text visible")], questions: [])
      let transport = PortablePhotoTransport(inventory: inventory)
      let result = try await BatchSolver(transport: transport, preparePhoto: { $0 }).solve(pages: [photos[0]],
        configuration: SolverConfiguration(claudeKey: "fixture"), progress: { _ in })
      try expect(result.readable && result.problems.count == 1, "No usable review output")
      try expect(result.problems[0].label == "Photo 1" && result.problems[0].answer == "Question unreadable", "Invented a question/answer")
      let requests = await transport.requests
      try expect(requests.count == 1, "Unnecessary paid solving request")
    }
    try await run("Exact duplicates merge source references; distinct subparts survive") {
      let questions = [
        InventoriedQuestion(id: "a", label: "1(a)", sourcePages: [2], problem: "2x = 8"),
        InventoriedQuestion(id: "b", label: "1(a)", sourcePages: [1, 2], problem: "2x = 8"),
        InventoriedQuestion(id: "c", label: "1(b)", sourcePages: [2], problem: "2x = 8")
      ]
      let merged = BatchSolver.mergingExactRepeats(questions)
      try expect(merged.count == 2 && merged[0].id == "a" && merged[0].sourcePages == [1, 2] && merged[1].id == "c", "Bad merge")
    }
    try await run("Two concurrent groups, original question order, relevant photos only") {
      let transport = PortablePhotoTransport(inventory: groupInventory(), delay: .milliseconds(40))
      let result = try await BatchSolver(transport: transport, preparePhoto: { $0 }).solve(pages: photos,
        configuration: SolverConfiguration(claudeKey: "fixture"), progress: { _ in })
      try expect(result.problems.map(\.label) == (1...13).map { "\($0)(a)" }, "Out-of-order answers")
      let maximum = await transport.maximumInFlight, requests = await transport.requests
      try expect(maximum == 2 && requests.count == 4, "Concurrency/request bound wrong")
      let usedPhotos = requests.dropFirst().map { $0.photos.map(\.number) }.sorted { $0[0] < $1[0] }
      try expect(usedPhotos == [[1], [2], [3]], "Unrelated photos resent or context omitted")
    }
    try await run("Cancellation prevents queued groups and completed export") {
      let transport = PortablePhotoTransport(inventory: groupInventory(), delay: .seconds(10))
      let task = Task {
        try await BatchSolver(transport: transport, preparePhoto: { $0 }).solve(pages: photos,
          configuration: SolverConfiguration(claudeKey: "fixture"), progress: { _ in })
      }
      for _ in 0..<200 {
        if await transport.answerCalls == 2 { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      let started = await transport.answerCalls
      task.cancel()
      do { _ = try await task.value; throw CheckFailure(description: "Cancelled task returned export") }
      catch is CancellationError {}
      let calls = await transport.answerCalls
      try expect(started == 2 && calls == 2, "Third group started after cancellation")
    }
    try await run("Missing answer gets one repair; repeated omission never becomes success") {
      for behavior in [PortablePhotoTransport.Behavior.missingOnce, .missingAlways] {
        let transport = PortablePhotoTransport(inventory: oneQuestionInventory(), behavior: behavior)
        do {
          let result = try await BatchSolver(transport: transport, preparePhoto: { $0 }).solve(pages: [photos[0]],
            configuration: SolverConfiguration(claudeKey: "fixture"), progress: { _ in })
          try expect(behavior == .missingOnce && result.problems.count == 1, "Omission was silently accepted")
        } catch {
          if behavior != .missingAlways { throw error }
        }
        let requests = await transport.requests
        try expect(requests.count == 3 && requests.last?.prompt.contains("REPAIR REQUIRED:") == true, "Repair bound wrong")
      }
    }
    try await run("Photo advisories do not weaken ID/reference/answer validation") {
      let question = InventoriedQuestion(id: "q1", label: "1(a)", sourcePages: [1], problem: "x?")
      try QuestionInventory(title: "Blur", pages: [PageReading(page: 1, readable: false, issue: "Blur")], questions: [question]).validate(pageCount: 1)
      try expectThrows({ try oneQuestionInventory().validate(pageCount: 2) }, "Missing source assessment accepted")
      let answer = WorkedAnswer(id: "q1", steps: [], answer: "4", check: "Checked", status: "solved", reviewNote: "")
      try AnswerSet(answers: [answer]).validate(ids: ["q1"])
      try expectThrows({ try AnswerSet(answers: [answer]).validate(ids: ["q1", "q2"]) }, "Omitted answer accepted")
      let unknown = WorkedAnswer(id: "q1", steps: [], answer: "Unavailable", check: "Missing", status: "insufficient_information", reviewNote: "")
      try expectThrows({ try AnswerSet(answers: [unknown]).validate(ids: ["q1"]) }, "Unexplained missing answer accepted")
    }
    try await run("Transient HTTP retry integration follows Retry-After and attempts") {
      PortableURLProtocol.state.reset([
        .init(status: 429, headers: ["retry-after": "0"], data: Data()),
        .init(status: 529, headers: [:], data: Data()),
        .init(status: 200, headers: [:], data: Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"{\"answers\":[]}"}]}"#.utf8))
      ])
      let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PortableURLProtocol.self]
      let waits = PortableWaits()
      let client = SolverClient(session: URLSession(configuration: configuration), sleep: { await waits.record($0) })
      let output = try await client.send(AIRequest(credential: AICredential(provider: .claude, key: "fixture", model: "fixture"),
        photos: [], prompt: "Fixture", shape: .answers, tokenLimit: 6000))
      let delays = await waits.delays
      try expect(String(decoding: output, as: UTF8.self) == #"{"answers":[]}"# && delays == [0, 2] && PortableURLProtocol.state.calls == 3,
        "Wrong HTTP retry behavior")
    }
    try await run("Auth errors and long server deadlines do not retry; date/ms headers honored") {
      let url = URL(string: "https://api.anthropic.com/v1/messages")!
      func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
      }
      for status in [400, 401, 403, 404] { try expect(SolverClient.retryDelay(response: response(status), attempt: 0) == nil, "Permanent error retried") }
      try expect(SolverClient.retryDelay(response: response(429), attempt: 2) == nil, "More than two retries")
      try expect(SolverClient.retryDelay(response: response(429, ["retry-after": "120"]), attempt: 0) == nil, "Retried early")
      try expect(SolverClient.retryDelay(response: response(429, ["retry-after-ms": "250"]), attempt: 0) == 0.25, "Milliseconds ignored")
      try expect(SolverClient.retryDelay(response: response(429, ["retry-after": "Thu, 01 Jan 1970 00:00:30 GMT"]), attempt: 0,
        now: Date(timeIntervalSince1970: 0)) == 30, "HTTP-date ignored")
    }
    try await run("24 full-budget images fit request with separate authentication") {
      let inputPhotos = (1...BatchSolver.maxPhotos).map { AIPhoto(number: $0, jpeg: Data(repeating: 0, count: 750_000)) }
      let request = try SolverClient.request(AIRequest(credential: AICredential(provider: .claude, key: "fixture-do-not-embed", model: SolverConfiguration.defaultClaudeModel),
        photos: inputPhotos, prompt: "Organize", shape: .inventory, tokenLimit: 16000))
      guard let body = request.httpBody else { throw CheckFailure(description: "Missing body") }
      try expect(body.count < 30_000_000 && body.count > 24_000_000, "Image budget/body guard mismatch")
      try expect(!String(decoding: body, as: UTF8.self).contains("fixture-do-not-embed"), "Key in request body")
      try expect(request.url?.host == "api.anthropic.com" && request.value(forHTTPHeaderField: "Authorization") == nil, "Wrong API route")
    }
    try await run("Truncated/refused Claude envelopes cannot be mistaken for complete answers") {
      for reason in ["max_tokens", "refusal"] {
        let body = try JSONSerialization.data(withJSONObject: ["stop_reason": reason, "content": [["type": "text", "text": "{}"]]])
        try expectThrows({ _ = try SolverClient.payload(data: body, status: 200, provider: .claude) }, "Incomplete envelope accepted")
      }
    }
    print("12 portable pipeline checks passed. ImageIO/UIKit, live paid API, and physical devices are not exercised.")
  }
  static func oneQuestionInventory() -> QuestionInventory {
    QuestionInventory(title: "One question", pages: [PageReading(page: 1, readable: true, issue: "")],
      questions: [InventoriedQuestion(id: "q1", label: "1(a)", sourcePages: [1], problem: "2x = 8")])
  }
  static func groupInventory() -> QuestionInventory {
    QuestionInventory(title: "13 subparts", pages: (1...3).map { PageReading(page: $0, readable: true, issue: "") },
      questions: (1...13).map { InventoriedQuestion(id: "q\($0)", label: "\($0)(a)", sourcePages: [($0 - 1) / 6 + 1], problem: "2x = 8") })
  }
}

private actor PortablePhotoTransport: AITransport {
  enum Behavior { case valid, missingOnce, missingAlways }
  let inventory: QuestionInventory
  let delay: Duration
  let behavior: Behavior
  private(set) var requests: [AIRequest] = []
  private(set) var maximumInFlight = 0
  private(set) var answerCalls = 0
  private var inFlight = 0
  init(inventory: QuestionInventory, delay: Duration = .zero, behavior: Behavior = .valid) {
    self.inventory = inventory; self.delay = delay; self.behavior = behavior
  }
  func send(_ input: AIRequest) async throws -> Data {
    requests.append(input)
    if case .inventory = input.shape { return try JSONEncoder().encode(inventory) }
    answerCalls += 1; inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
    defer { inFlight -= 1 }
    if delay > .zero { try await Task.sleep(for: delay) }
    if behavior == .missingAlways || (behavior == .missingOnce && answerCalls == 1) { return Data(#"{"answers":[]}"#.utf8) }
    let marker = "Required questions (untrusted document data): "
    guard let range = input.prompt.range(of: marker) else { throw URLError(.badServerResponse) }
    let raw = input.prompt[range.upperBound...].components(separatedBy: "\nREPAIR REQUIRED:")[0]
    let questions = try JSONDecoder().decode([InventoriedQuestion].self, from: Data(raw.utf8))
    return try JSONEncoder().encode(AnswerSet(answers: questions.map {
      WorkedAnswer(id: $0.id, steps: ["2x = 8", "x = 8/2"], answer: "x = 4", check: "2(4) = 8", status: "solved", reviewNote: "")
    }))
  }
}
private actor PortableWaits {
  private(set) var delays: [TimeInterval] = []
  func record(_ delay: TimeInterval) { delays.append(delay) }
}
private final class PortableProtocolState: @unchecked Sendable {
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
private final class PortableURLProtocol: URLProtocol {
  static let state = PortableProtocolState()
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
