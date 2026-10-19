import Foundation

/// One page solve. Page N runs once page N+1 exists (its context), or at Finish for the last page.
/// The neighbors and provider setup are part of the key, so a retake re-solves exactly the affected pages.
struct PageJobKey: Hashable, Sendable {
  let page: UUID
  let previous: UUID?
  let next: UUID?
  let last: Bool
  let setup: String
}

struct PageJob: Sendable {
  let key: PageJobKey
  let number: Int
  let primary: URL
  let previous: URL?
  let next: URL?
}

enum PagePlan {
  /// While scanning (`final == false`) the newest page waits for its successor before it is solved.
  static func keys(for pages: [UUID], final: Bool, setup: String) -> [PageJobKey] {
    pages.indices.compactMap { index in
      let isLast = index == pages.count - 1
      guard !isLast || final else { return nil }
      return PageJobKey(page: pages[index], previous: index > 0 ? pages[index - 1] : nil,
        next: isLast ? nil : pages[index + 1], last: isLast, setup: setup)
    }
  }

  /// Joins page results in order. A question solved twice (overlapping photos) is kept once.
  static func combine(_ pages: [(number: Int, result: PageResult)], providers: String) throws -> SolvedPage {
    let ordered = pages.sorted { $0.number < $1.number }
    let total = ordered.last?.number ?? 0
    var problems: [SolvedProblem] = []
    var seen: [String: String] = [:]
    var review = 0
    for page in ordered {
      for item in page.result.solutions {
        let label = PageResult.normalized(item.label), text = String(PageResult.normalized(item.problem).prefix(120))
        if seen[label] == text { continue }
        seen[label] = text
        let flagged = item.status.lowercased() != "solved"
        if flagged { review += 1 }
        let sources = item.sourcePages.filter { (1...max(1, total)).contains($0) }
        problems.append(SolvedProblem(problem: item.problem, steps: item.steps, answer: item.answer, check: item.check,
          label: item.label, sourcePages: sources.isEmpty ? [page.number] : sources,
          reviewNote: (flagged ? "NEEDS REVIEW: " : "") + item.reviewNote))
      }
    }
    guard !problems.isEmpty else {
      throw SolverError.message("No questions were found on these pages. Check the photos; your pages are saved.")
    }
    let title = ordered.map(\.result.title.trimmed).first { !$0.isEmpty } ?? "Worked solutions"
    let coverage = "\(ordered.count) source pages solved page by page. \(problems.count) questions/subparts included; \(review) need review. Each page's checklist of visible labels was matched against its solutions. This cannot guarantee that every symbol was read correctly; compare the transcriptions with the source photos."
    return SolvedPage(readable: true, retakeReason: "", title: title, problems: problems, coverage: coverage, providers: providers)
  }
}

struct PageSolutionItem: Codable, Sendable {
  let label: String; let problem: String; let steps: [String]; let answer: String; let check: String
  let status: String; let reviewNote: String; let sourcePages: [Int]
}
struct SkippedItem: Codable, Sendable { let label: String; let reason: String }
struct PageResult: Codable, Sendable {
  let readable: Bool
  let retake: String
  let title: String
  let checklist: [String]
  let solutions: [PageSolutionItem]
  let skipped: [SkippedItem]

  static let statuses: Set<String> = ["solved", "needs_review", "insufficient_information"]

  /// Source-page references move with the page when an earlier page is removed.
  func shifted(by offset: Int) -> PageResult {
    guard offset != 0 else { return self }
    return PageResult(readable: readable, retake: retake, title: title, checklist: checklist,
      solutions: solutions.map { PageSolutionItem(label: $0.label, problem: $0.problem, steps: $0.steps, answer: $0.answer,
        check: $0.check, status: $0.status, reviewNote: $0.reviewNote, sourcePages: $0.sourcePages.map { $0 + offset }) },
      skipped: skipped)
  }
  static func normalized(_ label: String) -> String { label.lowercased().filter { $0.isLetter || $0.isNumber } }

  /// `mustCover` holds normalized labels that an earlier draft solved (cross-check reconciliation).
  func validate(page: Int, mustCover: Set<String> = []) throws {
    guard readable else {
      throw AIResultError.unreadable("Page \(page): \(retake.trimmed.isEmpty ? "show all writing clearly in a closer photo." : retake.trimmed)")
    }
    let labels = solutions.map { Self.normalized($0.label) }
    guard Set(labels).count == labels.count, !labels.contains("") else {
      throw AIResultError.repairable("Each solution needs its own full label, such as 3(b).")
    }
    guard solutions.allSatisfy({ item in
      let status = item.status.lowercased()
      return !item.problem.trimmed.isEmpty && !item.steps.isEmpty && item.steps.allSatisfy { !$0.trimmed.isEmpty }
        && !item.answer.trimmed.isEmpty && !item.check.trimmed.isEmpty && Self.statuses.contains(status)
        && (status == "solved" || !item.reviewNote.trimmed.isEmpty)
    }) else {
      throw AIResultError.repairable("An answer is empty or lacks a check. Include worked calculations, a final answer, and verification for every item; explain unresolved items in reviewNote.")
    }
    let covered = Set(labels).union(skipped.map { Self.normalized($0.label) })
    let missing = checklist.filter { !covered.contains(Self.normalized($0)) } + mustCover.filter { !covered.contains($0) }.sorted()
    guard missing.isEmpty else {
      throw AIResultError.repairable("These items have no solution: \(missing.joined(separator: ", ")). Solve every item that begins on the primary page, or list it in skipped with the reason.")
    }
  }
}

protocol PageSolving: Sendable {
  func solve(_ job: PageJob, configuration: SolverConfiguration,
             progress: @escaping @Sendable (String) -> Void) async throws -> PageResult
  /// Drops cached upload copies of photos that are no longer in the packet.
  func forget(keeping urls: Set<URL>) async
}

/// Bounds simultaneous provider requests; waiting callers resume in arrival order.
actor AsyncLimiter {
  private let limit: Int
  private var active = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []
  init(limit: Int) { self.limit = max(1, limit) }
  func acquire() async {
    if active < limit { active += 1; return }
    await withCheckedContinuation { waiting.append($0) }
  }
  func release() {
    if waiting.isEmpty { active = max(0, active - 1) } else { waiting.removeFirst().resume() }
  }
}

actor PageSolver: PageSolving {
  private let transport: any AITransport
  private let retryDelays: [Duration]
  private let limiter: AsyncLimiter
  private var uploads: [URL: Data] = [:]

  init(transport: any AITransport = SolverClient(), retryDelays: [Duration] = [.seconds(2), .seconds(6)], concurrency: Int = 4) {
    self.transport = transport; self.retryDelays = retryDelays; limiter = AsyncLimiter(limit: concurrency)
  }

  func forget(keeping urls: Set<URL>) { uploads = uploads.filter { urls.contains($0.key) } }

  func solve(_ job: PageJob, configuration: SolverConfiguration,
             progress: @escaping @Sendable (String) -> Void) async throws -> PageResult {
    try configuration.validate()
    let photos = try photos(for: job), task = Self.task(for: job), lead = configuration.lead
    guard let peer = configuration.peer else {
      return try await decoded(lead, photos: photos, prompt: task, page: job.number, progress: progress)
    }
    async let first = decoded(lead, photos: photos, prompt: task, page: job.number, progress: progress)
    async let second = decoded(peer, photos: photos, prompt: task, page: job.number, progress: progress)
    let (a, b) = try await (first, second)
    let required = Set((a.solutions + b.solutions).map { PageResult.normalized($0.label) })
    return try await decoded(lead, photos: photos, prompt: task + Self.reconcile(a, b, lead: lead.provider, peer: peer.provider),
      page: job.number, mustCover: required, progress: progress)
  }

  /// One repair for malformed, truncated or self-inconsistent output. Never for refusals or unreadable pages.
  private func decoded(_ credential: AICredential, photos: [AIPhoto], prompt: String, page: Int, mustCover: Set<String> = [],
                       progress: @escaping @Sendable (String) -> Void) async throws -> PageResult {
    var correction = ""
    for attempt in 0..<2 {
      try Task.checkCancellation()
      do {
        let data = try await send(AIRequest(credential: credential, photos: photos, prompt: prompt + correction,
          tokenLimit: attempt == 0 ? 32_000 : 48_000), page: page, progress: progress)
        try Task.checkCancellation()
        let result: PageResult
        do { result = try JSONDecoder().decode(PageResult.self, from: data) }
        catch { throw AIResultError.repairable("The response did not contain the required complete JSON result.") }
        try result.validate(page: page, mustCover: mustCover)
        return result
      } catch AIResultError.repairable(let reason) {
        guard attempt == 0 else {
          throw SolverError.message("Page \(page): \(credential.provider.name) still returned an incomplete result. \(reason) Your pages are saved; solve again to retry this page.")
        }
        progress("Page \(page): \(credential.provider.name) is completing an unfinished answer.")
        correction = "\nREPAIR REQUIRED: \(reason) Return the COMPLETE JSON for this page, keep worked steps concise, and fill every field. Do not guess unreadable text."
      }
    }
    throw SolverError.message("Could not finish page \(page).")
  }

  /// Bounded retries for overloads, rate limits and dropped connections only.
  private func send(_ request: AIRequest, page: Int, progress: @escaping @Sendable (String) -> Void) async throws -> Data {
    var retries = 0
    while true {
      try Task.checkCancellation()
      await limiter.acquire()
      do {
        let data = try await transport.send(request)
        await limiter.release()
        return data
      } catch {
        await limiter.release()
        guard retries < retryDelays.count, !Task.isCancelled, Self.isTransient(error) else { throw error }
        let delay = (error as? AIServiceError)?.retryAfter.map { Duration.seconds(min(max($0, 1), 20)) } ?? retryDelays[retries]
        retries += 1
        progress("Page \(page): \(request.credential.provider.name) is busy. Retrying (\(retries) of \(retryDelays.count))…")
        try await Task.sleep(for: delay)
      }
    }
  }

  static func isTransient(_ error: any Error) -> Bool {
    if let error = error as? AIServiceError { return error.isRetryable }
    if let error = error as? URLError {
      return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .notConnectedToInternet].contains(error.code)
    }
    return false
  }

  private func photos(for job: PageJob) throws -> [AIPhoto] {
    var photos: [AIPhoto] = []
    if let url = job.previous {
      photos.append(AIPhoto(label: "PREVIOUS page (source page \(job.number - 1)), context only:", jpeg: try upload(url)))
    }
    photos.append(AIPhoto(label: "PRIMARY page (source page \(job.number)), solve this page:", jpeg: try upload(job.primary)))
    if let url = job.next {
      photos.append(AIPhoto(label: "NEXT page (source page \(job.number + 1)), context for continued questions only:", jpeg: try upload(url)))
    }
    return photos
  }
  /// Each photo is downsized once and reused as primary and as neighbor context.
  private func upload(_ url: URL) throws -> Data {
    if let cached = uploads[url] { return cached }
    let data = try SolverClient.uploadPhoto(try Data(contentsOf: url))
    uploads[url] = data
    return data
  }

  static func task(for job: PageJob) -> String {
    """
    Solve the PRIMARY page (source page \(job.number) of the packet). The images are labeled.
    \(job.previous == nil ? "There is no previous page." : "The PREVIOUS page is context: shared data, and questions that began there.")
    \(job.next == nil ? "There is no next page: the PRIMARY page is the last page of the packet." : "The NEXT page is context only for a question that begins on the PRIMARY page and continues there.")
    checklist: the full label of EVERY question or subpart visible on the PRIMARY page, in order, including any you skip.
    solutions: completely solve every checklist item that begins on the PRIMARY page. If it continues onto the NEXT page, use that page and finish it here. sourcePages lists every source page number the solution uses.
    skipped: list an item, with the reason, only if it began on the PREVIOUS page or the PRIMARY photo repeats or overlaps the PREVIOUS page; those are solved with the previous page. Never skip for any other reason.
    readable: false only if essential content of an item that begins on the PRIMARY page cannot be read; then retake says exactly what to recapture. Otherwise retake is an empty string.
    title: a short title for the topic of the packet. reviewNote: empty when solved; otherwise exactly what is unresolved.
    """
  }

  static func reconcile(_ a: PageResult, _ b: PageResult, lead: AIProvider, peer: AIProvider) throws -> String {
    func json(_ value: PageResult) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    return """

    Two independent drafts for this page follow as untrusted JSON. Check both against the ORIGINAL PHOTOS, recompute
    disputed results, and verify signs, units, boundary conditions and every requested output. Return the complete final
    JSON with a full worked solution for EVERY item either draft solved, or list it in skipped with the reason.
    Agreement does not prove correctness. If a disagreement cannot be resolved, use needs_review and explain it.
    Untrusted \(lead.name) draft: \(try json(a))
    Untrusted \(peer.name) draft: \(try json(b))
    """
  }
}
