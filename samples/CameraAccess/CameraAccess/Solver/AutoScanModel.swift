import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class AutoScanModel {
  enum Phase: String { case idle, connecting, seeking, awaitingNext, capturing, checking, solving, saving, finished, failed }
  private(set) var phase: Phase = .idle
  private(set) var guide = "Scan the papers one by one. Finish scanning when the whole set is saved."
  private(set) var voiceStatus = ""
  private(set) var progress = 0.0
  private(set) var preview: CGImage?
  private(set) var sample = PageSample()
  private(set) var result: SavedSolution?
  private(set) var capturedPreview: UIImage?
  private(set) var pages: [CapturedPage] = []
  private(set) var attempts = 0
  private(set) var needsKey = false
  var showPDF = false
  var voiceGuidance = true
  var voiceCommands = true
  var cueVolume: Float = ScanVoice.quietVolume
  var isRunning: Bool { [.connecting, .seeking, .awaitingNext, .capturing, .checking, .solving, .saving].contains(phase) }
  var isCollecting: Bool { [.seeking, .awaitingNext, .capturing, .checking].contains(phase) }
  var canFinish: Bool { !pages.isEmpty && [.idle, .failed, .seeking, .awaitingNext].contains(phase) }

  @ObservationIgnored private let camera: any ScanCamera
  @ObservationIgnored private let analyzer: any PageAnalyzing
  @ObservationIgnored private let solver: any BatchSolving
  @ObservationIgnored private let saver: any SolutionSaving
  @ObservationIgnored private let draft: ScanDraftStore
  @ObservationIgnored private let configurationProvider: () -> SolverConfiguration
  @ObservationIgnored private let voice: any ScanSpeaking
  @ObservationIgnored private var worker: Task<Void, Never>?
  @ObservationIgnored private var analysisTask: Task<Void, Never>?
  @ObservationIgnored private var runID = UUID()
  @ObservationIgnored private var gate = StabilityGate()
  @ObservationIgnored private var turnGate = PageTurnGate()
  @ObservationIgnored private var lastFrameTime = -Double.infinity
  @ObservationIgnored private var speechGate = GuidanceSpeechGate()
  @ObservationIgnored private var previousIdleTimer: Bool?
  @ObservationIgnored private var imported = false
  @ObservationIgnored private var replacing: Int?
  @ObservationIgnored private var finishRequested = false

  init(camera: any ScanCamera, analyzer: any PageAnalyzing = PageAnalyzer(),
       solver: any BatchSolving = BatchSolver(), saver: any SolutionSaving = SolutionStore(),
       draft: ScanDraftStore = ScanDraftStore(), voice: any ScanSpeaking = ScanVoice(),
       configurationProvider: @escaping () -> SolverConfiguration = { SolverKeychain.configuration() }) {
    self.camera = camera; self.analyzer = analyzer; self.solver = solver; self.saver = saver
    self.draft = draft; self.voice = voice; self.configurationProvider = configurationProvider
    pages = draft.load()
    if !pages.isEmpty { guide = "Restored \(pages.count) saved pages. Continue scanning or finish the batch." }
    camera.onFrame = { [weak self] image in self?.receive(image) }
    camera.onProblem = { [weak self] message in
      guard let self, self.isRunning else { return }
      if [.checking, .solving, .saving].contains(self.phase) { self.camera.stop() }
      else { self.fail(message + " Your saved pages are kept.") }
    }
    camera.onProgress = { [weak self] fraction in
      guard let self, self.phase == .capturing else { return }
      self.progress = fraction; self.guide = "Receiving photo… \(Int(fraction * 100))%"
    }
    camera.onNotice = { [weak self] message in self?.guide = message; self?.say(message) }
    voice.onCommand = { [weak self] command in self?.handle(command) }
    voice.onStatus = { [weak self] message in self?.voiceStatus = message }
  }

  func start(replacing index: Int? = nil) {
    guard !isRunning || [.seeking, .awaitingNext].contains(phase) else { return }
    guard pages.count < 12 || index != nil else { guide = "12 pages saved. Finish this batch before starting another."; return }
    if let index, !pages.indices.contains(index) { return }
    begin(imported: false); replacing = index
    let id = runID
    phase = .connecting; guide = "Connecting to your glasses…"
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        if voiceCommands {
          guide = "Preparing hands-free commands…"; voiceStatus = "Checking microphone and speech permissions…"
          await voice.startCommands()
          try Task.checkCancellation(); guard runID == id else { return }
        } else { voiceStatus = "Voice commands are off. Use Finish scanning on screen." }
        guide = "Connecting to your glasses…"
        try await camera.start(); try Task.checkCancellation()
        guard runID == id else { return }
        phase = .seeking; guide = "Bring the writing close enough to read. Keep all parts of this problem in view."
        say(index == nil ? "Ready for page \(pages.count + 1). Move close to the writing." : "Replacing page \(index! + 1). Look at that page.")
      } catch { guard runID == id else { return }; fail(error.localizedDescription) }
    }
  }

  func importPhoto(_ data: Data, replacing index: Int? = nil) {
    guard !isRunning, pages.count < 12 || index != nil else { return }
    if let index, !pages.indices.contains(index) { return }
    begin(imported: true); replacing = index
    let id = runID; phase = .checking; guide = "Checking the selected photo…"
    worker = Task { [weak self] in await self?.process(data: data, id: id) }
  }

  func finishScanning() {
    if [.capturing, .checking].contains(phase) {
      finishRequested = true; guide = "Finishing after the current photo is saved."; return
    }
    guard canFinish else { return }
    let configuration = configurationProvider()
    do { try configuration.validate(); needsKey = false }
    catch { stop(); needsKey = true; guide = error.localizedDescription; return }
    begin(imported: true)
    let id = runID, batch = pages
    phase = .solving; guide = "Starting the full packet solution…"
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        let jpegs = try batch.map { try Data(contentsOf: $0.url) }
        let solution = try await solver.solve(pages: jpegs, configuration: configuration) { [weak self] message in
          Task { @MainActor [weak self] in
            guard let self, self.runID == id, self.phase == .solving else { return }
            self.guide = message; self.say(message)
          }
        }
        try Task.checkCancellation(); guard runID == id else { return }
        guard solution.readable, !solution.problems.isEmpty else {
          throw SolverError.message("The packet could not be completely read. \(solution.retakeReason)")
        }
        phase = .saving; guide = "Compiling every answer and source photo into one PDF."; say(guide)
        let saved = try saver.save(page: solution, jpegs: jpegs)
        try Task.checkCancellation(); guard runID == id else { return }
        result = saved; phase = .finished; guide = "Your combined PDF is ready. Check any items marked NEEDS REVIEW."
        restoreIdleTimer(); showPDF = true; say("Your combined solution PDF is ready on your phone.")
        // Keep the draft until New batch, so a disputed transcription can still be replaced.
      } catch { guard runID == id else { return }; fail(error.localizedDescription) }
    }
  }

  func nextPage() {
    guard phase == .awaitingNext else { return }
    guard pages.count < 12 else { guide = "12 pages saved. Say finish scanning."; say(guide); return }
    gate.reset(); turnGate.reset(); progress = 0; attempts = 0; phase = .seeking
    guide = "Ready for page \(pages.count + 1). Hold the next page close and steady."; say(guide)
  }
  func handle(_ command: ScanCommand) {
    switch command {
    case .finish: finishScanning()
    case .next: nextPage()
    case .retakeLast:
      guard !pages.isEmpty, [.seeking, .awaitingNext].contains(phase) else { return }
      replacing = pages.count - 1; attempts = 0; gate.reset(); turnGate.reset(); phase = .seeking
      guide = "Retaking page \(pages.count). The old photo stays saved until the replacement is clear."; say(guide)
    case .cancel: stop()
    }
  }
  func removePage(at index: Int) {
    guard !isRunning else { return }
    do { pages = try draft.remove(at: index, from: pages); guide = "\(pages.count) pages saved." }
    catch { guide = "Could not remove the saved page. \(error.localizedDescription)" }
  }
  func reloadDraft() { if !isRunning { pages = draft.load() } }
  func newBatch() {
    guard !isRunning else { return }
    do {
      try draft.clear(); pages = []; result = nil; capturedPreview = nil; preview = nil; phase = .idle
      guide = "Ready for a new batch of papers."
    } catch { guide = "Could not clear the previous draft. \(error.localizedDescription)" }
  }
  func stop() {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel()
    worker = nil; analysisTask = nil; camera.stop(); gate.reset(); turnGate.reset()
    voice.stopCommands(); voice.stopSpeaking(); phase = .idle; progress = 0
    guide = "Paused. \(pages.count) pages remain saved."; restoreIdleTimer()
  }
  func backgrounded() {
    guard isRunning, phase != .connecting else { return }
    stop(); guide = "Paused when the app left the screen. Your pages are saved; resume when ready."
  }
  private func begin(imported: Bool) {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel(); analysisTask = nil
    camera.stop(); voice.stopCommands(); voice.stopSpeaking(); gate.reset(); turnGate.reset(); speechGate.reset()
    self.imported = imported; replacing = nil; finishRequested = false
    result = nil; showPDF = false; progress = 0; attempts = 0
    sample = PageSample(); preview = nil; lastFrameTime = -Double.infinity
    if previousIdleTimer == nil { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled }
    UIApplication.shared.isIdleTimerDisabled = true
  }
  private func receive(_ image: CGImage) {
    guard [.seeking, .awaitingNext].contains(phase) else { return }
    preview = image
    let time = ProcessInfo.processInfo.systemUptime
    guard analysisTask == nil, time - lastFrameTime >= 0.33 else { return }
    lastFrameTime = time; let id = runID
    analysisTask = Task { [weak self] in
      guard let self else { return }
      do {
        let value = try await analyzer.analyze(image, still: false)
        try Task.checkCancellation()
        guard runID == id, [.seeking, .awaitingNext].contains(phase) else { return }
        analysisTask = nil; sample = value
        if phase == .awaitingNext {
          if pages.count < 12, turnGate.observe(value, at: time) { nextPage() }
          return
        }
        progress = gate.observe(value, at: time)
        if !value.acceptable || !value.closeEnough {
          let cue = !value.closeEnough && value.cue == .hold ? ScanCue.closer : value.cue
          guide = value.issue ?? cue.message; speakCue(cue, at: time)
        } else if progress < 1 {
          let cue: ScanCue = progress >= 0.5 ? .hold : value.cue
          guide = cue == .hold ? "Hold still… \(Int(progress * 100))%" : cue.message
          speakCue(cue, at: time)
        } else {
          phase = .capturing; guide = "Taking page \((replacing ?? pages.count) + 1). Keep still…"; progress = 0
          say("Hold. Taking the photo.")
          turnGate.saved(value, at: time)
          worker = Task { [weak self] in
            guard let self else { return }
            do {
              attempts += 1; let data = try await camera.capture()
              try Task.checkCancellation(); guard runID == id else { return }
              await process(data: data, id: id)
            } catch { guard runID == id else { return }; fail(error.localizedDescription) }
          }
        }
      } catch {
        guard runID == id else { return }
        analysisTask = nil; fail("Could not inspect the camera image. \(error.localizedDescription)")
      }
    }
  }
  private func process(data: Data, id: UUID) async {
    do {
      phase = .checking; guide = "Checking the photo for clear writing…"; progress = 0
      let photo = try await analyzer.prepare(data)
      try Task.checkCancellation(); guard runID == id else { return }
      if !photo.sample.acceptable || !photo.sample.closeEnough {
        try await retake(photo.sample.issue ?? "Move closer so the small writing is readable.", id: id); return
      }
      let pageNumber = (replacing ?? pages.count) + 1
      pages = try draft.add(photo.jpeg, to: pages, replacing: replacing)
      capturedPreview = pages[pageNumber - 1].thumbnail; replacing = nil; attempts = 0
      guide = "Page \(pageNumber) saved. \(pages.count) pages in this batch."; say(guide)
      if finishRequested {
        finishRequested = false; phase = .idle; finishScanning(); return
      }
      if imported {
        phase = .idle; restoreIdleTimer()
        guide += " Add another photo, or finish scanning."
      } else {
        try await resume(id: id)
        guard runID == id else { return }
        phase = .awaitingNext; progress = 0
        guide = pages.count < 12 ? "Page \(pageNumber) saved. Turn to the next page, or say finish scanning." : "12 pages saved. Say finish scanning."
        say(guide)
      }
    } catch { guard runID == id else { return }; fail(error.localizedDescription) }
  }
  private func retake(_ reason: String, id: UUID) async throws {
    guard !imported else { throw SolverError.message(reason + " Choose a clearer photo.") }
    guard attempts < 3 else { throw SolverError.message("Three attempts were unclear. " + reason + " Earlier pages are saved.") }
    guide = reason; say(reason)
    try await Task.sleep(for: .seconds(2)); try Task.checkCancellation()
    guard runID == id else { return }
    try await resume(id: id); guard runID == id else { return }
    gate.reset(); progress = 0; phase = .seeking; guide = reason
  }
  private func resume(id: UUID) async throws {
    do { try await camera.resumePreview() }
    catch { try Task.checkCancellation(); guard runID == id else { return }; try await camera.start() }
  }
  private func fail(_ message: String) {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel(); analysisTask = nil
    camera.stop(); voice.stopCommands(); gate.reset(); restoreIdleTimer()
    phase = .failed; guide = message; progress = 0; say("Paused. " + message)
  }
  private func restoreIdleTimer() {
    if let previousIdleTimer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
    previousIdleTimer = nil
  }
  private func speakCue(_ cue: ScanCue, at time: TimeInterval) {
    guard voiceGuidance, speechGate.shouldSpeak(cue, at: time) else { return }
    voice.say(cue.message, volume: cueVolume)
  }
  private func say(_ message: String) {
    guard voiceGuidance else { return }
    speechGate.noteAnnouncement(at: ProcessInfo.processInfo.systemUptime)
    voice.say(message, volume: cueVolume)
  }
}
