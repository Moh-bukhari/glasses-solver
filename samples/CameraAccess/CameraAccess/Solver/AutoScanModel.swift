import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class AutoScanModel {
  enum Phase: String { case idle, connecting, seeking, awaitingNext, capturing, checking, solving, saving, finished, failed }
  /// Per-page solving status shown on the page queue.
  enum PageState: Equatable { case waiting, queued, solving, solved, failed(String) }
  static let maxPages = 30

  private(set) var phase: Phase = .idle
  private(set) var guide = "Tap Start and look at the first page. Give a thumbs-up when you're done."
  private(set) var voiceStatus = ""
  private(set) var solveStatus = ""
  private(set) var progress = 0.0
  private(set) var preview: CGImage?
  private(set) var sample = PageSample()
  private(set) var result: SavedSolution?
  private(set) var capturedPreview: UIImage?
  private(set) var pages: [CapturedPage] = []
  private(set) var thumbnails: [UUID: UIImage] = [:]
  private(set) var pageStates: [UUID: PageState] = [:]
  private(set) var attempts = 0
  private(set) var needsKey = false
  var showPDF = false
  var voiceGuidance = true
  var voiceCommands = false
  var cueVolume: Float = ScanVoice.quietVolume
  var privateAudio = true
  var gesturesEnabled = true
  var glassesButtons = true
  var solveWhileScanning = true
  var isRunning: Bool { [.connecting, .seeking, .awaitingNext, .capturing, .checking, .solving, .saving].contains(phase) }
  var isCollecting: Bool { [.seeking, .awaitingNext, .capturing, .checking].contains(phase) }
  var canFinish: Bool { !pages.isEmpty && [.idle, .failed, .seeking, .awaitingNext].contains(phase) }
  var solvedPages: Int { pages.filter { pageStates[$0.id] == .solved }.count }

  @ObservationIgnored private let camera: any ScanCamera
  @ObservationIgnored private let analyzer: any PageAnalyzing
  @ObservationIgnored private let solver: any PageSolving
  @ObservationIgnored private let saver: any SolutionSaving
  @ObservationIgnored private let draft: ScanDraftStore
  @ObservationIgnored private let configurationProvider: () -> SolverConfiguration
  @ObservationIgnored private let voice: any ScanSpeaking
  @ObservationIgnored private var worker: Task<Void, Never>?
  @ObservationIgnored private var analysisTask: Task<Void, Never>?
  @ObservationIgnored private var runID = UUID()
  @ObservationIgnored private var gate = StabilityGate()
  @ObservationIgnored private var turnGate = PageTurnGate()
  @ObservationIgnored private var gestureGate = GestureGate()
  @ObservationIgnored private var lastFrameTime = -Double.infinity
  @ObservationIgnored private var awaitingSince = 0.0
  @ObservationIgnored private var speechGate = GuidanceSpeechGate()
  @ObservationIgnored private var previousIdleTimer: Bool?
  @ObservationIgnored private var imported = false
  @ObservationIgnored private var replacing: Int?
  @ObservationIgnored private var finishRequested = false
  @ObservationIgnored private var forceCapture = false
  @ObservationIgnored private var captureFailures = 0
  @ObservationIgnored private var backgroundWork: UIBackgroundTaskIdentifier = .invalid
  // Page solving: jobs are keyed by page + neighbors + provider setup; results are reused until that changes.
  @ObservationIgnored private var solveSetup: SolverConfiguration?
  @ObservationIgnored private var planFinal = false
  @ObservationIgnored private var jobs: [PageJobKey: (token: UUID, task: Task<Void, Never>)] = [:]
  @ObservationIgnored private var results: [PageJobKey: (number: Int, result: PageResult)] = [:]
  @ObservationIgnored private var jobErrors: [PageJobKey: String] = [:]

  init(camera: any ScanCamera, analyzer: any PageAnalyzing = PageAnalyzer(),
       solver: any PageSolving = PageSolver(), saver: any SolutionSaving = SolutionStore(),
       draft: ScanDraftStore = ScanDraftStore(), voice: any ScanSpeaking = ScanVoice(),
       configurationProvider: @escaping () -> SolverConfiguration = { SolverKeychain.configuration() }) {
    self.camera = camera; self.analyzer = analyzer; self.solver = solver; self.saver = saver
    self.draft = draft; self.voice = voice; self.configurationProvider = configurationProvider
    pages = draft.load()
    loadThumbnails()
    if !pages.isEmpty { guide = "Restored \(pages.count) saved pages. Continue scanning, or finish to solve them." }
    camera.onFrame = { [weak self] image in self?.receive(image) }
    camera.onProblem = { [weak self] message in
      guard let self, self.isRunning else { return }
      if [.checking, .solving, .saving].contains(self.phase) { self.camera.stop() }
      else { self.fail(message + " Your saved pages are kept.") }
    }
    camera.onProgress = { [weak self] fraction in
      guard let self, self.phase == .capturing else { return }
      self.progress = fraction
    }
    camera.onNotice = { [weak self] message in self?.guide = message; self?.say(message) }
    camera.onShutter = { [weak self] in self?.shutter() }
    camera.onCommand = { [weak self] command in self?.handle(command) }
    voice.onCommand = { [weak self] command in self?.handle(command) }
    voice.onStatus = { [weak self] message in self?.voiceStatus = message }
  }

  // MARK: Scanning

  func start(replacing index: Int? = nil) {
    guard !isRunning || [.seeking, .awaitingNext].contains(phase) else { return }
    guard pages.count < Self.maxPages || index != nil else {
      guide = "\(Self.maxPages) pages saved. Finish this packet first."; return
    }
    if let index, !pages.indices.contains(index) { return }
    begin(imported: false); replacing = index
    planFinal = false
    let configuration = configurationProvider()
    solveSetup = solveWhileScanning && (try? configuration.validate()) != nil ? configuration : nil
    syncJobs()
    let id = runID
    phase = .connecting; guide = "Connecting to your glasses…"
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        if voiceCommands {
          guide = "Preparing voice commands…"; voiceStatus = "Checking microphone and speech permissions…"
          await voice.startCommands()
          try Task.checkCancellation(); guard runID == id else { return }
        } else { voiceStatus = ""; voice.prepareOutput() }
        guide = "Connecting to your glasses…"
        try await camera.start(); try Task.checkCancellation()
        guard runID == id else { return }
        phase = .seeking
        if let index {
          guide = "Show page \(index + 1) again, close and steady."; say("Show page \(index + 1) again.")
        } else {
          guide = "Look at page \(pages.count + 1), close and steady. Thumbs-up when you're done."
          say(pages.isEmpty ? "Ready. Look at the first page." : "Ready for page \(pages.count + 1).")
        }
      } catch { guard runID == id else { return }; fail(error.localizedDescription) }
    }
  }

  func importPhoto(_ data: Data, replacing index: Int? = nil) {
    guard !isRunning, pages.count < Self.maxPages || index != nil else { return }
    if let index, !pages.indices.contains(index) { return }
    begin(imported: true); replacing = index
    let id = runID; phase = .checking; guide = "Checking the selected photo…"
    worker = Task { [weak self] in await self?.process(data: data, id: id) }
  }

  func nextPage() {
    guard phase == .awaitingNext else { return }
    guard pages.count < Self.maxPages else { guide = "Page limit reached. Give a thumbs-up to finish."; say(guide); return }
    gate.reset(); turnGate.reset(); progress = 0; attempts = 0; forceCapture = false; phase = .seeking
    guide = "Page \(pages.count + 1): hold it close and steady."; say("Page \(pages.count + 1).")
  }

  /// One command path for glasses clicks, hand gestures, the screen, and optional voice.
  func handle(_ command: ScanCommand) {
    switch command {
    case .finish:
      guard !pages.isEmpty || [.capturing, .checking].contains(phase) else {
        if isCollecting { guide = "Scan at least one page first."; say("Scan a page first.") }
        return
      }
      finishScanning()
    case .next:
      if phase == .awaitingNext { nextPage() }
      else if phase == .seeking { forceCapture = true; guide = "Taking it as soon as the writing is clear…" }
    case .retakeLast:
      guard !pages.isEmpty, [.seeking, .awaitingNext].contains(phase) else { return }
      replacing = pages.count - 1; attempts = 0; forceCapture = false
      gate.reset(); turnGate.reset(); progress = 0; phase = .seeking
      guide = "Retaking page \(pages.count). The old photo stays until the new one is clear."
      say("Retaking page \(pages.count).")
    case .cancel: stop()
    }
  }

  func removePage(at index: Int) {
    guard !isRunning else { return }
    do {
      pages = try draft.remove(at: index, from: pages); pruneThumbnails()
      guide = "\(pages.count) pages saved."; syncJobs()
    } catch { guide = "Could not remove the saved page. \(error.localizedDescription)" }
  }
  func reloadDraft() {
    guard !isRunning else { return }
    pages = draft.load(); loadThumbnails(); refreshPageStates()
  }
  func newBatch() {
    guard !isRunning else { return }
    clearPacket()
    result = nil; capturedPreview = nil; preview = nil; phase = .idle
    guide = "Ready for a new packet. Tap Start."
  }
  /// User pause/stop: ends scanning and any solving in progress. Finished page results stay cached.
  func stop() {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel()
    worker = nil; analysisTask = nil
    for job in jobs.values { job.task.cancel() }
    jobs = [:]
    camera.stop(); gate.reset(); turnGate.reset(); gestureGate.reset()
    voice.stopCommands(); voice.stopSpeaking(); phase = .idle; progress = 0
    guide = "Paused. \(pages.count) pages remain saved."; restoreIdleTimer(); endBackgroundWork()
    refreshPageStates()
  }
  /// Leaving the screen stops the camera but never cancels page solving or PDF creation.
  func backgrounded() {
    guard isCollecting else { return } // `connecting` may hand off to Meta AI for permission
    pauseScanning("Paused when the app left the screen. Your pages are saved; tap Continue when ready.")
  }
  func viewDisappeared() {
    guard isCollecting || phase == .connecting else { return }
    pauseScanning("Scanning paused. Your pages are saved.")
  }
  private func pauseScanning(_ message: String) {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel(); worker = nil; analysisTask = nil
    camera.stop(); gate.reset(); turnGate.reset(); gestureGate.reset(); voice.stopCommands()
    phase = .idle; progress = 0; guide = message; restoreIdleTimer()
  }

  private func begin(imported: Bool) {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel(); analysisTask = nil
    camera.stop(); voice.stopCommands(); voice.stopSpeaking()
    gate.reset(); turnGate.reset(); speechGate.reset(); gestureGate.reset()
    self.imported = imported; replacing = nil; finishRequested = false; forceCapture = false; captureFailures = 0
    result = nil; showPDF = false; progress = 0; attempts = 0; solveStatus = ""
    sample = PageSample(); preview = nil; lastFrameTime = -Double.infinity
    camera.glassesButtons = glassesButtons; voice.privateOnly = privateAudio
    if previousIdleTimer == nil { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled }
    UIApplication.shared.isIdleTimerDisabled = true
  }

  private func receive(_ image: CGImage) {
    guard [.seeking, .awaitingNext].contains(phase) else { return }
    preview = image
    let time = ProcessInfo.processInfo.systemUptime
    // Analyze every delivered frame; one analysis in flight throttles itself when Vision is slower.
    guard analysisTask == nil, time - lastFrameTime >= 0.12 else { return }
    lastFrameTime = time; let id = runID
    analysisTask = Task { [weak self] in
      guard let self else { return }
      do {
        let value = try await analyzer.analyze(image, still: false)
        try Task.checkCancellation()
        guard runID == id else { return }
        analysisTask = nil
        guard [.seeking, .awaitingNext].contains(phase) else { return }
        sample = value
        if gesturesEnabled {
          if let gesture = gestureGate.observe(value.gesture, at: time) { handle(gesture: gesture); return }
          // Never photograph or page-turn while a command hand is raised.
          if value.gesture != nil { gate.reset(); progress = 0; guide = "Hold the gesture for a moment…"; return }
        }
        if phase == .awaitingNext {
          if pages.count < Self.maxPages, turnGate.observe(value, at: time) { nextPage() }
          else if time - awaitingSince > 4, value.acceptable, !value.closeEnough { speakCue(.closer, at: time) }
          return
        }
        progress = gate.observe(value, at: time)
        let forced = forceCapture && value.acceptable && value.closeEnough
        if !forced && (!value.acceptable || !value.closeEnough) {
          let cue = !value.closeEnough && value.cue == .hold ? ScanCue.closer : value.cue
          guide = value.issue ?? cue.message; speakCue(cue, at: time)
        } else if !forced && progress < 1 {
          let cue: ScanCue = progress >= 0.5 ? .hold : value.cue
          guide = cue == .hold ? "Hold still… \(Int(progress * 100))%" : cue.message
          speakCue(cue, at: time)
        } else {
          beginCapture(value, at: time, id: id)
        }
      } catch {
        guard runID == id else { return }
        analysisTask = nil; fail("Could not inspect the camera image. \(error.localizedDescription)")
      }
    }
  }

  private func handle(gesture: HandGesture) {
    switch gesture {
    case .thumbsUp: handle(.finish)
    case .thumbsDown: handle(.retakeLast)
    case .openPalm: handle(.next)
    }
  }

  private func beginCapture(_ value: PageSample, at time: TimeInterval, id: UUID) {
    forceCapture = false
    phase = .capturing; guide = "Taking page \((replacing ?? pages.count) + 1). Keep still…"; progress = 0
    say("Hold still.")
    turnGate.saved(value, at: time)
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        attempts += 1; let data = try await camera.capture()
        try Task.checkCancellation(); guard runID == id else { return }
        captureFailures = 0
        await process(data: data, id: id)
      } catch {
        guard runID == id else { return }
        await captureFailed(error, id: id)
      }
    }
  }
  /// The still exists on the glasses: release the wearer to turn the page while it transfers.
  private func shutter() {
    guard phase == .capturing else { return }
    guide = "Got it. Turn to the next page while it saves."; say("Got it.")
  }
  /// A dropped transfer is retried by looking at the page again; repeated failures stop with the pages kept.
  private func captureFailed(_ error: any Error, id: UUID) async {
    captureFailures += 1
    guard captureFailures < 3, !(error is CancellationError) else { fail(error.localizedDescription); return }
    guide = "The photo didn't come through. Show page \((replacing ?? pages.count) + 1) again."; say(guide)
    do {
      try await resume(id: id); guard runID == id else { return }
      gate.reset(); progress = 0; phase = .seeking
    } catch { guard runID == id else { return }; fail(error.localizedDescription) }
  }

  private func process(data: Data, id: UUID) async {
    // Restart the preview while the still is checked and saved; it is ready for the next page sooner.
    let restart: Task<Void, any Error>? = imported || finishRequested ? nil : Task { [weak self] in
      guard let self else { return }
      try await self.resume(id: id)
    }
    do {
      phase = .checking; progress = 0
      if !guide.hasPrefix("Got it") { guide = "Checking the photo for clear writing…" }
      let photo = try await analyzer.prepare(data)
      try Task.checkCancellation(); guard runID == id else { restart?.cancel(); return }
      if !photo.sample.acceptable || !photo.sample.closeEnough {
        try await restart?.value; guard runID == id else { return }
        try retake(photo.sample.issue ?? "Move closer so the small writing is readable.")
        return
      }
      let index = replacing ?? pages.count
      pages = try draft.add(photo.jpeg, to: pages, replacing: replacing)
      let page = pages[index]
      if let thumbnail = photo.thumbnail { thumbnails[page.id] = UIImage(cgImage: thumbnail) }
      capturedPreview = thumbnails[page.id]; replacing = nil; attempts = 0
      pruneThumbnails()
      syncJobs() // the previous page now has its next-page context and can be solved
      let urls = Set(pages.map(\.url)), solver = self.solver
      Task { await solver.forget(keeping: urls) }
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      if finishRequested {
        restart?.cancel(); finishRequested = false; phase = .idle; finishScanning(); return
      }
      if imported {
        phase = .idle; restoreIdleTimer()
        guide = "Page \(index + 1) saved. Add another photo, or finish to solve."
      } else {
        try await restart?.value
        guard runID == id else { return }
        phase = .awaitingNext; progress = 0; awaitingSince = ProcessInfo.processInfo.systemUptime
        if pages.count < Self.maxPages {
          guide = "Page \(index + 1) saved. Turn the page, or give a thumbs-up to finish."; say("Page \(index + 1) saved.")
        } else {
          guide = "Page limit reached. Give a thumbs-up to finish."; say(guide)
        }
      }
    } catch { restart?.cancel(); guard runID == id else { return }; fail(error.localizedDescription) }
  }
  /// Hands-free scanning keeps guiding instead of giving up after unclear stills.
  private func retake(_ reason: String) throws {
    guard !imported else { throw SolverError.message(reason + " Choose a clearer photo.") }
    let number = (replacing ?? pages.count) + 1
    guide = "That photo wasn't clear. Show page \(number) again. \(reason)"
    say("Show page \(number) again. \(reason)")
    gate.reset(); progress = 0; phase = .seeking
  }
  private func resume(id: UUID) async throws {
    do { try await camera.resumePreview() }
    catch { try Task.checkCancellation(); guard runID == id else { return }; try await camera.start() }
  }

  // MARK: Solving

  func finishScanning() {
    if [.capturing, .checking].contains(phase) {
      finishRequested = true; guide = "Finishing after this photo is saved."; return
    }
    guard canFinish else { return }
    let configuration = configurationProvider()
    do { try configuration.validate(); needsKey = false }
    catch { stop(); needsKey = true; guide = error.localizedDescription; return }
    begin(imported: true)
    solveSetup = configuration // a corrected key or model applies to every page still to solve
    planFinal = true
    jobErrors = [:] // finishing again retries only the pages that failed
    phase = .solving; progress = 0
    syncJobs()
    let remaining = pages.count - solvedPages
    say(remaining == 0 ? "Making your PDF." : "Done scanning. Solving.")
    beginBackgroundWork()
    advanceFinish()
  }

  /// Starts or cancels page jobs so they match the current pages; cached results are reused.
  private func syncJobs() {
    guard let configuration = solveSetup else { refreshPageStates(); return }
    let desired = PagePlan.keys(for: pages.map(\.id), final: planFinal, setup: configuration.setup)
    let wanted = Set(desired), ids = Set(pages.map(\.id))
    for (key, job) in jobs where !wanted.contains(key) { job.task.cancel(); jobs[key] = nil }
    results = results.filter { ids.contains($0.key.page) }
    jobErrors = jobErrors.filter { wanted.contains($0.key) }
    for key in desired where results[key] == nil && jobs[key] == nil && jobErrors[key] == nil {
      startJob(key, configuration)
    }
    refreshPageStates()
  }

  private func startJob(_ key: PageJobKey, _ configuration: SolverConfiguration) {
    guard let index = pages.firstIndex(where: { $0.id == key.page }) else { return }
    let urls = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.url) })
    let job = PageJob(key: key, number: index + 1, primary: pages[index].url,
      previous: key.previous.flatMap { urls[$0] }, next: key.next.flatMap { urls[$0] })
    let token = UUID(), solver = self.solver
    let task = Task { [weak self] in
      let outcome: Result<PageResult, any Error>
      do {
        let value = try await solver.solve(job, configuration: configuration) { message in
          Task { @MainActor [weak self] in self?.solveNotice(message) }
        }
        outcome = .success(value)
      } catch { outcome = .failure(error) }
      self?.jobFinished(key, token: token, number: job.number, outcome: outcome)
    }
    jobs[key] = (token, task)
  }

  private func jobFinished(_ key: PageJobKey, token: UUID, number: Int, outcome: Result<PageResult, any Error>) {
    guard jobs[key]?.token == token else { return } // cancelled or superseded
    jobs[key] = nil
    switch outcome {
    case .success(let value): results[key] = (number, value)
    case .failure(let error): jobErrors[key] = error.localizedDescription
    }
    refreshPageStates()
    if phase == .solving { advanceFinish() }
  }

  private func solveNotice(_ message: String) {
    solveStatus = message
    if phase == .solving { guide = message }
  }

  private func refreshPageStates() {
    let keys = solveSetup.map { PagePlan.keys(for: pages.map(\.id), final: planFinal, setup: $0.setup) } ?? []
    var states: [UUID: PageState] = [:]
    for page in pages {
      guard let key = keys.first(where: { $0.page == page.id }) else { states[page.id] = .waiting; continue }
      if results[key] != nil { states[page.id] = .solved }
      else if let error = jobErrors[key] { states[page.id] = .failed(error) }
      else if jobs[key] != nil { states[page.id] = .solving }
      else { states[page.id] = .queued }
    }
    pageStates = states
  }

  private func advanceFinish() {
    guard phase == .solving, let configuration = solveSetup else { return }
    let keys = PagePlan.keys(for: pages.map(\.id), final: true, setup: configuration.setup)
    let done = keys.filter { results[$0] != nil }.count
    let failed = keys.filter { jobErrors[$0] != nil }
    progress = keys.isEmpty ? 0 : Double(done) / Double(keys.count)
    guard done + failed.count == keys.count else {
      guide = "Solving… \(done) of \(keys.count) pages done."; return
    }
    guard failed.isEmpty else {
      let numbers = failed.compactMap { key in pages.firstIndex { $0.id == key.page }.map { String($0 + 1) } }
      let detail = jobErrors[failed[0]] ?? ""
      let summary = failed.count == 1 ? detail : "Pages \(numbers.joined(separator: ", ")) could not be solved. \(detail)"
      endBackgroundWork()
      fail(summary + " Solved pages are kept; finish again to retry only the rest.")
      return
    }
    let entries: [(number: Int, result: PageResult)] = keys.compactMap { key in
      guard let cached = results[key], let index = pages.firstIndex(where: { $0.id == key.page }) else { return nil }
      // A removed earlier page renumbers later pages without changing their content or context.
      return (index + 1, cached.result.shifted(by: index + 1 - cached.number))
    }
    save(entries, providers: configuration.summary)
  }

  private func save(_ entries: [(number: Int, result: PageResult)], providers: String) {
    let id = runID, sources = pages.map(\.url)
    phase = .saving; progress = 1; guide = "Making your PDF…"
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        let solution = try PagePlan.combine(entries, providers: providers)
        let saved = try await saver.save(page: solution, sources: sources)
        try Task.checkCancellation(); guard runID == id else { return }
        result = saved; phase = .finished
        let review = solution.problems.contains { $0.reviewNote?.hasPrefix("NEEDS REVIEW") == true }
        guide = review ? "Your PDF is ready. Check items marked NEEDS REVIEW." : "Your PDF is ready."
        // The PDF folder now holds every original photo; the next Start begins a fresh packet.
        clearPacket()
        restoreIdleTimer(); endBackgroundWork(); showPDF = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        say("Your solution PDF is ready on your phone.")
      } catch { guard runID == id else { return }; endBackgroundWork(); fail(error.localizedDescription) }
    }
  }

  private func clearPacket() {
    do { try draft.clear() } catch { guide = "Could not clear the previous draft. \(error.localizedDescription)"; return }
    for job in jobs.values { job.task.cancel() }
    jobs = [:]; results = [:]; jobErrors = [:]; solveSetup = nil; planFinal = false
    pages = []; thumbnails = [:]; pageStates = [:]; solveStatus = ""
    let solver = self.solver
    Task { await solver.forget(keeping: []) }
  }

  // MARK: Helpers

  private func fail(_ message: String) {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel(); analysisTask = nil
    camera.stop(); voice.stopCommands(); gate.reset(); restoreIdleTimer()
    phase = .failed; guide = message; progress = 0; say("Paused. " + message)
    refreshPageStates()
  }
  private func loadThumbnails() {
    let missing = pages.filter { thumbnails[$0.id] == nil }
    guard !missing.isEmpty else { return }
    Task { [weak self] in
      let loaded = await Task.detached(priority: .utility) { missing.map { ($0.id, $0.loadThumbnail()) } }.value
      guard let self else { return }
      for (id, image) in loaded { if let image { self.thumbnails[id] = image } }
    }
  }
  private func pruneThumbnails() {
    let ids = Set(pages.map(\.id))
    thumbnails = thumbnails.filter { ids.contains($0.key) }
  }
  private func beginBackgroundWork() {
    guard backgroundWork == .invalid else { return }
    backgroundWork = UIApplication.shared.beginBackgroundTask(withName: "Solve packet") { [weak self] in
      Task { @MainActor [weak self] in self?.endBackgroundWork() }
    }
  }
  private func endBackgroundWork() {
    guard backgroundWork != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundWork); backgroundWork = .invalid
  }
  private func restoreIdleTimer() {
    if let previousIdleTimer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
    previousIdleTimer = nil
  }
  private func speakCue(_ cue: ScanCue, at time: TimeInterval) {
    guard voiceGuidance, speechGate.shouldSpeak(cue, at: time) else { return }
    voice.privateOnly = privateAudio
    voice.say(cue.message, volume: cueVolume)
  }
  private func say(_ message: String) {
    guard voiceGuidance else { return }
    speechGate.noteAnnouncement(at: ProcessInfo.processInfo.systemUptime)
    voice.privateOnly = privateAudio
    voice.say(message, volume: cueVolume)
  }
}
