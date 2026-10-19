@testable import CameraAccess
import XCTest
import UIKit

@MainActor
final class PageSolvingTests: XCTestCase {
  // MARK: Plan and combine

  func testNewestPageWaitsForItsSuccessorAndFinishAddsTheLastPage() {
    let a = UUID(), b = UUID(), c = UUID()
    let scanning = PagePlan.keys(for: [a, b, c], final: false, setup: "s")
    XCTAssertEqual(scanning.map(\.page), [a, b])
    XCTAssertEqual(scanning[0].previous, nil); XCTAssertEqual(scanning[0].next, b)
    XCTAssertEqual(scanning[1].previous, a); XCTAssertEqual(scanning[1].next, c)
    let finished = PagePlan.keys(for: [a, b, c], final: true, setup: "s")
    XCTAssertEqual(finished.count, 3)
    XCTAssertEqual(finished[2].page, c); XCTAssertNil(finished[2].next); XCTAssertTrue(finished[2].last)
    XCTAssertEqual(Array(finished.prefix(2)), scanning, "Finishing must reuse every earlier page's job.")
    XCTAssertTrue(PagePlan.keys(for: [], final: true, setup: "s").isEmpty)
  }
  func testRetakingAPageReSolvesOnlyItAndItsNeighbors() {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), retaken = UUID()
    let before = Set(PagePlan.keys(for: [a, b, c, d], final: true, setup: "s"))
    let after = Set(PagePlan.keys(for: [a, b, retaken, d], final: true, setup: "s"))
    XCTAssertEqual(before.intersection(after).map(\.page), [a])
    XCTAssertNotEqual(Set(PagePlan.keys(for: [a], final: true, setup: "x")), Set(PagePlan.keys(for: [a], final: true, setup: "y")),
      "Changing provider or model must not reuse another setup's answers.")
  }
  func testCombineKeepsPageOrderDropsRepeatedQuestionsAndFlagsReview() throws {
    let two = result([item("2(a)", "Find y", page: 2, status: "needs_review", note: "Exponent unclear")])
    let one = result([item("1(a)", "Find x", page: 1), item("1(b)", "Find z", page: 1)])
    let repeated = result([item("2 (a)", "Find  y", page: 3)])
    let solution = try PagePlan.combine([(2, two), (1, one), (3, repeated)], providers: "fixture")
    XCTAssertEqual(solution.problems.map(\.label), ["1(a)", "1(b)", "2(a)"])
    XCTAssertEqual(solution.problems[2].reviewNote, "NEEDS REVIEW: Exponent unclear")
    XCTAssertTrue(solution.coverage?.contains("3 source pages") == true)
    XCTAssertTrue(solution.coverage?.contains("1 need review") == true)
    XCTAssertThrowsError(try PagePlan.combine([(1, result([]))], providers: "fixture"))
    XCTAssertEqual(result([item("4", "Q", page: 5)]).shifted(by: -1).solutions[0].sourcePages, [4])
  }
  func testParentNumbersUnresolvedItemsAndLooseLabelsDoNotForceRepairs() throws {
    let parts = [item("3(a)", "f'(x)", page: 1), item("3(b)", "f'(2)", page: 1)]
    XCTAssertNoThrow(try result(parts, checklist: ["3", "3(a)", "3(b)"]).validate(page: 1), "A parent number is covered by its subparts.")
    XCTAssertThrowsError(try result([item("12(a)", "x", page: 1)], checklist: ["1", "12(a)"]).validate(page: 1), "'1' is not a parent of '12(a)'.")
    let missingData = PageSolutionItem(label: "4", problem: "Find the mass", steps: [], answer: "", check: "", status: "insufficient_information",
      reviewNote: "The density is not given.", sourcePages: [1])
    XCTAssertNoThrow(try result([missingData]).validate(page: 1))
    let combined = try PagePlan.combine([(1, result([missingData]))], providers: "fixture")
    XCTAssertEqual(combined.problems[0].answer, "—"); XCTAssertFalse(combined.problems[0].steps.isEmpty)
    XCTAssertNoThrow(try result([item("3(b)", "x", page: 1)]).validate(page: 1, mustCover: ["Q3(b)"]), "Cross-check drafts may spell labels differently.")
    // A must-solve item that is missing or skipped again is sent back for repair.
    XCTAssertThrowsError(try result([item("1(a)", "x", page: 2)], checklist: ["1(a)"]).validate(page: 2, mustSolve: ["5(b)"]))
    let skippedClaim = PageResult(readable: true, retake: "", title: "T", checklist: ["5(b)"], solutions: [],
      skipped: [SkippedItem(label: "5(b)", reason: "began earlier")])
    XCTAssertThrowsError(try skippedClaim.validate(page: 2, mustSolve: ["5(b)"]))
  }
  func testItemsSkippedOnBothPagesAreDetected() {
    let one = result([item("5(a)", "Block on incline", page: 1)])
    let two = PageResult(readable: true, retake: "", title: "T", checklist: ["5(b)", "6"], solutions: [item("6", "Next", page: 2)],
      skipped: [SkippedItem(label: "5(b)", reason: "question 5 began on the previous page")])
    XCTAssertEqual(PagePlan.orphanedSkips([(1, one), (2, two)]), [2: ["5(b)"]])
    let repeated = PageResult(readable: true, retake: "", title: "T", checklist: ["5(a)"], solutions: [],
      skipped: [SkippedItem(label: "5 (a)", reason: "overlapping photo")])
    XCTAssertTrue(PagePlan.orphanedSkips([(1, one), (2, repeated)]).isEmpty, "A repeat of an item the previous page solved is fine.")
    let firstPage = PageResult(readable: true, retake: "", title: "T", checklist: ["1"], solutions: [], skipped: [SkippedItem(label: "1", reason: "x")])
    XCTAssertEqual(PagePlan.orphanedSkips([(1, firstPage)]), [1: ["1"]])
    var job = PageJob(key: PageJobKey(page: UUID(), previous: UUID(), next: nil, last: true, setup: "s"), number: 2,
      primary: URL(fileURLWithPath: "/p"), previous: URL(fileURLWithPath: "/q"), next: nil)
    job.mustSolve = ["5(b)"]
    XCTAssertTrue(PageSolver.task(for: job).contains("MUST be solved here, not skipped: 5(b)"))
  }
  func testOpenAIStreamErrorsAreRetriedOnlyWhenTransient() throws {
    var server = StreamParser(provider: .openAI)
    XCTAssertThrowsError(try server.consume(#"data: {"type":"error","code":"server_error","message":"x","param":null}"#)) {
      XCTAssertTrue(PageSolver.isTransient($0))
    }
    var invalid = StreamParser(provider: .openAI)
    XCTAssertThrowsError(try invalid.consume(#"data: {"type":"error","code":"invalid_prompt","message":"Bad image","param":null}"#)) {
      XCTAssertFalse(PageSolver.isTransient($0)); XCTAssertTrue($0.localizedDescription.contains("Bad image"))
    }
    var claude = StreamParser(provider: .claude)
    XCTAssertThrowsError(try claude.consume(#"data: {"type":"error","error":{"type":"invalid_request_error","message":"no"}}"#)) {
      XCTAssertFalse(PageSolver.isTransient($0))
    }
  }
  func testRepairOutputStaysWithinOlderModelLimits() {
    XCTAssertEqual(SolverClient.outputLimit(48_000, model: "gpt-6.1-sol"), 48_000)
    XCTAssertEqual(SolverClient.outputLimit(48_000, model: "claude-opus-5-5"), 48_000)
    XCTAssertEqual(SolverClient.outputLimit(48_000, model: "gpt-4.1"), 32_000)
  }
  func testPageResultValidationRequiresCoverageAndCompleteAnswers() throws {
    let solved = item("1(a)", "Solve", page: 1)
    XCTAssertNoThrow(try PageResult(readable: true, retake: "", title: "T", checklist: ["1(a)", "1(b)"], solutions: [solved],
      skipped: [SkippedItem(label: "1 (b)", reason: "began on the previous page")]).validate(page: 1))
    XCTAssertThrowsError(try result([solved], checklist: ["1(a)", "1(b)"]).validate(page: 1)) { error in
      guard case AIResultError.repairable(let reason) = error else { return XCTFail("\(error)") }
      XCTAssertTrue(reason.contains("1(b)"))
    }
    XCTAssertThrowsError(try result([solved, solved]).validate(page: 1))
    XCTAssertThrowsError(try result([item("1(a)", "Solve", page: 1, answer: " ")]).validate(page: 1))
    XCTAssertThrowsError(try result([item("1(a)", "Solve", page: 1, status: "needs_review")]).validate(page: 1))
    XCTAssertThrowsError(try result([solved]).validate(page: 1, mustCover: ["2a"]))
    let unreadable = PageResult(readable: false, retake: "Show the bottom line", title: "", checklist: [], solutions: [], skipped: [])
    XCTAssertThrowsError(try unreadable.validate(page: 3)) { error in
      guard case AIResultError.unreadable(let message) = error else { return XCTFail("\(error)") }
      XCTAssertEqual(message, "Page 3: Show the bottom line")
    }
  }

  // MARK: Streams and envelopes

  func testClaudeStreamRebuildsTheJSONAndIgnoresThinking() throws {
    var parser = StreamParser(provider: .claude)
    let lines = [
      "event: message_start",
      #"data: {"type":"message_start","message":{"id":"m","content":[],"stop_reason":null}}"#,
      "",
      #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
      #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"not output"}}"#,
      #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
      #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"{\"a\":"}}"#,
      #"data: {"type":"ping"}"#,
      #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"1}"}}"#,
      #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
    ]
    for line in lines { XCTAssertFalse(try parser.consume(line)) }
    XCTAssertThrowsError(try parser.finish(), "A stream without message_stop was cut off.") { error in
      XCTAssertTrue(PageSolver.isTransient(error))
    }
    XCTAssertTrue(try parser.consume(#"data: {"type":"message_stop"}"#))
    XCTAssertEqual(String(decoding: try parser.finish(), as: UTF8.self), #"{"a":1}"#)
  }
  func testClaudeStreamTruncationRefusalAndOverload() throws {
    for (reason, repairable) in [("max_tokens", true), ("refusal", false)] {
      var parser = StreamParser(provider: .claude)
      _ = try parser.consume(#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"{"}}"#)
      _ = try parser.consume(#"data: {"type":"message_delta","delta":{"stop_reason":"\#(reason)"}}"#)
      _ = try parser.consume(#"data: {"type":"message_stop"}"#)
      XCTAssertThrowsError(try parser.finish()) { error in
        XCTAssertEqual(error is AIResultError, repairable, "\(reason): \(error)")
        XCTAssertFalse(PageSolver.isTransient(error))
      }
    }
    var parser = StreamParser(provider: .claude)
    XCTAssertThrowsError(try parser.consume(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)) { error in
      XCTAssertTrue(PageSolver.isTransient(error))
    }
  }
  func testOpenAIStreamUsesTheFinalResponseAndHandlesIncompleteAndFailed() throws {
    var parser = StreamParser(provider: .openAI)
    _ = try parser.consume(#"data: {"type":"response.created","response":{"status":"in_progress"}}"#)
    _ = try parser.consume(#"data: {"type":"response.output_text.delta","delta":"{\"a\":"}"#)
    _ = try parser.consume(#"data: {"type":"response.output_text.delta","delta":"1}"}"#)
    XCTAssertTrue(try parser.consume(#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"{\"a\":1}"}]}]}}"#))
    XCTAssertEqual(String(decoding: try parser.finish(), as: UTF8.self), #"{"a":1}"#)

    var deltasOnly = StreamParser(provider: .openAI)
    _ = try deltasOnly.consume(#"data: {"type":"response.output_text.delta","delta":"{\"b\":2}"}"#)
    _ = try deltasOnly.consume(#"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"#)
    XCTAssertEqual(String(decoding: try deltasOnly.finish(), as: UTF8.self), #"{"b":2}"#)

    var incomplete = StreamParser(provider: .openAI)
    _ = try incomplete.consume(#"data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}}"#)
    XCTAssertThrowsError(try incomplete.finish()) { XCTAssertTrue($0 is AIResultError) }

    var failed = StreamParser(provider: .openAI)
    _ = try failed.consume(#"data: {"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"x"},"output":[]}}"#)
    XCTAssertThrowsError(try failed.finish()) { XCTAssertTrue(PageSolver.isTransient($0)) }

    var invalid = StreamParser(provider: .openAI)
    _ = try invalid.consume(#"data: {"type":"response.failed","response":{"status":"failed","error":{"code":"invalid_image","message":"x"},"output":[]}}"#)
    XCTAssertThrowsError(try invalid.finish()) { XCTAssertFalse(PageSolver.isTransient($0)) }
  }
  func testEnvelopesRejectHTTPIncompleteRefusalAndEmptyText() throws {
    XCTAssertThrowsError(try SolverClient.payload(data: Data(), status: 401, provider: .openAI)) { XCTAssertFalse(PageSolver.isTransient($0)) }
    let incomplete = Data(#"{"status":"incomplete","output":[]}"#.utf8)
    XCTAssertThrowsError(try SolverClient.payload(data: incomplete, status: 200, provider: .openAI))
    let refusal = Data(#"{"status":"completed","output":[{"content":[{"type":"refusal","refusal":"no"}]}]}"#.utf8)
    XCTAssertThrowsError(try SolverClient.payload(data: refusal, status: 200, provider: .openAI))
    XCTAssertThrowsError(try SolverClient.payload(data: Data(#"{"status":"completed","output":[]}"#.utf8), status: 200, provider: .openAI))
    let claude = Data(#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"not a solution"},{"type":"text","text":"{\"answers\":[]}"}]}"#.utf8)
    XCTAssertEqual(String(decoding: try SolverClient.payload(data: claude, status: 200, provider: .claude), as: UTF8.self), #"{"answers":[]}"#)
    XCTAssertThrowsError(try SolverClient.payload(data: Data(#"{"stop_reason":"end_turn","content":[]}"#.utf8), status: 200, provider: .claude))
  }
  func testOnlyTransientServiceErrorsAreRetryable() {
    XCTAssertTrue(PageSolver.isTransient(AIServiceError.http(provider: .claude, status: 529, retryAfter: nil, detail: "")))
    XCTAssertTrue(PageSolver.isTransient(AIServiceError.http(provider: .openAI, status: 429, retryAfter: 3, detail: "rate_limit_exceeded")))
    XCTAssertTrue(PageSolver.isTransient(URLError(.networkConnectionLost)))
    XCTAssertTrue(PageSolver.isTransient(AIServiceError.http(provider: .openAI, status: 520, retryAfter: nil, detail: "")))
    XCTAssertFalse(PageSolver.isTransient(URLError(.timedOut)), "An idle timeout after minutes of silence would only repeat.")
    XCTAssertFalse(PageSolver.isTransient(AIServiceError.http(provider: .openAI, status: 501, retryAfter: nil, detail: "")))
    for status in [400, 401, 402, 403, 404, 413] {
      XCTAssertFalse(PageSolver.isTransient(AIServiceError.http(provider: .openAI, status: status, retryAfter: nil, detail: "")))
    }
    XCTAssertFalse(PageSolver.isTransient(AIServiceError.http(provider: .claude, status: 429, retryAfter: nil, detail: #"{"error_code":"enforced_spend_limit_reached"}"#)))
    XCTAssertFalse(PageSolver.isTransient(AIServiceError.http(provider: .openAI, status: 429, retryAfter: nil, detail: #"{"code":"insufficient_quota"}"#)))
    XCTAssertFalse(PageSolver.isTransient(URLError(.cancelled)))
    XCTAssertFalse(PageSolver.isTransient(SolverError.message("refused")))
  }

  // MARK: Requests

  func testRequestsStreamUseTheRequestedModelsAndSeparateCredentials() throws {
    let photo = AIPhoto(label: "PRIMARY page (source page 2), solve this page:", jpeg: Data([1, 2, 3]))
    for provider in AIProvider.allCases {
      let model = provider == .claude ? SolverConfiguration.claudeDefault : SolverConfiguration.openAIDefault
      let credential = AICredential(provider: provider, key: provider == .claude ? "claude-secret-fixture" : "openai-secret-fixture", model: model)
      let request = try SolverClient.request(AIRequest(credential: credential, photos: [photo], prompt: "Solve", tokenLimit: 32_000))
      let data = try XCTUnwrap(request.httpBody), body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let text = String(decoding: data, as: UTF8.self)
      XCTAssertFalse(text.contains("secret-fixture"))
      XCTAssertEqual(body["stream"] as? Bool, true)
      XCTAssertEqual(body["model"] as? String, model)
      XCTAssertTrue(text.contains("source page 2"))
      if provider == .claude {
        XCTAssertEqual(model, "claude-opus-5-5")
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), credential.key)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "medium"); XCTAssertNotNil(output["format"])
        XCTAssertEqual(body["max_tokens"] as? Int, 32_000)
        XCTAssertTrue(text.contains("media_type"))
      } else {
        XCTAssertEqual(model, "gpt-6.1-sol")
        XCTAssertEqual(request.url?.host, "api.openai.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + credential.key)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 32_000)
        let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertTrue(text.contains("input_image"))
      }
    }
    let older = try SolverClient.request(AIRequest(credential: AICredential(provider: .claude, key: "k", model: "claude-3-7-sonnet"),
      photos: [photo], prompt: "Solve", tokenLimit: 1000))
    let olderBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(older.httpBody)) as? [String: Any])
    XCTAssertNil((olderBody["output_config"] as? [String: Any])?["effort"], "Effort is only sent to models that accept it.")
  }
  func testSchemaIsStrictEverywhere() {
    func check(_ node: Any, path: String) {
      guard let object = node as? [String: Any] else { return }
      if object["type"] as? String == "object" {
        XCTAssertEqual(object["additionalProperties"] as? Bool, false, path)
        let properties = object["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(object["required"] as? [String] ?? []), Set(properties.keys), path)
        for (key, value) in properties { check(value, path: path + "." + key) }
      }
      if let items = object["items"] { check(items, path: path + "[]") }
    }
    check(SolverClient.schema, path: "page")
    for word in ["reasoning", "thinking"] {
      XCTAssertFalse(String(describing: SolverClient.schema).lowercased().contains(word), "Schema fields must not request private deliberation.")
    }
  }

  // MARK: Page solver

  func testPageSolverRetriesOverloadsAndDroppedConnectionsButNotAuthOrSpendLimits() async throws {
    let job = try pageJob()
    let ok = ScriptedTransport([.failure(AIServiceError.http(provider: .openAI, status: 529, retryAfter: nil, detail: "")),
      .failure(URLError(.networkConnectionLost)), .success(valid())])
    _ = try await fastSolver(ok).solve(job, configuration: openAI(), progress: { _ in })
    var count = await ok.requests.count; XCTAssertEqual(count, 3)

    for error in [AIServiceError.http(provider: .openAI, status: 401, retryAfter: nil, detail: ""),
                  AIServiceError.http(provider: .openAI, status: 429, retryAfter: nil, detail: "insufficient_quota")] {
      let transport = ScriptedTransport([.failure(error), .success(valid())])
      do { _ = try await fastSolver(transport).solve(job, configuration: openAI(), progress: { _ in }); XCTFail("Must not retry \(error)") } catch {}
      count = await transport.requests.count; XCTAssertEqual(count, 1)
    }
    let busy = ScriptedTransport(Array(repeating: .failure(AIServiceError.http(provider: .openAI, status: 529, retryAfter: nil, detail: "")), count: 5))
    do { _ = try await fastSolver(busy).solve(job, configuration: openAI(), progress: { _ in }); XCTFail("Retries are bounded") } catch {}
    count = await busy.requests.count; XCTAssertEqual(count, 3, "One attempt plus at most two retries.")
  }
  func testIncompleteChecklistGetsOneRepairAndUnreadablePagesNone() async throws {
    let job = try pageJob()
    let missing = try JSONEncoder().encode(result([item("1(a)", "Solve", page: 1)], checklist: ["1(a)", "1(b)"]))
    let repaired = ScriptedTransport([.success(missing), .success(valid())])
    _ = try await fastSolver(repaired).solve(job, configuration: openAI(), progress: { _ in })
    let prompts = await repaired.requests.map(\.prompt)
    XCTAssertEqual(prompts.count, 2); XCTAssertTrue(prompts[1].contains("REPAIR REQUIRED") && prompts[1].contains("1(b)"))
    let tokens = await repaired.requests.map(\.tokenLimit); XCTAssertEqual(tokens, [32_000, 48_000])

    let stillMissing = ScriptedTransport([.success(missing), .success(missing), .success(valid())])
    do { _ = try await fastSolver(stillMissing).solve(job, configuration: openAI(), progress: { _ in }); XCTFail("Only one repair") } catch {}
    var count = await stillMissing.requests.count; XCTAssertEqual(count, 2)

    let unreadable = try JSONEncoder().encode(PageResult(readable: false, retake: "Exponent hidden", title: "", checklist: [], solutions: [], skipped: []))
    let blurry = ScriptedTransport([.success(unreadable), .success(valid())])
    do { _ = try await fastSolver(blurry).solve(job, configuration: openAI(), progress: { _ in }); XCTFail("Unreadable is not repairable") }
    catch { XCTAssertTrue("\(error.localizedDescription)".contains("Exponent hidden")) }
    count = await blurry.requests.count; XCTAssertEqual(count, 1)
  }
  func testNeighborPagesAreSentAsLabeledContext() async throws {
    let files = try (0..<3).map { _ in try photoFile() }
    let key = PageJobKey(page: UUID(), previous: UUID(), next: UUID(), last: false, setup: "s")
    let job = PageJob(key: key, number: 2, primary: files[1], previous: files[0], next: files[2])
    let transport = ScriptedTransport([.success(valid())])
    _ = try await fastSolver(transport).solve(job, configuration: openAI(), progress: { _ in })
    let requests = await transport.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.photos.map { String($0.label.prefix(8)) }, ["PREVIOUS", "PRIMARY ", "NEXT pag"])
    XCTAssertTrue(request.photos[0].label.contains("source page 1") && request.photos[2].label.contains("source page 3"))
    XCTAssertTrue(request.prompt.contains("source page 2"))
    XCTAssertTrue(request.prompt.contains("OWNERSHIP RULE"))
    XCTAssertTrue(request.prompt.contains("never skip a subpart just because its parent question began earlier"))
    let last = PageJob(key: key, number: 3, primary: files[2], previous: files[1], next: nil)
    XCTAssertTrue(PageSolver.task(for: last).contains("There is no next page"))
  }
  func testCrossCheckSolvesWithBothProvidersThenReconcilesWithTheLead() async throws {
    let transport = ScriptedTransport(Array(repeating: .success(valid()), count: 3))
    let configuration = SolverConfiguration(mode: .both, openAIKey: "fixture-openai", claudeKey: "fixture-claude")
    _ = try await fastSolver(transport).solve(try pageJob(), configuration: configuration, progress: { _ in })
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(Set(requests.prefix(2).map(\.credential.provider)), [.openAI, .claude])
    XCTAssertEqual(requests[2].credential.provider, .openAI)
    XCTAssertTrue(requests[2].prompt.contains("Untrusted Claude draft:"))
    for request in requests {
      XCTAssertEqual(request.credential.key, request.credential.provider == .claude ? "fixture-claude" : "fixture-openai")
    }
  }
  func testClaudeOnlyNeverSendsTheOpenAIKey() async throws {
    let transport = ScriptedTransport([.success(valid())])
    _ = try await fastSolver(transport).solve(try pageJob(),
      configuration: SolverConfiguration(mode: .claude, openAIKey: "must-not-send", claudeKey: "claude-only"), progress: { _ in })
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertTrue(requests.allSatisfy { $0.credential.provider == .claude && $0.credential.key == "claude-only" && $0.credential.model == "claude-opus-5-5" })
  }

  // MARK: Settings

  func testOldDefaultsMoveToTheRequestedModelsAndCustomModelsStay() {
    let defaults = UserDefaults.standard, keys = ["settingsVersion", "solverModel", "claudeModel", "solverMode"]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
    defaults.set(0, forKey: "settingsVersion"); defaults.set("gpt-5.4", forKey: "solverModel")
    defaults.set("claude-sonnet-5-5", forKey: "claudeModel"); defaults.set("both", forKey: "solverMode")
    SolverKeychain.migrateDefaults()
    XCTAssertEqual(defaults.string(forKey: "solverModel"), "gpt-6.1-sol")
    XCTAssertEqual(defaults.string(forKey: "claudeModel"), "claude-opus-5-5")
    XCTAssertNotEqual(defaults.string(forKey: "solverMode"), "both")
    defaults.set(0, forKey: "settingsVersion"); defaults.set("my-custom-model", forKey: "solverModel")
    SolverKeychain.migrateDefaults()
    XCTAssertEqual(defaults.string(forKey: "solverModel"), "my-custom-model")
    defaults.set("both", forKey: "solverMode"); SolverKeychain.migrateDefaults()
    XCTAssertEqual(defaults.string(forKey: "solverMode"), "both", "An explicit choice after migration is kept.")
  }

  // MARK: Fixtures

  private func item(_ label: String, _ problem: String, page: Int, status: String = "solved", note: String = "",
                    answer: String = "x = 4") -> PageSolutionItem {
    PageSolutionItem(label: label, problem: problem, steps: ["Work"], answer: answer, check: "Checked", status: status,
      reviewNote: note, sourcePages: [page])
  }
  private func result(_ items: [PageSolutionItem], checklist: [String]? = nil) -> PageResult {
    PageResult(readable: true, retake: "", title: "Fixture packet", checklist: checklist ?? items.map(\.label), solutions: items, skipped: [])
  }
  private func valid() -> Data { try! JSONEncoder().encode(result([item("1(a)", "Solve 2x = 8", page: 1)])) }
  private func openAI() -> SolverConfiguration { SolverConfiguration(openAIKey: "fixture") }
  private func fastSolver(_ transport: ScriptedTransport) -> PageSolver {
    PageSolver(transport: transport, retryDelays: [.milliseconds(5), .milliseconds(5)])
  }
  private func photoFile() throws -> URL {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { context in
      UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
      ("2x + 3 = 11" as NSString).draw(at: CGPoint(x: 60, y: 300), withAttributes: [.font: UIFont.systemFont(ofSize: 40)])
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("page-\(UUID()).jpg")
    try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
    return url
  }
  private func pageJob() throws -> PageJob {
    PageJob(key: PageJobKey(page: UUID(), previous: nil, next: nil, last: true, setup: "s"), number: 1,
      primary: try photoFile(), previous: nil, next: nil)
  }
}

private actor ScriptedTransport: AITransport {
  private var script: [Result<Data, any Error>]
  private(set) var requests: [AIRequest] = []
  init(_ script: [Result<Data, any Error>]) { self.script = script }
  func send(_ input: AIRequest) async throws -> Data {
    requests.append(input)
    guard !script.isEmpty else { throw URLError(.badServerResponse) }
    return try script.removeFirst().get()
  }
}
