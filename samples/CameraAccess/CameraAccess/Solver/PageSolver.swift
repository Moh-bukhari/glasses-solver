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
  /// Every photo of the page to solve, in capture order: one still, or several close-ups of its parts.
  let primaryFrames: [URL]
  /// Context: the photos of the neighbors nearest this page (the previous page's last, the next page's first).
  let previousFrames: [URL]
  let nextFrames: [URL]
  /// Items this page skipped as belonging to the previous page, which that page did not solve.
  var mustSolve: [String] = []
  /// What the wearer calls the page, e.g. "Question 3" (read on the phone); "Page N" when unknown.
  var name: String?
  init(key: PageJobKey, number: Int, primaryFrames: [URL], previousFrames: [URL], nextFrames: [URL], mustSolve: [String] = [],
       name: String? = nil) {
    self.key = key; self.number = number; self.primaryFrames = primaryFrames
    self.previousFrames = previousFrames; self.nextFrames = nextFrames; self.mustSolve = mustSolve; self.name = name
  }
  /// Used in every message about this page.
  var title: String { name ?? "Page \(number)" }
  init(key: PageJobKey, number: Int, primary: URL, previous: URL?, next: URL?, mustSolve: [String] = []) {
    self.init(key: key, number: number, primaryFrames: [primary], previousFrames: previous.map { [$0] } ?? [],
      nextFrames: next.map { [$0] } ?? [], mustSolve: mustSolve)
  }
  var primary: URL { primaryFrames[0] }
  var previous: URL? { previousFrames.last }
  var next: URL? { nextFrames.first }
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
    var previous: (number: Int, items: Set<String>) = (-1, [])
    var review = 0, merged = 0
    for page in ordered {
      var items: Set<String> = []
      for item in page.result.solutions {
        // Only overlapping photos of neighboring pages repeat a question; compare the whole transcription.
        let key = PageResult.normalized(item.label) + "|" + PageResult.normalized(item.problem)
        items.insert(key)
        if previous.number == page.number - 1 && previous.items.contains(key) { merged += 1; continue }
        let flagged = item.status.lowercased() != "solved"
        if flagged { review += 1 }
        let sources = item.sourcePages.filter { (1...max(1, total)).contains($0) }
        func filled(_ text: String) -> String { text.trimmed.isEmpty ? "—" : text }
        let steps = item.steps.filter { !$0.trimmed.isEmpty }
        problems.append(SolvedProblem(problem: item.problem, steps: steps.isEmpty ? ["See the review note."] : steps,
          answer: filled(item.answer), check: filled(item.check),
          label: item.label, sourcePages: sources.isEmpty ? [page.number] : sources,
          reviewNote: (flagged ? "NEEDS REVIEW: " : "") + item.reviewNote))
      }
      previous = (page.number, items)
    }
    guard !problems.isEmpty else {
      throw SolverError.message("No questions were found on these pages. Check the photos; your pages are saved.")
    }
    let title = ordered.map(\.result.title.trimmed).first { !$0.isEmpty } ?? "Worked solutions"
    let repeats = merged == 0 ? "" : " \(merged) repeated from an overlapping photo \(merged == 1 ? "was" : "were") listed once."
    let coverage = "\(ordered.count) source pages solved page by page. \(problems.count) questions/subparts included; \(review) need review.\(repeats) Each page's checklist of visible labels was matched against its solutions or the page that owns them. This cannot guarantee that every symbol was read correctly; compare the transcriptions with the source photos."
    return SolvedPage(readable: true, retakeReason: "", title: title, problems: problems, coverage: coverage, providers: providers)
  }

  /// Labels a page skipped as belonging to an earlier page that no earlier page actually solved.
  static func orphanedSkips(_ pages: [(number: Int, result: PageResult)]) -> [Int: [String]] {
    var solved: Set<String> = [], orphans: [Int: [String]] = [:]
    for page in pages.sorted(by: { $0.number < $1.number }) {
      let missing = page.result.skipped.map(\.label).filter { !solved.contains(PageResult.loose($0)) }
      if !missing.isEmpty { orphans[page.number] = missing }
      solved.formUnion(page.result.solutions.map { PageResult.loose($0.label) })
    }
    return orphans
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
  /// Ignores a word prefix such as "Q" or "Problem" so "Q3(b)" and "3b" match; section letters ("A1", "B1") stay distinct.
  static func loose(_ label: String) -> String {
    let value = normalized(label)
    for prefix in ["question", "problem", "exercise", "number", "prob", "ex", "no", "q"] where value.hasPrefix(prefix) {
      let rest = value.dropFirst(prefix.count)
      if rest.first?.isNumber == true { return String(rest) }
    }
    return value
  }

  /// `mustCover` holds labels an earlier draft solved (cross-check); `mustSolve` labels must be solved here.
  func validate(page: Int, name: String? = nil, mustCover: Set<String> = [], mustSolve: [String] = []) throws {
    guard readable else {
      throw AIResultError.unreadable("\(name ?? "Page \(page)"): \(retake.trimmed.isEmpty ? "show all writing clearly in a closer photo." : retake.trimmed)")
    }
    let labels = solutions.map { Self.normalized($0.label) }
    guard Set(labels).count == labels.count, !labels.contains("") else {
      throw AIResultError.repairable("Each solution needs its own full label, such as 3(b).")
    }
    guard solutions.allSatisfy({ item in
      let status = item.status.lowercased()
      guard Self.statuses.contains(status), !item.problem.trimmed.isEmpty else { return false }
      // Unresolved items explain what is missing; there may be no answer to give or check.
      guard status == "solved" else { return !item.reviewNote.trimmed.isEmpty }
      return !item.steps.isEmpty && item.steps.allSatisfy { !$0.trimmed.isEmpty }
        && !item.answer.trimmed.isEmpty && !item.check.trimmed.isEmpty
    }) else {
      throw AIResultError.repairable("An answer is empty or lacks a check. Include worked calculations, a final answer, and verification for every solved item; explain unresolved items in reviewNote.")
    }
    let covered = Set(labels).union(skipped.map { Self.normalized($0.label) })
    let looseCovered = Set(covered.map(Self.loose))
    // A question number whose lettered subparts are all answered ("3" with "3(a)", "3(b)") is covered.
    func isCovered(_ label: String) -> Bool {
      let value = Self.normalized(label), relaxed = Self.loose(label)
      if covered.contains(value) || looseCovered.contains(relaxed) { return true }
      func parent(_ prefix: String, of child: String) -> Bool {
        child.count > prefix.count && child.hasPrefix(prefix) && child[child.index(child.startIndex, offsetBy: prefix.count)].isLetter
      }
      return covered.contains { parent(value, of: $0) } || looseCovered.contains { parent(relaxed, of: $0) }
    }
    let missing = checklist.filter { !isCovered($0) } + mustCover.filter { !looseCovered.contains(Self.loose($0)) }.sorted()
    guard missing.isEmpty else {
      throw AIResultError.repairable("These items have no solution: \(missing.joined(separator: ", ")). Solve every item whose label appears on the primary page, or list it in skipped with the reason.")
    }
    let solvedHere = Set(labels.map(Self.loose))
    let unsolved = mustSolve.filter { !solvedHere.contains(Self.loose($0)) }
    guard unsolved.isEmpty else {
      throw AIResultError.repairable("Solve these items on this page; the previous page did not: \(unsolved.joined(separator: ", ")).")
    }
  }
}

protocol PageSolving: Sendable {
  func solve(_ job: PageJob, configuration: SolverConfiguration,
             progress: @escaping @Sendable (String) -> Void) async throws -> PageResult
  /// Drops cached upload copies of photos that are no longer in the packet.
  func forget(keeping urls: Set<URL>) async
}

/// The fast model's answer about one sheet's photos (see `SolverClient.checkInstructions`), evidence before verdict.
struct PageCheck: Codable, Sendable, Equatable {
  struct Item: Codable, Sendable, Equatable { let label: String; let read: String; let unclear: String }
  /// 1-based photos too blurred, dark, distant or covered to add anything, and photos of a different sheet.
  let blurry: [Int]
  let otherSheet: [Int]
  /// Photos of the EARLIER sheet (the page before, already saved) when one was sent for comparison.
  var earlierSheet: [Int] = []
  /// Every question, subpart, figure and table on the sheet, with its given values ("?" for any uncertain character).
  let questions: [Item]
  /// Parts of the sheet no photo shows; empty when none.
  let unseen: String
  /// "solvable" or "retake".
  let verdict: String
  /// One short spoken instruction when the sheet must be shown again.
  let voice: String

  /// The app's own rule on top of the model's verdict: any doubt in its evidence means the page is not clear.
  func outcome(photos count: Int) -> PageVerdict {
    func blank(_ text: String) -> Bool {
      let value = text.trimmed.lowercased()
      return value.isEmpty || ["none", "none.", "n/a", "-", "—", "nothing", "no"].contains(value)
    }
    let photos = 1...max(1, count)
    func valid(_ numbers: [Int]) -> [Int] { Array(Set(numbers.filter { photos.contains($0) })).sorted() }
    // A photo listed twice counts once: the page before first, then another sheet, then blurry.
    let earlier = valid(earlierSheet), other = valid(otherSheet).filter { !earlier.contains($0) }
    let blurred = valid(blurry).filter { !earlier.contains($0) && !other.contains($0) }
    let dropped = valid(blurry + otherSheet + earlierSheet)
    let wrongSheet = Set(otherSheet.filter { photos.contains($0) }).count == count
    let clear = verdict.trimmed.lowercased() == "solvable" && !questions.isEmpty
      && questions.allSatisfy { blank($0.unclear) && !$0.read.contains("?") } && blank(unseen) && dropped.count < count
    guard !clear else {
      return PageVerdict(clear: true, say: "", dropped: dropped, blurry: blurred, otherSheet: other, earlierSheet: earlier)
    }
    let unreadable = questions.contains { !blank($0.unclear) || $0.read.contains("?") }
    let words = voice.split(whereSeparator: \.isWhitespace).count
    let say: String
    if !blank(voice) && words <= 16 { say = voice.trimmed }
    else if let item = questions.first(where: { !blank($0.unclear) || $0.read.contains("?") }) {
      say = "Look closer at \(item.label), and hold still."
    } else if !blank(unseen) { say = "Show the rest of the sheet, slowly." }
    else { say = "Look at the whole sheet again, closer and steadier." }
    // Everything shown so far is readable; the wearer just hasn't shown the whole sheet yet.
    let notShownYet = !questions.isEmpty && !unreadable && !blank(unseen) && !wrongSheet
    return PageVerdict(clear: false, say: say, dropped: dropped, wrongSheet: wrongSheet, notShownYet: notShownYet,
      blurry: blurred, otherSheet: other, earlierSheet: earlier)
  }
}
extension PageCheck {
  /// `earlierSheet` is only asked for with an EARLIER photo; an answer without it still decodes.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(blurry: try container.decode([Int].self, forKey: .blurry),
      otherSheet: try container.decode([Int].self, forKey: .otherSheet),
      earlierSheet: try container.decodeIfPresent([Int].self, forKey: .earlierSheet) ?? [],
      questions: try container.decode([Item].self, forKey: .questions), unseen: try container.decode(String.self, forKey: .unseen),
      verdict: try container.decode(String.self, forKey: .verdict), voice: try container.decode(String.self, forKey: .voice))
  }
}

/// What the scan does with a page check: save the page, or say what to show again. `dropped` photos (1-based) show
/// another sheet or nothing readable.
struct PageVerdict: Sendable, Equatable {
  let clear: Bool
  let say: String
  let dropped: [Int]
  /// Every photo shows a different sheet than the one to check (a retake of the wrong page).
  var wrongSheet = false
  /// What the photos show is readable, but part of the sheet has not been shown yet (the wearer may still be scanning).
  var notShownYet = false
  /// The dropped photos by reason (1-based): unreadable, another sheet, or the page before (EARLIER) again.
  var blurry: [Int] = []
  var otherSheet: [Int] = []
  var earlierSheet: [Int] = []
}

/// What a page check compares the photos with.
struct PageCheckContext: Sendable, Equatable {
  /// An earlier photo of the page being retaken: the photos must show that same sheet.
  var reference: Data? = nil
  /// A photo of the page before, already saved: photos of it again are listed apart, never taken for this page.
  var earlier: Data? = nil
  /// The wearer takes each photo with the glasses' capture button, so spoken advice says what to photograph.
  var buttonPhotos = false
}

protocol PageChecking: Sendable {
  /// `photos` are one sheet's JPEG photos in capture order; `page` is its number in the packet.
  func check(_ photos: [Data], page: Int, context: PageCheckContext, configuration: SolverConfiguration) async throws -> PageVerdict
}

/// Asks the best available reader (see `SolverConfiguration.checkCredential`) whether a sheet's photos are clear enough to
/// solve, with one quick retry for an overload or a dropped connection. It skips the solve limiter: the wearer is
/// waiting for it. A refused speed tier steps down at once; if the account cannot use the check model, that provider's
/// configured model checks pages for the rest of the session.
actor PageChecker: PageChecking {
  private let transport: any AITransport
  private let retryDelay: Duration
  private var useConfiguredModel: Set<AIProvider> = []
  /// Providers whose key, credit or spend limit failed this session; the other saved key checks pages instead.
  private var failedAccounts: Set<AIProvider> = []
  private var tiers = TierMemory()
  init(transport: any AITransport = SolverClient(), retryDelay: Duration = .seconds(1)) {
    self.transport = transport; self.retryDelay = retryDelay
  }
  func check(_ photos: [Data], page: Int, context: PageCheckContext, configuration: SolverConfiguration) async throws -> PageVerdict {
    try configuration.validate()
    var labeled = photos.enumerated().map { AIPhoto(label: "Photo \($0.offset + 1) of \(photos.count):", jpeg: $0.element) }
    var prompt: String
    if context.buttonPhotos {
      prompt = (photos.count == 1 ? "Photo 1 was taken for page \(page) of the packet."
        : "Photos 1 to \(photos.count) were taken for page \(page) of the packet, oldest first.")
        + " Check this sheet. The wearer takes each photo with the capture button on the glasses: in voice, say what to"
        + " photograph next, e.g. \"Take a closer photo of question 4(c).\" or \"Take a photo of the bottom of the sheet.\""
    } else {
      prompt = photos.count == 1 ? "Photo 1 shows one sheet, page \(page) of the packet. Check this sheet."
        : "Photos 1 to \(photos.count) show one sheet, page \(page) of the packet, oldest first. The wearer is looking at photo \(photos.count) now. Check this sheet."
    }
    if let reference = context.reference {
      labeled.insert(AIPhoto(label: "REFERENCE: an earlier photo of page \(page), the sheet being retaken. It may be unclear.", jpeg: reference), at: 0)
      prompt += " The wearer is retaking page \(page): photos that do not show the REFERENCE sheet belong in otherSheet."
    }
    if let earlier = context.earlier {
      labeled.insert(AIPhoto(label: "EARLIER: page \(page - 1), already done.", jpeg: earlier), at: 0)
      prompt += " Photos that show the EARLIER sheet belong in earlierSheet; the sheet to check is the one in the first photo that does not show it."
    }
    var retried = false, lowered: SpeedTier?
    while true {
      try Task.checkCancellation()
      var provider = configuration.checkCredential.provider
      if failedAccounts.contains(provider), let other = configuration.alternative(to: provider) { provider = other }
      let configured = configuration.credential(provider)
      let preferred = AICredential(provider: provider, key: configured.key, model: SolverConfiguration.checkModel(provider))
      let credential = useConfiguredModel.contains(provider) ? configured : preferred
      let tier = lowered ?? tiers.tier(for: credential, fast: configuration.fastTiers)
      let request = AIRequest(credential: credential, photos: labeled, prompt: prompt, tokenLimit: 8_000, kind: .check, tier: tier)
      do {
        let data = try await transport.send(request)
        tiers.succeeded(credential, tier: tier)
        guard let check = try? JSONDecoder().decode(PageCheck.self, from: data) else {
          throw AIResultError.repairable("The page check returned an unexpected answer.")
        }
        return check.outcome(photos: photos.count)
      } catch {
        if let lower = tiers.stepDown(after: error, from: tier, credential: credential) { lowered = lower; continue }
        if credential.model != configured.model, Self.modelUnavailable(error) {
          useConfiguredModel.insert(provider); lowered = nil; continue
        }
        if (error as? AIServiceError)?.isAccountProblem == true, !failedAccounts.contains(provider),
          configuration.alternative(to: provider) != nil {
          failedAccounts.insert(provider); lowered = nil; continue
        }
        guard !retried, !Task.isCancelled, PageSolver.isTransient(error) else { throw error }
        retried = true
        try await Task.sleep(for: retryDelay)
      }
    }
  }
  /// The account or API version cannot use the fast check model (not a key, billing or rate problem).
  static func modelUnavailable(_ error: any Error) -> Bool {
    guard case .http(_, let status, _, let detail)? = error as? AIServiceError else { return false }
    return [400, 403, 404].contains(status) && detail.lowercased().contains("model")
  }
}

/// Runs `work`, giving up with a timeout after `seconds`.
func withDeadline<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await work() }
    group.addTask { try await Task.sleep(for: .seconds(seconds)); throw URLError(.timedOut) }
    defer { group.cancelAll() }
    guard let value = try await group.next() else { throw URLError(.timedOut) }
    return value
  }
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
  private var tiers = TierMemory()
  private var failedAccounts: Set<AIProvider> = []
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
    // One provider at a time: if its key, credit or spend limit fails, the other saved key solves for the session.
    var configuration = configuration
    if configuration.mode != .both, failedAccounts.contains(configuration.lead.provider),
      let other = configuration.alternative(to: configuration.lead.provider) {
      configuration.mode = other == .claude ? .claude : .openAI
    }
    do { return try await solveOnce(job, configuration: configuration, progress: progress) }
    catch let error as AIServiceError where error.isAccountProblem && configuration.mode != .both {
      let failed = configuration.lead.provider
      guard let other = configuration.alternative(to: failed) else { throw error }
      failedAccounts.insert(failed); configuration.mode = other == .claude ? .claude : .openAI
      progress("\(job.title): \(failed.name) can't be used (\(error.localizedDescription)) Solving with \(other.name) instead.")
      return try await solveOnce(job, configuration: configuration, progress: progress)
    }
  }

  private func solveOnce(_ job: PageJob, configuration: SolverConfiguration,
                         progress: @escaping @Sendable (String) -> Void) async throws -> PageResult {
    let photos = try photos(for: job), task = Self.task(for: job), lead = configuration.lead
    let mustSolve = job.mustSolve, fast = configuration.fastTiers
    guard let peer = configuration.peer else {
      return try await decoded(lead, photos: photos, prompt: task, page: job.number, name: job.title, mustSolve: mustSolve,
        fast: fast, progress: progress)
    }
    async let first = decoded(lead, photos: photos, prompt: task, page: job.number, name: job.title, mustSolve: mustSolve,
      fast: fast, progress: progress)
    async let second = decoded(peer, photos: photos, prompt: task, page: job.number, name: job.title, mustSolve: mustSolve,
      fast: fast, progress: progress)
    let (a, b) = try await (first, second)
    let required = Set((a.solutions + b.solutions).map(\.label))
    return try await decoded(lead, photos: photos, prompt: task + Self.reconcile(a, b, lead: lead.provider, peer: peer.provider),
      page: job.number, name: job.title, mustCover: required, mustSolve: mustSolve, fast: fast, progress: progress)
  }

  /// One repair for malformed, truncated or self-inconsistent output. Never for refusals or unreadable pages.
  private func decoded(_ credential: AICredential, photos: [AIPhoto], prompt: String, page: Int, name: String, mustCover: Set<String> = [],
                       mustSolve: [String] = [], fast: Bool, progress: @escaping @Sendable (String) -> Void) async throws -> PageResult {
    var correction = ""
    for attempt in 0..<2 {
      try Task.checkCancellation()
      do {
        // High effort thinks longer, and thinking counts toward the output limit.
        let data = try await send(AIRequest(credential: credential, photos: photos, prompt: prompt + correction,
          tokenLimit: SolverClient.outputLimit(attempt == 0 ? 64_000 : 96_000, model: credential.model)), fast: fast, name: name,
          progress: progress)
        try Task.checkCancellation()
        let result: PageResult
        do { result = try JSONDecoder().decode(PageResult.self, from: data) }
        catch { throw AIResultError.repairable("The response did not contain the required complete JSON result.") }
        try result.validate(page: page, name: name, mustCover: mustCover, mustSolve: mustSolve)
        return result
      } catch AIResultError.repairable(let reason) {
        guard attempt == 0 else {
          throw SolverError.message("\(name): \(credential.provider.name) still returned an incomplete result. \(reason) Your pages are saved; solve again to retry it.")
        }
        progress("\(name): \(credential.provider.name) is completing an unfinished answer.")
        correction = "\nREPAIR REQUIRED: \(reason) Return the COMPLETE JSON for this page, keep worked steps concise, and fill every field. Do not guess unreadable text."
      }
    }
    throw SolverError.message("Could not finish page \(page).")
  }

  /// Bounded retries for overloads, rate limits and dropped connections only.
  /// A refused speed tier is resent at once at the next lower tier; that does not count as a retry.
  private func send(_ request: AIRequest, fast: Bool, name: String, progress: @escaping @Sendable (String) -> Void) async throws -> Data {
    var request = request, retries = 0
    request.tier = tiers.tier(for: request.credential, fast: fast)
    while true {
      try Task.checkCancellation()
      await limiter.acquire()
      do {
        let data = try await transport.send(request)
        await limiter.release()
        tiers.succeeded(request.credential, tier: request.tier)
        return data
      } catch {
        await limiter.release()
        if let lower = tiers.stepDown(after: error, from: request.tier, credential: request.credential) { request.tier = lower; continue }
        guard retries < retryDelays.count, !Task.isCancelled, Self.isTransient(error) else { throw error }
        let delay = (error as? AIServiceError)?.retryAfter.map { Duration.seconds(min(max($0, 1), 20)) } ?? retryDelays[retries]
        retries += 1
        progress("\(name): \(request.credential.provider.name) is busy. Retrying (\(retries) of \(retryDelays.count))…")
        try await Task.sleep(for: delay)
      }
    }
  }

  static func isTransient(_ error: any Error) -> Bool {
    if let error = error as? AIServiceError { return error.isRetryable }
    if let error = error as? URLError {
      // An idle timeout after minutes of silence would only repeat; dropped connections are worth a retry.
      return [.networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .notConnectedToInternet].contains(error.code)
    }
    return false
  }

  private func photos(for job: PageJob) throws -> [AIPhoto] {
    func labeled(_ urls: [URL], _ title: String) throws -> [AIPhoto] {
      try urls.enumerated().map { index, url in
        AIPhoto(label: urls.count == 1 ? title + ":" : title + ", photo \(index + 1) of \(urls.count):", jpeg: try upload(url))
      }
    }
    return try labeled(job.previousFrames, "PREVIOUS page (source page \(job.number - 1)), context only")
      + labeled(job.primaryFrames, "PRIMARY page (source page \(job.number)), solve this page")
      + labeled(job.nextFrames, "NEXT page (source page \(job.number + 1)), context for continued questions only")
  }
  /// Each photo is downsized once and reused as primary and as neighbor context.
  private func upload(_ url: URL) throws -> Data {
    if let cached = uploads[url] { return cached }
    let data = try SolverClient.uploadPhoto(try Data(contentsOf: url))
    uploads[url] = data
    return data
  }

  static func task(for job: PageJob) -> String {
    let parts = job.primaryFrames.count < 2 ? "" : " The PRIMARY page is shown as \(job.primaryFrames.count) close-up photos of parts of the same sheet, in the order they were taken. They may overlap: an item seen in several photos is ONE item; read it from its clearest photo and join an item cut across photos. Neighbor pages may also be shown only in part."
    var text = """
    Solve the PRIMARY page (source page \(job.number) of the packet). The images are labeled.\(parts)
    OWNERSHIP RULE: every answerable item (a question, or each lettered/numbered subpart) belongs to the page where its OWN label first appears.
    \(job.previous == nil ? "There is no previous page." : "The PREVIOUS page provides shared stems, data and figures for items on the PRIMARY page.")
    \(job.next == nil ? "There is no next page: the PRIMARY page is the last page of the packet." : "Use the NEXT page only to finish an item whose own text is cut off at the bottom of the PRIMARY page.")
    checklist: the full label of every answerable item whose label is visible on the PRIMARY page, in order; when a question has subparts, list the subparts, not the parent number.
    solutions: completely solve every checklist item this page owns, using the other pages for shared context. sourcePages lists every source page number the solution uses.
    skipped: list an item, with the reason, only if its OWN label already appears on the PREVIOUS page (its continuation, or a repeated/overlapping photo). Never skip for any other reason, and never skip a subpart just because its parent question began earlier.
    readable: false only if essential content of an item this page owns cannot be read in ANY of the PRIMARY photos (several photos may show the same part, some blurred: read each item from its clearest photo). Then retake names the question and says exactly what to recapture. Otherwise retake is an empty string.
    Copy every given number, sign and unit exactly from the clearest photo. If a value reads differently in different photos and the clearest one is still ambiguous, use status needs_review and give both readings in reviewNote.
    title: a short title for the topic of the packet. reviewNote: empty when solved; otherwise exactly what is unresolved. For unresolved items, steps, answer and check state what can and cannot be determined.
    """
    if !job.mustSolve.isEmpty {
      text += "\nThe previous page did not solve these items, so they MUST be solved here, not skipped: \(job.mustSolve.joined(separator: ", "))."
    }
    return text
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
