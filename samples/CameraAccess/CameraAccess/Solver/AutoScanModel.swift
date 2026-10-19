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
  private(set) var guide = "Tap Start (or use the Start Glasses Scan shortcut) and look at the first page. Thumbs-up when you're done."
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
  /// Increments on every failed finish for a missing key, so the view reopens Settings each time.
  private(set) var keyPrompts = 0
  /// The saved pages produced the current PDF. Editing a page re-opens the packet; Start begins a new one.
  private(set) var packetSolved = false
  /// Bumped by the launch shortcut; the app shows Auto Scan and starts once it is in the foreground.
  private(set) var shortcutRequests = 0
  private(set) var shortcutPending = false
  var showPDF = false
  var voiceGuidance = true
  var voiceCommands = false
  var cueVolume: Float = ScanVoice.quietVolume
  var privateAudio = true
  var gesturesEnabled = true
  var glassesButtons = false
  var solveWhileScanning = true
  var isRunning: Bool { [.connecting, .seeking, .awaitingNext, .capturing, .checking, .solving, .saving].contains(phase) }
  var isCollecting: Bool { [.seeking, .awaitingNext, .capturing, .checking].contains(phase) }
  var canFinish: Bool { !pages.isEmpty && !packetSolved && [.idle, .failed, .seeking, .awaitingNext].contains(phase) }
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
  @ObservationIgnored private var previewTask: Task<Void, any Error>?
  @ObservationIgnored private var cameraProblem: String?
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
  /// Pages already re-solved once to claim an item that both neighbors skipped.
  @ObservationIgnored private var claimed: Set<PageJobKey> = []
  /// Photos the AI could not read, with its advice. A retake gives the page a new id, which clears its entry.
  @ObservationIgnored private var unclear: [UUID: String] = [:]
  // Fuller spoken help is given once per scan run; later cues stay short.
  @ObservationIgnored private var helpGiven: Set<String> = []
  @ObservationIgnored private var lastGestureHint = -Double.infinity
  @ObservationIgnored private var nextHintGiven = false
  // Hands-free control: the wearer never needs the phone between the shortcut and the PDF.
  /// The packet is being scanned with the glasses, so unclear pages and failures are handled with gestures.
  @ObservationIgnored private var handsFree = false
  /// After Finish, asking again for pages the AI could not read; solving resumes once they are retaken.
  @ObservationIgnored private var fixing = false
  /// Unreadable pages the wearer chose to solve without (thumbs-up while asked for them).
  @ObservationIgnored private var leftOut: Set<UUID> = []
  /// The page photographed last, which 👈 retakes first.
  @ObservationIgnored private var lastSaved: Int?
  /// The camera stays on but waits for 👉 instead of a page turn, because the sheet in view was scanned before.
  @ObservationIgnored private var holdForNext = false
  /// A retake of a page that is not in view captures only after the view changes, or after `armTimeout`.
  @ObservationIgnored private var armAfterTurn = false
  @ObservationIgnored private var armGate = PageTurnGate()
  @ObservationIgnored private var armDeadline = Double.infinity
  /// Recent clear views without a hand, to remember what was in view before a gesture was raised.
  @ObservationIgnored private var recentViews: [(time: TimeInterval, sample: PageSample)] = []
  @ObservationIgnored private var lastActivity = 0.0
  static let armTimeout: TimeInterval = 6
  /// The camera stops after this long without a new page or gesture, so a forgotten scan doesn't drain the glasses.
  static let idleLimit: TimeInterval = 300

  init(camera: any ScanCamera, analyzer: any PageAnalyzing = PageAnalyzer(),
       solver: any PageSolving = PageSolver(), saver: any SolutionSaving = SolutionStore(),
       draft: ScanDraftStore = ScanDraftStore(), voice: any ScanSpeaking = ScanVoice(),
       configurationProvider: @escaping () -> SolverConfiguration = { SolverKeychain.configuration() }) {
    self.camera = camera; self.analyzer = analyzer; self.solver = solver; self.saver = saver
    self.draft = draft; self.voice = voice; self.configurationProvider = configurationProvider
    pages = draft.load()
    packetSolved = !pages.isEmpty && draft.isSolved
    loadThumbnails()
    if packetSolved { guide = "Your last packet is solved. Tap Start for a new packet, or retake a page to fix it." }
    else if !pages.isEmpty { guide = "Restored \(pages.count) saved pages. Continue scanning, or finish to solve them." }
    camera.onFrame = { [weak self] image in self?.receive(image) }
    camera.onProblem = { [weak self] message in
      guard let self, self.isRunning else { return }
      if [.checking, .solving, .saving].contains(self.phase) {
        // A hands-free check finishes saving its photo, then stops with this message instead of waiting forever.
        if self.phase == .checking, !self.imported { self.cameraProblem = message }
        self.cancelPreviewRestart(); self.camera.stop()
      } else { self.fail(message + " Your saved pages are kept.") }
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
    if index == nil && packetSolved { clearPacket() } // one button: after a PDF, Start begins a new packet
    begin(imported: false); replacing = index
    planFinal = false; helpGiven = []; handsFree = true; fixing = false; lastSaved = nil
    refreshSolveSetup()
    syncJobs()
    let keyMissing = (try? configurationProvider().validate()) == nil
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
        if voiceGuidance && privateAudio && !voice.routeIsPrivate {
          voiceStatus = "Glasses audio isn't connected, so directions are shown on screen only."
        }
        guide = "Connecting to your glasses…"
        try await camera.start(); try Task.checkCancellation()
        guard runID == id else { return }
        phase = .seeking; noteActivity()
        if let index {
          guide = "Show page \(index + 1) again, close and steady."; say("Show page \(index + 1) again.")
        } else if keyMissing {
          guide = "No API key yet. Pages will be saved; add a key in Settings before you finish."
          say("Ready. No API key yet, so pages are only saved. Add a key in Settings before you finish.")
        } else {
          guide = "Look at page \(pages.count + 1), close and steady. Thumbs-up when you're done."
          say(pages.isEmpty ? "Ready. Look at the first page. Give a thumbs-up when you're done." : "Ready for page \(pages.count + 1).")
        }
      } catch { guard runID == id else { return }; fail(error.localizedDescription) }
    }
  }

  func importPhoto(_ data: Data, replacing index: Int? = nil) {
    guard !isRunning, pages.count < Self.maxPages || index != nil else { return }
    if let index, !pages.indices.contains(index) { return }
    if index == nil && packetSolved { clearPacket() }
    begin(imported: true); replacing = index; handsFree = false; fixing = false
    refreshSolveSetup()
    let id = runID; phase = .checking; guide = "Checking the selected photo…"
    worker = Task { [weak self] in await self?.process(data: data, id: id) }
  }

  func nextPage() {
    guard phase == .awaitingNext else { return }
    guard pages.count < Self.maxPages else { guide = "Page limit reached. Give a thumbs-up to finish."; say(guide); return }
    gate.reset(); turnGate.reset(); progress = 0; attempts = 0; forceCapture = false; phase = .seeking
    replacing = nil; holdForNext = false; armAfterTurn = false; noteActivity()
    // Adding pages after Finish (from a hands-free retry): the newest page waits for its successor again.
    if planFinal { planFinal = false; syncJobs() }
    guide = "Page \(pages.count + 1): hold it close and steady."; say("Page \(pages.count + 1).")
  }

  /// One command path for hand gestures, the screen, and optional glasses clicks or voice.
  /// 👍 finish · 👉 next page (or take this page now) · 👈 previous page (retake; again steps further back).
  func handle(_ command: ScanCommand) {
    noteActivity()
    switch command {
    case .finish:
      guard !pages.isEmpty || [.capturing, .checking].contains(phase) else {
        if isCollecting { guide = "Scan at least one page first."; say("Scan a page first.") }
        return
      }
      finishScanning()
    case .next:
      if phase == .awaitingNext { nextPage() }
      else if phase == .seeking {
        // The wearer vouches for the page in view: no need to wait for it to change.
        forceCapture = true; armAfterTurn = false
        guide = "Taking it as soon as the writing is clear…"; say("Taking it now.")
      }
    case .previous: previousPage()
    case .cancel: stop()
    }
  }

  /// 👈 retakes the page just photographed; each further 👈 steps one more page back.
  /// The old photo stays until the new one is clear.
  func previousPage() {
    guard !pages.isEmpty, [.seeking, .awaitingNext].contains(phase) else { return }
    let target: Int, inView: Bool
    if phase == .seeking, let replacing {
      target = replacing - 1; inView = false
    } else if phase == .awaitingNext, let lastSaved, pages.indices.contains(lastSaved) {
      // Just photographed and no page turn seen yet: still in front of the wearer, unless they were sent elsewhere.
      target = lastSaved; inView = !holdForNext
    } else {
      target = pages.count - 1; inView = false
    }
    guard target >= 0 else { guide = "This is page 1. Show it again."; say("This is page 1."); return }
    retake(page: target, inView: inView)
    guide = "Retaking page \(target + 1). " + (inView ? "Hold it steady." : "Turn back to page \(target + 1).")
    say(inView ? "Retaking page \(target + 1)." : "Page \(target + 1). Turn back to it.")
  }

  /// Aims the camera at an earlier page. A page that is not in view is photographed only once the view changes,
  /// so the sheet the wearer is still holding is never saved in its place.
  private func retake(page index: Int, inView: Bool) {
    replacing = index; attempts = 0; forceCapture = false; holdForNext = false
    gate.reset(); turnGate.reset(); progress = 0; phase = .seeking
    armAfterTurn = !inView; armGate.reset(); armDeadline = .infinity
    guard armAfterTurn else { return }
    // Remember the view from before the hand was raised; a frame with the hand in it would make lowering it look like a page turn.
    let now = ProcessInfo.processInfo.systemUptime
    if let reference = recentViews.last(where: { $0.time <= now - 1.5 }) ?? recentViews.first {
      armGate.saved(reference.sample, at: now); armDeadline = now + Self.armTimeout
    }
  }

  func removePage(at index: Int) {
    guard !isRunning else { return }
    do {
      pages = try draft.remove(at: index, from: pages); pruneThumbnails(); packetSolved = false
      guide = "\(pages.count) pages saved."; refreshSolveSetup(); syncJobs()
    } catch { guide = "Could not remove the saved page. \(error.localizedDescription)" }
  }
  func reloadDraft() {
    guard !isRunning else { return }
    pages = draft.load(); packetSolved = !pages.isEmpty && draft.isSolved; loadThumbnails(); refreshPageStates()
  }
  func newBatch() {
    guard !isRunning else { return }
    clearPacket()
    result = nil; capturedPreview = nil; preview = nil; phase = .idle
    guide = "Ready for a new packet. Tap Start."
  }
  /// The launch shortcut (Action button, Back Tap, Siri, Control Center): show Auto Scan and start once the app is active.
  func requestShortcutStart() { shortcutPending = true; shortcutRequests += 1 }
  /// Called by the view when the app is in the foreground. Starting (or continuing) a packet needs no further tap.
  func startFromShortcut() {
    guard shortcutPending else { return }
    shortcutPending = false
    guard !isRunning else { say(isCollecting ? "Already scanning." : "Still solving your last packet."); return }
    start()
  }
  /// Pause while collecting keeps page solves running; it only stops the camera.
  func pause() {
    if isCollecting || phase == .connecting { pauseScanning("Paused. \(pages.count) pages saved; solving continues.") }
    else { stop() }
  }
  /// User stop: ends scanning and any solving in progress. Finished page results stay cached.
  /// Ignored while the PDF is written, so a finished file is never orphaned.
  func stop() {
    guard phase != .saving else { return }
    runID = UUID(); worker?.cancel(); analysisTask?.cancel(); cancelPreviewRestart()
    worker = nil; analysisTask = nil
    for job in jobs.values { job.task.cancel() }
    jobs = [:]
    camera.stop(); gate.reset(); turnGate.reset(); gestureGate.reset(); fixing = false
    voice.stopCommands(); voice.stopSpeaking(); phase = .idle; progress = 0
    guide = "Paused. \(pages.count) pages remain saved."; restoreIdleTimer(); endBackgroundWork()
    refreshPageStates()
  }
  /// Leaving the screen stops the camera but never cancels page solving or PDF creation.
  func backgrounded() {
    if !jobs.isEmpty { beginBackgroundWork() } // let page solves in flight finish while iOS allows
    guard isCollecting else { return } // `connecting` may hand off to Meta AI for permission
    pauseScanning("Paused when the app left the screen. Your pages are saved; tap Continue or run the Glasses Scan shortcut.")
    say("Scanning paused. Open the app or run your Glasses Scan shortcut to continue.")
  }
  func viewDisappeared() {
    guard isCollecting || phase == .connecting else { return }
    pauseScanning("Scanning paused. Your pages are saved.")
  }
  private func pauseScanning(_ message: String) {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel(); cancelPreviewRestart(); worker = nil; analysisTask = nil
    camera.stop(); gate.reset(); turnGate.reset(); gestureGate.reset(); voice.stopCommands(); fixing = false
    phase = .idle; progress = 0; guide = message; restoreIdleTimer()
  }

  private func begin(imported: Bool) {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel(); analysisTask = nil; cancelPreviewRestart(); cameraProblem = nil
    camera.stop(); voice.stopCommands(); voice.stopSpeaking()
    gate.reset(); turnGate.reset(); speechGate.reset(); gestureGate.reset()
    self.imported = imported; replacing = nil; finishRequested = false; forceCapture = false; captureFailures = 0
    holdForNext = false; armAfterTurn = false; armGate.reset(); armDeadline = .infinity; recentViews = []; noteActivity()
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
        if time - lastActivity > Self.idleLimit {
          pauseScanning("Paused after 5 minutes without a new page. Your pages are saved.")
          say("Scanning paused."); return
        }
        if value.gesture == nil, value.acceptable, value.closeEnough {
          recentViews.append((time, value)); recentViews.removeAll { time - $0.time > 5 }
        }
        if gesturesEnabled {
          // Thumbs down and thumbs left both mean "previous": one gesture to the gate, so turning a held thumb
          // from one to the other never fires twice.
          let command = value.gesture == .thumbsDown ? HandGesture.thumbsLeft : value.gesture
          if let gesture = gestureGate.observe(command, at: time) { handle(gesture: gesture); return }
          // Never photograph or page-turn while a command hand is raised.
          if value.gesture != nil {
            gate.reset(); progress = 0; guide = "Hold the gesture for a moment…"
            if time - lastGestureHint > 3 { lastGestureHint = time; say("Hold.") }
            return
          }
        }
        if phase == .awaitingNext {
          // After an earlier page was fixed, the sheets in front of the wearer were already scanned: wait for 👉.
          if holdForNext { return }
          if pages.count < Self.maxPages, turnGate.observe(value, at: time) { noteActivity(); nextPage() }
          else if time - awaitingSince > 4, value.acceptable, !value.closeEnough { speakCue(.closer, at: time) }
          else if time - awaitingSince > 6, value.acceptable, !nextHintGiven {
            // Look-alike pages may not register as a page turn.
            nextHintGiven = true
            say("If this is a new page, give a thumbs-right.")
          }
          return
        }
        if armAfterTurn, let index = replacing {
          // Retaking a page that was not in view: wait until the wearer has turned to it.
          if !armGate.hasReference, value.gesture == nil, value.acceptable, value.closeEnough {
            armGate.saved(value, at: time); armDeadline = time + Self.armTimeout
          }
          if armGate.observe(value, at: time) || time >= armDeadline {
            armAfterTurn = false; gate.reset()
          } else {
            gate.reset(); progress = 0; guide = "Turn to page \(index + 1)…"; return
          }
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
    case .thumbsRight, .openPalm: handle(.next)
    case .thumbsLeft, .thumbsDown: handle(.previous)
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
    guide = "Got it. Turn to the next page while it saves."
    say(helpGiven.insert("shutter").inserted ? "Got it. Turn the page." : "Got it.")
  }
  /// A dropped transfer is retried by looking at the page again; repeated failures stop with the pages kept.
  private func captureFailed(_ error: any Error, id: UUID) async {
    if finishRequested, !pages.isEmpty { finishRequested = false; phase = .idle; finishScanning(); return }
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
    cancelPreviewRestart()
    if !imported && !finishRequested {
      previewTask = Task { [weak self] in
        guard let self else { return }
        try await self.resume(id: id)
      }
    }
    let restart = previewTask
    do {
      phase = .checking; progress = 0
      if !guide.hasPrefix("Got it") { guide = "Checking the photo for clear writing…" }
      let photo = try await analyzer.prepare(data)
      try Task.checkCancellation(); guard runID == id else { restart?.cancel(); return }
      if !photo.sample.acceptable || !photo.sample.closeEnough {
        let reason = photo.sample.issue ?? "Move closer so the small writing is readable."
        if finishRequested, !pages.isEmpty {
          // The wearer already asked to finish: solve the saved pages instead of waiting on a retake.
          restart?.cancel(); finishRequested = false; phase = .idle
          finishScanning(); say("The last photo wasn't clear, so it was skipped. Solving."); return
        }
        finishRequested = false
        if let message = cameraProblem { fail(message + " Your saved pages are kept."); return }
        if let restart { try await restart.value } else if !imported { try await resume(id: id) }
        guard runID == id else { return }
        try retakeUnclearStill(reason)
        return
      }
      let index = replacing ?? pages.count
      let replacedEarlierPage = replacing.map { $0 < pages.count - 1 } ?? false
      pages = try draft.add(photo.jpeg, to: pages, replacing: replacing)
      packetSolved = false
      let page = pages[index]
      if let thumbnail = photo.thumbnail { thumbnails[page.id] = UIImage(cgImage: thumbnail) }
      capturedPreview = thumbnails[page.id]; replacing = nil; attempts = 0; lastSaved = index; noteActivity()
      pruneThumbnails()
      syncJobs() // the previous page now has its next-page context and can be solved
      let urls = Set(pages.map(\.url)), solver = self.solver
      Task { await solver.forget(keeping: urls) }
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      if finishRequested {
        restart?.cancel(); finishRequested = false; phase = .idle; finishScanning(); return
      }
      if let message = cameraProblem { fail(message + " Your saved pages are kept."); return }
      if imported {
        phase = .idle; restoreIdleTimer()
        guide = "Page \(index + 1) saved. Add another photo, or finish to solve."
      } else if fixing {
        // Asked for after Finish: continue with the next unclear page, or go straight back to solving.
        if let next = nextFixTarget() {
          try await restart?.value
          guard runID == id else { return }
          askAgain(for: next, after: "Page \(index + 1) saved.")
        } else {
          restart?.cancel(); fixing = false; phase = .idle
          say("Page \(index + 1) saved."); finishScanning()
        }
      } else if replacedEarlierPage {
        // The sheets in front of the wearer were already scanned, so a page turn must not add them again.
        // The camera stays on: 👉 at the first new page continues, 👍 solves.
        try await restart?.value
        guard runID == id else { return }
        phase = .awaitingNext; holdForNext = true; progress = 0
        if pages.count < Self.maxPages {
          guide = "Page \(index + 1) replaced. Turn to page \(pages.count + 1), then give a thumbs-right. Thumbs-up solves."
          say("Page \(index + 1) replaced. At page \(pages.count + 1), thumbs-right. Or thumbs-up to solve.")
        } else {
          guide = "Page \(index + 1) replaced. Give a thumbs-up to solve."; say(guide)
        }
      } else {
        try await restart?.value
        guard runID == id else { return }
        if finishRequested { finishRequested = false; phase = .idle; finishScanning(); return }
        phase = .awaitingNext; progress = 0; awaitingSince = ProcessInfo.processInfo.systemUptime; nextHintGiven = false
        if pages.count < Self.maxPages {
          guide = "Page \(index + 1) saved. Turn the page. Thumbs-left retakes it; thumbs-up finishes."
          say(helpGiven.insert("saved").inserted ? "Page \(index + 1) saved. Turn the page. Thumbs-left retakes it, thumbs-up finishes."
            : "Page \(index + 1) saved.")
        } else {
          guide = "Page limit reached. Give a thumbs-up to finish."; say(guide)
        }
      }
    } catch {
      restart?.cancel(); guard runID == id else { return }
      fail(cameraProblem.map { $0 + " Your saved pages are kept." } ?? error.localizedDescription)
    }
  }
  /// Hands-free scanning keeps guiding instead of giving up after unclear stills.
  private func retakeUnclearStill(_ reason: String) throws {
    guard !imported else { throw SolverError.message(reason + " Choose a clearer photo.") }
    let number = (replacing ?? pages.count) + 1
    guide = "That photo wasn't clear. Show page \(number) again. \(reason)"
    say("Show page \(number) again. \(reason)")
    gate.reset(); progress = 0; phase = .seeking
  }
  private func resume(id: UUID) async throws {
    do { try await camera.resumePreview() }
    catch {
      try Task.checkCancellation(); guard runID == id else { return }
      try await camera.start()
      if runID != id || Task.isCancelled { camera.stop() } // stopped meanwhile: never leave a session open
    }
  }
  private func cancelPreviewRestart() { previewTask?.cancel(); previewTask = nil }
  private func noteActivity() { lastActivity = ProcessInfo.processInfo.systemUptime }
  private func refreshSolveSetup() {
    let configuration = configurationProvider()
    solveSetup = solveWhileScanning && (try? configuration.validate()) != nil ? configuration : nil
  }

  // MARK: Solving

  func finishScanning() {
    if [.capturing, .checking].contains(phase) {
      finishRequested = true; guide = "Finishing after this photo is saved."; say("Finishing after this photo."); return
    }
    guard canFinish else { return }
    let configuration = configurationProvider()
    do { try configuration.validate(); needsKey = false }
    catch {
      stop(); needsKey = true; keyPrompts += 1; guide = error.localizedDescription
      say(error.localizedDescription + " Open Settings on your phone."); return
    }
    if fixing { leftOut.formUnion(unclear.keys); fixing = false } // 👍 while asked for an unclear page: solve without it
    begin(imported: true)
    solveSetup = configuration // a corrected key or model applies to every page still to solve
    planFinal = true
    jobErrors = [:]; claimed = [] // finishing again retries only the pages that failed
    // From the phone, Done also retries photos the AI could not read; a hands-free scan asks for them again instead.
    if !handsFree { unclear = [:] }
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
    unclear = unclear.filter { ids.contains($0.key) }
    // Hands-free, an unreadable photo is asked for again (or left out), never sent again as it is.
    for key in desired where results[key] == nil && jobs[key] == nil && jobErrors[key] == nil
      && !(handsFree && unclear[key.page] != nil) {
      startJob(key, configuration)
    }
    refreshPageStates()
  }

  private func startJob(_ key: PageJobKey, _ configuration: SolverConfiguration, mustSolve: [String] = []) {
    guard let index = pages.firstIndex(where: { $0.id == key.page }) else { return }
    let urls = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.url) })
    let job = PageJob(key: key, number: index + 1, primary: pages[index].url,
      previous: key.previous.flatMap { urls[$0] }, next: key.next.flatMap { urls[$0] }, mustSolve: mustSolve)
    let token = UUID(), solver = self.solver
    let notify: @Sendable (String) -> Void = { [weak self] message in
      Task { @MainActor in self?.solveNotice(message) }
    }
    let task = Task { [weak self] in
      let outcome: Result<PageResult, any Error>
      do {
        let value = try await solver.solve(job, configuration: configuration, progress: notify)
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
    case .failure(let error):
      jobErrors[key] = error.localizedDescription
      if case AIResultError.unreadable(let message)? = error as? AIResultError {
        unclear[key.page] = message
        // Say it now, not only after Finish. Hands-free, the page is asked for again once scanning is done.
        if fixing {
          solveStatus = message; say(message + " I'll ask for it next.")
        } else if isCollecting {
          solveStatus = message + (handsFree ? " I'll ask for it again when you finish." : " Retake it from the phone.")
          say(message + (handsFree ? " I'll ask for it again when you finish." : ""))
        }
      }
    }
    refreshPageStates()
    if phase == .solving { advanceFinish() }
    else if jobs.isEmpty && phase != .saving { endBackgroundWork() }
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
      else if let message = unclear[page.id] { states[page.id] = .failed(message) }
      else if let error = jobErrors[key] { states[page.id] = .failed(error) }
      else if jobs[key] != nil { states[page.id] = .solving }
      else { states[page.id] = .queued }
    }
    pageStates = states
  }

  private func advanceFinish() {
    guard phase == .solving, let configuration = solveSetup else { return }
    // Hands-free: ask again for a page the AI could not read right away, while the other pages keep solving.
    if handsFree, let target = nextFixTarget() { startFix(at: target); return }
    let keys = PagePlan.keys(for: pages.map(\.id), final: true, setup: configuration.setup)
    let solving = keys.filter { !leftOut.contains($0.page) }
    guard !solving.isEmpty else {
      leftOut = []; endBackgroundWork()
      fail("None of the pages could be read. Retake them, then finish."); return
    }
    let done = solving.filter { results[$0] != nil }.count
    let failed = solving.filter { jobErrors[$0] != nil }
    progress = Double(done) / Double(solving.count)
    guard done + failed.count == solving.count else {
      guide = "Solving… \(done) of \(solving.count) pages done."; return
    }
    guard failed.isEmpty else {
      let numbers = failed.compactMap { key in pages.firstIndex { $0.id == key.page }.map { String($0 + 1) } }
      let detail = jobErrors[failed[0]] ?? ""
      let summary = failed.count == 1 ? detail : "Pages \(numbers.joined(separator: ", ")) could not be solved. \(detail)"
      endBackgroundWork()
      if handsFree {
        standby(summary + " Solved pages are kept. Give a thumbs-up to try again.",
          otherwise: summary + " Solved pages are kept; tap Done to retry only the failed pages.")
        return
      }
      let advice = failed.contains { unclear[$0.page] != nil }
        ? " Retake that page with the Retake button under it, then tap Done; sending the same photo again won't help."
        : " Solved pages are kept; tap Done to retry only the failed pages."
      fail(summary + advice)
      return
    }
    var entries: [(number: Int, result: PageResult)] = solving.compactMap { key in
      guard let cached = results[key], let index = pages.firstIndex(where: { $0.id == key.page }) else { return nil }
      // A removed earlier page renumbers later pages without changing their content or context.
      return (index + 1, cached.result.shifted(by: index + 1 - cached.number))
    }
    // A page may skip an item as "belonging to the previous page" that the previous page did not solve.
    // Re-solve that page once, requiring those items, so nothing silently falls between pages.
    for (number, labels) in PagePlan.orphanedSkips(entries).sorted(by: { $0.key < $1.key }) {
      guard keys.indices.contains(number - 1) else { continue }
      // Items continued from a page that was left out unreadable cannot be claimed from this page.
      if number >= 2, leftOut.contains(pages[number - 2].id) { continue }
      let key = keys[number - 1]
      guard !claimed.contains(key) else { continue }
      claimed.insert(key); results[key] = nil
      startJob(key, configuration, mustSolve: labels)
      guide = "Completing \(labels.joined(separator: ", ")) on page \(number)…"
      refreshPageStates(); return
    }
    // A page the wearer chose to leave out stays visible in the PDF, with its photo, as an item to review.
    for (index, page) in pages.enumerated() where leftOut.contains(page.id) {
      let reason = unclear[page.id] ?? "The photo could not be read."
      let note = PageSolutionItem(label: "Page \(index + 1)", problem: "This page could not be read, so it was left out.",
        steps: ["Retake page \(index + 1) and finish again to add its solutions."], answer: "—", check: "—",
        status: "unreadable", reviewNote: reason, sourcePages: [index + 1])
      entries.append((index + 1, PageResult(readable: true, retake: "", title: "", checklist: [], solutions: [note], skipped: [])))
    }
    save(entries, providers: configuration.summary)
  }

  /// The first page whose photo the AI could not read, unless the wearer chose to solve without it.
  private func nextFixTarget() -> Int? {
    pages.firstIndex { unclear[$0.id] != nil && !leftOut.contains($0.id) }
  }

  /// After Finish, an unreadable page is asked for again through the glasses; solving resumes once it is retaken.
  private func startFix(at index: Int) {
    fixing = true
    begin(imported: false)
    let id = runID
    phase = .connecting; guide = unclear[pages[index].id] ?? "Page \(index + 1) is unclear."
    say(fixRequest(for: index)) // while the camera reconnects, so the wearer can already turn to that page
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        try await camera.start(); try Task.checkCancellation()
        guard runID == id else { return }
        askAgain(for: index, after: nil, speak: false)
      } catch {
        guard runID == id else { return }
        fixing = false
        fail(error.localizedDescription + " Retake page \(index + 1) with the Retake button under it, then tap Done.")
      }
    }
  }

  private func askAgain(for index: Int, after prefix: String?, speak: Bool = true) {
    retake(page: index, inView: false); noteActivity()
    let reason = unclear[pages[index].id] ?? "Page \(index + 1) is unclear."
    guide = "\(reason) Show page \(index + 1) again, or give a thumbs-up to solve without it."
    if speak { say([prefix, fixRequest(for: index)].compactMap { $0 }.joined(separator: " ")) }
  }
  private func fixRequest(for index: Int) -> String {
    (unclear[pages[index].id] ?? "Page \(index + 1) is unclear.") + " Show page \(index + 1) again, or thumbs-up to solve without it."
  }

  /// Hands-free failure: the glasses camera stays on so a thumbs-up retries without taking out the phone.
  private func standby(_ message: String, otherwise phoneMessage: String) {
    begin(imported: false)
    let id = runID
    phase = .connecting; guide = message; say(message)
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        try await camera.start(); try Task.checkCancellation()
        guard runID == id else { return }
        phase = .awaitingNext; holdForNext = true; progress = 0; guide = message; noteActivity()
      } catch { guard runID == id else { return }; fail(phoneMessage) }
    }
  }

  private func save(_ entries: [(number: Int, result: PageResult)], providers: String) {
    let id = runID, sources = pages.map(\.url)
    let missing = pages.indices.filter { leftOut.contains(pages[$0].id) }.map { String($0 + 1) }
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
        if !missing.isEmpty { guide += " Left out unreadable: page \(missing.joined(separator: ", "))." }
        // Keep the pages and cached answers so one page can be retaken and the PDF rebuilt quickly.
        // The next Start (or a new photo) begins a fresh packet; the PDF folder holds every original.
        try? draft.markSolved(); packetSolved = true
        restoreIdleTimer(); endBackgroundWork(); showPDF = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        say("Your solution PDF is ready on your phone.")
      } catch { guard runID == id else { return }; endBackgroundWork(); fail(error.localizedDescription) }
    }
  }

  private func clearPacket() {
    do { try draft.clear() } catch { guide = "Could not clear the previous draft. \(error.localizedDescription)"; return }
    for job in jobs.values { job.task.cancel() }
    jobs = [:]; results = [:]; jobErrors = [:]; claimed = []; unclear = [:]; leftOut = []; solveSetup = nil; planFinal = false
    packetSolved = false
    pages = []; thumbnails = [:]; pageStates = [:]; solveStatus = ""
    let solver = self.solver
    Task { await solver.forget(keeping: []) }
  }

  // MARK: Helpers

  private func fail(_ message: String) {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel(); analysisTask = nil; cancelPreviewRestart(); cameraProblem = nil
    camera.stop(); voice.stopCommands(); gate.reset(); restoreIdleTimer(); fixing = false
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
