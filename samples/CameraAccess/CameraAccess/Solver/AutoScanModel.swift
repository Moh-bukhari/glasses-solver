import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class AutoScanModel {
  enum Phase: String { case idle, connecting, seeking, awaitingNext, capturing, checking, importing, solving, saving, finished, failed }
  /// Per-page solving status shown on the page queue.
  enum PageState: Equatable { case waiting, queued, solving, solved, failed(String) }
  static let maxPages = 30

  private(set) var phase: Phase = .idle
  private(set) var guide = "Tap Start (or use the Start Glasses Scan shortcut), then take photos of page 1 with the capture button on your glasses."
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
  var solveWhileScanning = false
  /// Each page is checked by the AI while the wearer still looks at it; the scan moves on only once it is clear.
  var checkPages = true
  /// How pages are photographed. `buttonPhotos` (2.6 default): the wearer takes each photo with the glasses' capture
  /// button and the Meta AI app imports it into Photos, where the app picks it up; much sharper than the video stream.
  /// `frames`: the clearest live preview frames (several per page). `photos`: one full-resolution still per page.
  enum CaptureMode: String, CaseIterable, Sendable { case buttonPhotos, frames, photos }
  var captureMode = CaptureMode.buttonPhotos
  /// Glasses photos: how many reached the app and how long the last one took (Meta AI's import delay).
  private(set) var photoStatus = ""
  /// Photos access is missing or limited; the view links to the app's page in iOS Settings.
  private(set) var needsPhotoAccess = false
  /// Glasses photos: the page being photographed, and photos of a later sheet taken before that page was clear.
  private var openPhotos: [PagePhoto] = []
  private var laterPhotos: [PagePhoto] = []
  /// Photos taken before a retake began: they are not the retake, and continue as new pages once it is saved.
  private var heldPhotos: [PagePhoto] = []
  var hasOpenPhotos: Bool {
    !openPhotos.isEmpty || !laterPhotos.isEmpty || !heldPhotos.isEmpty || !photoEvents.isEmpty || !intake.isEmpty
  }
  /// `importing` (picked photos being added) is running but not collecting: leaving the screen never stops it.
  var isRunning: Bool { [.connecting, .seeking, .awaitingNext, .capturing, .checking, .importing, .solving, .saving].contains(phase) }
  var isCollecting: Bool { [.seeking, .awaitingNext, .capturing, .checking].contains(phase) }
  var canFinish: Bool {
    (!pages.isEmpty || hasOpenPhotos) && !packetSolved && [.idle, .failed, .seeking, .awaitingNext].contains(phase)
  }
  var solvedPages: Int { pages.filter { pageStates[$0.id] == .solved }.count }

  @ObservationIgnored private let camera: any ScanCamera
  @ObservationIgnored private let analyzer: any PageAnalyzing
  @ObservationIgnored private let solver: any PageSolving
  @ObservationIgnored private let checker: any PageChecking
  @ObservationIgnored private let saver: any SolutionSaving
  @ObservationIgnored private let draft: ScanDraftStore
  @ObservationIgnored private let configurationProvider: () -> SolverConfiguration
  @ObservationIgnored private let voice: any ScanSpeaking
  @ObservationIgnored private let photos: any PhotoSource
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
  // Live-frame capture: the page being scanned is a set of kept preview frames (see FrameCapture.swift).
  @ObservationIgnored private var pageFrames = PageFrames()
  @ObservationIgnored private var keptImages: [Int: (image: CGImage, sample: PageSample)] = [:]
  @ObservationIgnored private var nextFrameID = 0
  @ObservationIgnored private var lastRead = -Double.infinity
  @ObservationIgnored private var reading = false
  /// Bumped whenever the open page is saved or dropped, so a text read that finishes late never lands on another page.
  @ObservationIgnored private var pageGeneration = 0
  /// Words of the page saved last: a view of the same sheet must not start the next page (it would duplicate questions).
  @ObservationIgnored private var savedPageWords: Set<String> = []
  @ObservationIgnored private var stillSpoken = false
  /// Text is read on a steady frame at most this often (accurate recognition takes ~120-250 ms).
  static let readInterval: TimeInterval = 0.33
  // Page check: the open page's frames go to the AI once the view has been steady for `checkQuiet`; the page is saved
  // only when the AI can read everything needed to solve it.
  @ObservationIgnored private var pageCheck: Task<Void, Never>?
  /// When a frame was last added to (or sharpened on) the open page, and the latest such time a check has covered.
  @ObservationIgnored private var lastChange = -Double.infinity
  @ObservationIgnored private var checkedThrough = -Double.infinity
  /// The same, for the last check that came back with a verdict (a failed check judged nothing).
  @ObservationIgnored private var verdictThrough = -Double.infinity
  @ObservationIgnored private var verdictAt = -Double.infinity
  @ObservationIgnored private var reminded = false
  /// Pages in a row saved without a check because the AI did not answer; two in a row turn checks off for the scan.
  @ObservationIgnored private var failedCheckPages = 0
  @ObservationIgnored private var checkRounds = 0
  @ObservationIgnored private var checkFailures = 0
  @ObservationIgnored private var retryCheckAt = Double.infinity
  @ObservationIgnored private var lastRetake = ""
  /// The AI said the open page is unclear after 👍: the next 👍 solves without waiting for it.
  @ObservationIgnored private var finishAnyway = false
  /// Why checks stopped for this scan (a key, billing or model problem); pages are then saved without a check.
  @ObservationIgnored private var checksOff: String?
  @ObservationIgnored private var checkKey = false
  static let checkQuiet: TimeInterval = 1.5
  /// From this many unclear answers on, the wearer hears that 👉 keeps the page; checks continue only after new views.
  static let maxCheckRounds = 3
  /// An unclear page with nothing new for this long gets one spoken reminder of what to show, and that 👉 keeps it.
  static let remindAfter: TimeInterval = 12
  /// A typical check answers in a few seconds (Opus 5.5 may think briefly first); a slower one is retried once, then
  /// the page is saved without it.
  static let checkTimeout: TimeInterval = 20
  /// Views kept per page while it is checked; the AI may need a few close-ups of a crowded sheet.
  static let frameConfiguration: PageFrames.Configuration = { var value = PageFrames.Configuration(); value.maxFrames = 8; return value }()
  // Glasses photos (see "Glasses photos" below): no glasses camera stream runs; photos come from the photo library.
  /// The current (or last) scan takes the glasses' own photos.
  private(set) var photoScan = false
  /// The photo library is being watched for this scan.
  @ObservationIgnored private var watchingPhotos = false
  /// Photos that reached the app, looked at in order for a hand command before they join a page.
  @ObservationIgnored private var intake: [IncomingPhoto] = []
  @ObservationIgnored private var intakeTask: Task<Void, Never>?
  /// Page photos and commands in the order they were taken, waiting for the open page's check.
  @ObservationIgnored private var photoEvents: [PhotoEvent] = []
  @ObservationIgnored private var photoCheck: Task<Void, Never>?
  @ObservationIgnored private var photoTimer: Task<Void, Never>?
  /// Library photos already used in this packet: a continued scan looks back and sees recent photos again.
  @ObservationIgnored private var usedPhotos: Set<String> = []
  /// Where a continued scan picks up: when the last one stopped, or its oldest photo not yet on a saved page.
  @ObservationIgnored private var photosResumeFrom: Date?
  @ObservationIgnored private var photosReceived = 0
  /// This scan's start (before the clock allowance) and the newest photo it received: where a stopped scan resumes when
  /// no photo was waiting, so photos Meta AI imports late are still found.
  @ObservationIgnored private var photoRunStart: Date?
  @ObservationIgnored private var lastPhotoTaken: Date?
  /// The app is in the background (the wearer may be in Meta AI): no idle finish until it is back.
  @ObservationIgnored private var photosAway = false
  /// When the open retake began (the 👈 photo's time, or the tap), and when a page was last saved: a 👈 photo applies
  /// to the pages as they were when it was taken.
  @ObservationIgnored private var retakeFrom: Date?
  @ObservationIgnored private var lastPageSavedAt: Date?
  /// When the 👍 photo of a pending finish was taken: photos taken after it are not part of this packet.
  @ObservationIgnored private var finishCutoff: Date?
  @ObservationIgnored private var photoStart = 0.0
  @ObservationIgnored private var photoHintGiven = false
  /// Checks of the open page so far, and whether the wearer heard that a photo shows the page before again.
  @ObservationIgnored private var pageChecks = 0
  @ObservationIgnored private var earlierSpoken = false
  /// A few photos and an upload of each: slower than a check of live frames.
  static let photoCheckTimeout: TimeInterval = 40
  /// Without any photo this long after Start, the wearer hears how photos reach the phone.
  static let photoHintAfter: TimeInterval = 45
  /// After this long without a new photo, the pages taken so far are solved.
  static let photoIdleFinish: TimeInterval = 600
  private struct PagePhoto: Sendable { let id: String; let jpeg: Data; let taken: Date }
  private enum PhotoEvent { case photo(PagePhoto), command(ScanCommand, taken: Date) }

  init(camera: any ScanCamera, analyzer: any PageAnalyzing = PageAnalyzer(),
       solver: any PageSolving = PageSolver(), checker: any PageChecking = PageChecker(), saver: any SolutionSaving = SolutionStore(),
       draft: ScanDraftStore = ScanDraftStore(), voice: any ScanSpeaking = ScanVoice(), photos: any PhotoSource = PhotoLibraryInbox(),
       configurationProvider: @escaping () -> SolverConfiguration = { SolverKeychain.configuration() }) {
    self.camera = camera; self.analyzer = analyzer; self.solver = solver; self.checker = checker; self.saver = saver
    self.draft = draft; self.voice = voice; self.photos = photos; self.configurationProvider = configurationProvider
    pages = draft.load()
    packetSolved = !pages.isEmpty && draft.isSolved
    if let state = draft.loadPhotoState() {
      // A relaunch continues a glasses-photo packet where it stopped, without reusing photos already on its pages.
      usedPhotos = Set(state.used)
      if !packetSolved { photosResumeFrom = state.resumeFrom }
    }
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
    photos.onIdle = { [weak self] in self?.pumpPhotos() } // a finish may be waiting for the library
  }

  // MARK: Scanning

  func start(replacing index: Int? = nil) {
    guard !isRunning || [.seeking, .awaitingNext].contains(phase) else { return }
    guard pages.count < Self.maxPages || index != nil else {
      guide = "\(Self.maxPages) pages saved. Finish this packet first."; return
    }
    if let index, !pages.indices.contains(index) { return }
    if index == nil && packetSolved { clearPacket() } // one button: after a PDF, Start begins a new packet
    if captureMode == .buttonPhotos { startPhotos(replacing: index); return }
    begin(imported: false); replacing = index; photoScan = false
    planFinal = false; helpGiven = []; handsFree = true; fixing = false; lastSaved = nil
    refreshSolveSetup()
    syncJobs()
    let keyMissing = (try? configurationProvider().validate()) == nil
    checkKey = !keyMissing; checksOff = nil; failedCheckPages = 0
    let id = runID
    phase = .connecting; guide = "Connecting to your glasses…"
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        try await prepareVoice(id: id)
        guide = "Connecting to your glasses…"
        try await camera.start(); try Task.checkCancellation()
        guard runID == id else { return }
        phase = .seeking; noteActivity()
        if let index {
          guide = "Show page \(index + 1) again, close and steady."; say("Show page \(index + 1) again.")
        } else if keyMissing {
          guide = "No API key yet. Pages will be saved without a check; add a key in Settings before you finish."
          say("Ready. No API key yet, so pages are only saved. Add a key in Settings before you finish.")
        } else {
          let number = pages.count + 1
          guide = "Page \(number): look at it closely, part by part, top to bottom. Thumbs-up when you're done."
          say(pages.isEmpty ? "Ready. Look at page 1 closely, part by part, top to bottom. Give a thumbs-up when you're done."
            : "Ready for page \(number).")
        }
      } catch { guard runID == id else { return }; fail(error.localizedDescription) }
    }
  }

  /// Manual import (2.7): the photos the user picked, in the order picked, each become a page. Photos are only normalized
  /// (orientation, JPEG); the user chose the clearest ones, so no on-device quality gate can reject them. Pages are solved
  /// when the user taps Solve.
  func importPhotos(_ photos: [Data]) {
    guard !photos.isEmpty else { return }
    guard !isRunning else {
      guide = phase == .importing ? "Still adding the last photos. Pick more when they are in."
        : "Wait until this packet is solved (or stop it), then add photos."
      return
    }
    if packetSolved { clearPacket() }
    let room = Self.maxPages - pages.count
    guard room > 0 else { guide = "\(Self.maxPages) pages saved. Solve or start a new packet first."; return }
    begin(imported: true); replacing = nil; handsFree = false; fixing = false; photoScan = false
    refreshSolveSetup()
    let chosen = Array(photos.prefix(room)), id = runID, analyzer = self.analyzer
    phase = .importing; progress = 0; guide = "Adding \(chosen.count) photo\(chosen.count == 1 ? "" : "s")…"
    beginBackgroundWork() // finishes even if the phone locks or the app leaves the screen
    worker = Task { [weak self] in
      var added = 0, failed = 0
      for data in chosen {
        guard let self, self.runID == id else { return }
        do {
          let photo = try await analyzer.prepare(data)
          guard self.runID == id else { return }
          self.pages = try self.draft.add(frames: [photo.jpeg], to: self.pages, replacing: nil)
          if let thumbnail = photo.thumbnail, let page = self.pages.last { self.thumbnails[page.id] = UIImage(cgImage: thumbnail) }
          added += 1
        } catch { failed += 1 }
        self.progress = Double(added + failed) / Double(chosen.count)
      }
      guard let self, self.runID == id else { return }
      self.packetSolved = false; self.lastSaved = self.pages.count - 1
      self.syncJobs()
      let solver = self.solver, urls = Set(self.pages.flatMap(\.frames))
      Task { await solver.forget(keeping: urls) }
      self.phase = .idle; self.restoreIdleTimer(); self.progress = 0
      if self.jobs.isEmpty { self.endBackgroundWork() }
      var message = "\(self.pages.count) page\(self.pages.count == 1 ? "" : "s") ready. Tap Solve, or add more photos."
      if failed > 0 { message = "\(failed) photo\(failed == 1 ? "" : "s") could not be read and \(failed == 1 ? "was" : "were") skipped. " + message }
      if photos.count > chosen.count { message += " Only the first \(chosen.count) were added (limit \(Self.maxPages) pages)." }
      self.guide = message
    }
  }

  /// Voice commands (if on) and the audio route, before a scan's first direction.
  private func prepareVoice(id: UUID) async throws {
    if voiceCommands {
      guide = "Preparing voice commands…"; voiceStatus = "Checking microphone and speech permissions…"
      await voice.startCommands()
      try Task.checkCancellation(); guard runID == id else { throw CancellationError() }
    } else { voiceStatus = ""; voice.prepareOutput() }
    if voiceGuidance && privateAudio && !voice.routeIsPrivate {
      voiceStatus = "Glasses audio isn't connected, so directions are shown on screen only."
    }
  }

  func importPhoto(_ data: Data, replacing index: Int? = nil) {
    guard !isRunning, pages.count < Self.maxPages || index != nil else { return }
    if let index, !pages.indices.contains(index) { return }
    if index == nil && packetSolved { clearPacket() }
    begin(imported: true); replacing = index; handsFree = false; fixing = false; photoScan = false
    refreshSolveSetup()
    let id = runID; phase = .checking; guide = "Checking the selected photo…"
    worker = Task { [weak self] in await self?.process(data: data, id: id) }
  }

  func nextPage(fromTurn: Bool = false) {
    guard phase == .awaitingNext else { return }
    guard pages.count < Self.maxPages else { guide = "Page limit reached. Give a thumbs-up to finish."; say(guide); return }
    gate.reset(); turnGate.reset(); progress = 0; attempts = 0; forceCapture = false; phase = .seeking
    replacing = nil; holdForNext = false; armAfterTurn = false; noteActivity(); discardOpenPage()
    if !fromTurn { savedPageWords = [] } // 👉: the wearer says this is a new page, even if it looks alike
    // Adding pages after Finish (from a hands-free retry): the newest page waits for its successor again.
    if planFinal { planFinal = false; syncJobs() }
    guide = "Page \(pages.count + 1): look at it closely, part by part."; say("Page \(pages.count + 1).")
  }

  /// One command path for hand gestures, the screen, and optional glasses clicks or voice.
  /// 👍 finish · 👉 next page (or take this page now) · 👈 previous page (retake; again steps further back).
  func handle(_ command: ScanCommand) {
    noteActivity()
    switch command {
    case .finish:
      guard !pages.isEmpty || !pageFrames.isEmpty || hasOpenPhotos || [.capturing, .checking].contains(phase) else {
        if isCollecting {
          guide = photoScan ? "Take a photo of page 1 first." : "Scan at least one page first."
          say(photoScan ? "Take a photo of page 1 first." : "Scan a page first.")
        }
        return
      }
      finishScanning()
    case .next:
      if photoScan && isCollecting { keepPhotoPage() }
      else if phase == .awaitingNext { nextPage() }
      else if phase == .seeking && captureMode == .frames && !imported && !pageFrames.isEmpty {
        // Live frames: the wearer keeps the page as it is, checked or not; save what was kept.
        armAfterTurn = false
        let run = runID
        Task { [weak self] in await self?.commitPage(id: run) }
      } else if phase == .seeking {
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
  /// `taken`: the 👈 photo's time. If a page was saved after it was taken, "the page before" is the one before that page.
  func previousPage(asOf taken: Date? = nil) {
    guard !pages.isEmpty, [.seeking, .awaitingNext].contains(phase) else { return }
    let target: Int, inView: Bool
    if phase == .seeking, let replacing {
      target = replacing - 1; inView = false
    } else if phase == .awaitingNext, let lastSaved, pages.indices.contains(lastSaved) {
      // Just photographed and no page turn seen yet: still in front of the wearer, unless they were sent elsewhere.
      target = lastSaved; inView = !holdForNext
    } else {
      let savedSince = taken.map { (lastPageSavedAt ?? .distantPast) > $0 } ?? false
      target = pages.count - (savedSince ? 2 : 1); inView = false
    }
    guard target >= 0 else { guide = "This is page 1. Show it again."; say("This is page 1."); return }
    if photoScan {
      // The page being photographed continues once the retake is saved. Queued photos taken before the retake began
      // are held the same way when they come up (`takeQueuedPhotos`).
      heldPhotos = (heldPhotos + openPhotos + laterPhotos).sorted { $0.taken < $1.taken }
      retakeFrom = taken ?? Date()
    }
    retake(page: target, inView: inView)
    guide = "Retaking page \(target + 1). " + (inView ? "Hold it steady." : "Turn back to it.")
    say(inView ? "Retaking page \(target + 1)." : "Page \(target + 1). Turn back to it.")
    // The open page's check was cancelled: go on with photos that were waiting for it.
    if photoScan { pumpPhotos() }
  }

  /// Aims the camera at an earlier page. A page that is not in view is photographed only once the view changes,
  /// so the sheet the wearer is still holding is never saved in its place.
  private func retake(page index: Int, inView: Bool) {
    // A 👍 waiting on the open page's check is dropped with that page: the scan continues with the retake.
    replacing = index; attempts = 0; forceCapture = false; holdForNext = false; finishRequested = false
    gate.reset(); turnGate.reset(); progress = 0; phase = .seeking
    discardOpenPage() // frames of the page being scanned are dropped; that page is scanned again after the retake
    laterPhotos = []
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
    camera.stop(); stopPhotos(); gate.reset(); turnGate.reset(); gestureGate.reset(); fixing = false
    voice.stopCommands(); voice.stopSpeaking(); phase = .idle; progress = 0
    guide = "Paused. \(pages.count) pages remain saved."; restoreIdleTimer(); endBackgroundWork()
    refreshPageStates()
  }
  /// Leaving the screen stops the camera but never cancels page solving or PDF creation.
  func backgrounded() {
    if !jobs.isEmpty || (photoScan && isCollecting) { beginBackgroundWork() } // let solves and checks in flight finish
    photosAway = true
    guard isCollecting else { return } // `connecting` may hand off to Meta AI for permission
    // Glasses photos keep arriving in the library (Meta AI may need to be opened to import them); they are picked up
    // as soon as the app is back.
    if photoScan { return }
    pauseScanning("Paused when the app left the screen. Your pages are saved; tap Continue or run the Glasses Scan shortcut.")
    say("Scanning paused. Open the app or run your Glasses Scan shortcut to continue.")
  }
  /// The app is in the foreground again: look for glasses photos imported meanwhile.
  func foregrounded() {
    photosAway = false
    guard photoScan && isCollecting else { return }
    // Time spent in Meta AI importing photos is not idle time.
    noteActivity(); photos.catchUp()
    if jobs.isEmpty { endBackgroundWork() }
  }
  func viewDisappeared() {
    guard (isCollecting || phase == .connecting) && !photoScan else { return }
    pauseScanning("Scanning paused. Your pages are saved.")
  }
  private func pauseScanning(_ message: String) {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel(); cancelPreviewRestart(); worker = nil; analysisTask = nil
    camera.stop(); stopPhotos(); gate.reset(); turnGate.reset(); gestureGate.reset(); voice.stopCommands(); fixing = false
    phase = .idle; progress = 0; guide = message; restoreIdleTimer()
  }

  private func begin(imported: Bool) {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel(); analysisTask = nil; cancelPreviewRestart(); cameraProblem = nil
    camera.stop(); stopPhotos(); voice.stopCommands(); voice.stopSpeaking()
    gate.reset(); turnGate.reset(); speechGate.reset(); gestureGate.reset()
    self.imported = imported; replacing = nil; finishRequested = false; forceCapture = false; captureFailures = 0
    finishCutoff = nil; retakeFrom = nil
    holdForNext = false; armAfterTurn = false; armGate.reset(); armDeadline = .infinity; recentViews = []; noteActivity()
    discardOpenPage(); savedPageWords = []; stillSpoken = false
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
          if pages.count < Self.maxPages, turnGate.observe(value, at: time) { noteActivity(); nextPage(fromTurn: true) }
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
        if captureMode == .frames && !imported { await collect(value, image: image, at: time, id: id); return }
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

  // MARK: Live-frame capture

  /// Seeking in frame mode: keep the clearest frame of each view of the page. Once the view has been steady for a moment
  /// the AI checks the page; it is saved when everything needed to solve it can be read, and otherwise the wearer hears
  /// what to show again. Without a key (or with checks off) the page is saved once nothing new appears for a moment.
  private func collect(_ value: PageSample, image: CGImage, at time: TimeInterval, id: UUID) async {
    let forced = forceCapture && value.acceptable && value.gesture == nil
    let steady = pageFrames.gate(value)
    if (steady || forced) && !reading && time - lastRead >= Self.readInterval {
      reading = true; lastRead = time
      let generation = pageGeneration
      let text = (try? await analyzer.readText(image)) ?? FrameText()
      guard runID == id, generation == pageGeneration else { return }
      reading = false
      guard phase == .seeking else { return }
      keep(value, image: image, text: text, at: time)
      if forced { forceCapture = false; await commitPage(id: id); return }
    }
    let cued = !steady && guideFrame(value, at: time)
    guard runID == id, phase == .seeking else { return }
    if checksActive {
      let changed = lastChange > checkedThrough || time >= retryCheckAt
      if pageCheck == nil, !pageFrames.isEmpty, changed, time - lastChange >= Self.checkQuiet { startCheck(id: id); return }
      if pageCheck == nil, !lastRetake.isEmpty, !changed, !reminded, time - verdictAt >= Self.remindAfter {
        // Never wait in silence: repeat what the page needs, and the way to keep it as it is.
        reminded = true; say("Page \(openNumber): \(lastRetake) Or thumbs-right to keep it as it is.")
      }
      if !pageFrames.isEmpty && !cued && pageCheck == nil && lastChange > checkedThrough {
        progress = min(0.99, (time - lastChange) / Self.checkQuiet)
        guide = "Page \(openNumber): \(pageSummary())"
      }
      return
    }
    if pageFrames.isComplete(at: time) { await commitPage(id: id); return }
    if !pageFrames.isEmpty && !cued {
      progress = min(0.99, (time - pageFrames.lastNew) / pageFrames.configuration.quietTime)
      guide = "Page \(openNumber): \(pageSummary())"
    }
  }

  private func keep(_ value: PageSample, image: CGImage, text: FrameText, at time: TimeInterval) {
    // The printed text must be readable; large handwriting alone does not make a frame worth keeping.
    guard pageFrames.isLegible(text) else {
      guide = "Move a little closer: the printed text is too small to read."; speakCue(.closer, at: time); return
    }
    if pageFrames.isEmpty, replacing == nil,
      PageFrames.overlap(text.signature, with: savedPageWords) >= pageFrames.configuration.sameView {
      // The sheet just saved is still in view (seen whole, or a part already kept): not the next page.
      if !stillSpoken {
        stillSpoken = true; say("Still page \(pages.count). Turn the page, or thumbs-left to retake it.")
      }
      return
    }
    let frameID = nextFrameID; nextFrameID += 1
    pageFrames.keepCloserViews = checksActive && !lastRetake.isEmpty; pageFrames.evictWhenFull = checksActive
    switch pageFrames.offer(value, text: text, id: frameID, at: time) {
    case .added(let new):
      keptImages[new] = (image, value)
    case .replaced(let old, let new):
      keptImages[old] = nil; keptImages[new] = (image, value)
    case .duplicate:
      return
    case .full:
      // Without a check: this page is done; the view in front of the wearer starts the next page.
      forceCapture = false
      let run = runID
      Task { [weak self] in await self?.commitPage(id: run) }
      return
    }
    noteActivity(); stillSpoken = false; lastChange = time
  }

  /// Directions for a frame that cannot be kept; returns whether one was given (it stays on screen this frame).
  private func guideFrame(_ value: PageSample, at time: TimeInterval) -> Bool {
    let tooSmall = value.acceptable && value.contentBounds != nil && !pageFrames.isBigEnough(value)
    let cue: ScanCue = tooSmall || (!value.closeEnough && value.cue == .hold) ? .closer : value.cue
    guard pageFrames.isEmpty || !value.acceptable || tooSmall else { return false }
    guide = value.issue ?? cue.message; speakCue(cue, at: time)
    return true
  }

  /// Pages are checked when the wearer scans with the glasses, a key is set, and checks have not failed for good.
  private var checksActive: Bool { checkPages && (photoScan || captureMode == .frames) && !imported && checkKey && checksOff == nil }

  private typealias KeptFrame = (id: Int, image: CGImage, sample: PageSample)
  private var openFrames: [KeptFrame] {
    pageFrames.frameIDs.compactMap { id in keptImages[id].map { (id: id, image: $0.image, sample: $0.sample) } }
  }

  /// Sends the open page's frames to the AI. Frames kept meanwhile wait for the next check; if this one says the page is
  /// clear, exactly the checked frames are saved (later ones may already show the next sheet), as the same JPEGs the
  /// check judged.
  private func startCheck(id: UUID) {
    let frames = openFrames
    guard !frames.isEmpty else { return }
    let through = lastChange
    checkedThrough = through; retryCheckAt = .infinity
    let generation = pageGeneration, number = openNumber, configuration = configurationProvider(), checker = self.checker
    // A retake is checked against an earlier photo of that page, so another sheet in view is not saved in its place.
    let reference = replacing.flatMap { pages.indices.contains($0) ? pages[$0].frames.first : nil }
    guide = "Checking page \(number)…"; progress = 0
    if lastRetake.isEmpty && checkFailures == 0 { say("Checking page \(number).") }
    let images = frames.map(\.image)
    pageCheck = Task { [weak self] in
      let outcome: Result<(PageVerdict, [Data]), any Error>
      do {
        let (jpegs, earlier) = try await Task.detached(priority: .userInitiated) {
          (try images.map { try PageAnalyzer.encodeJPEG($0, quality: 0.9) }, reference.flatMap { try? Data(contentsOf: $0) })
        }.value
        let verdict = try await withDeadline(Self.checkTimeout) {
          try await checker.check(jpegs, page: number, context: PageCheckContext(reference: earlier), configuration: configuration)
        }
        outcome = .success((verdict, jpegs))
      } catch { outcome = .failure(error) }
      await self?.checked(outcome, frames: frames, through: through, generation: generation, id: id)
    }
  }

  private func checked(_ outcome: Result<(PageVerdict, [Data]), any Error>, frames: [KeptFrame], through: TimeInterval,
                       generation: Int, id: UUID) async {
    guard runID == id, generation == pageGeneration, phase == .seeking else { return }
    pageCheck = nil
    let number = openNumber
    switch outcome {
    case .success(let (verdict, jpegs)):
      verdictThrough = through; failedCheckPages = 0
      if verdict.wrongSheet, replacing != nil {
        // Not the page being retaken: drop those photos and keep waiting for it.
        let ids = Set(frames.map(\.id))
        pageFrames.remove(ids); for frame in ids { keptImages[frame] = nil }
        let message = "That's a different sheet. Turn to page \(number)."
        if finishRequested { finishRequested = false; finishAnyway = true }
        guide = message; progress = 0; say(message); return
      }
      let dropped = Set(verdict.dropped.filter { frames.indices.contains($0 - 1) }.map { $0 - 1 })
      let usable = frames.indices.filter { !dropped.contains($0) }
      checkFailures = 0
      if verdict.clear, !usable.isEmpty {
        await commitPage(id: id, frames: usable.map { frames[$0] }, jpegs: usable.map { jpegs[$0] }, checked: true); return
      }
      // Photos of another sheet, or of nothing readable, would only mislead the solver; never drop every photo.
      if !usable.isEmpty {
        let ids = Set(dropped.map { frames[$0].id })
        pageFrames.remove(ids); for frame in ids { keptImages[frame] = nil }
      }
      let advice = verdict.clear ? "Look at page \(number) again, closer." : verdict.say
      let message: String
      if verdict.notShownYet && !finishRequested {
        // The wearer is probably still scanning the page: guide, but don't escalate or repeat the same request aloud.
        let repeated = advice == lastRetake
        lastRetake = advice; verdictAt = ProcessInfo.processInfo.systemUptime; reminded = false
        guide = "Page \(number): \(advice)"; progress = 0
        if !repeated { say(guide) }
        return
      }
      checkRounds += 1
      if finishRequested {
        finishRequested = false; finishAnyway = true
        message = "Page \(number): \(advice) Or thumbs-up to solve anyway."
      } else if checkRounds >= Self.maxCheckRounds {
        // Bounded: the wearer decides now instead of hearing the same request again.
        message = "Page \(number) still isn't clear: \(advice) Thumbs-right keeps it."
      } else if checkRounds >= 2 {
        message = "Page \(number): \(advice == lastRetake ? "Still unclear. " : "")\(advice) Or thumbs-right to keep it as it is."
      } else {
        message = "Page \(number): \(advice)"
      }
      lastRetake = advice; verdictAt = ProcessInfo.processInfo.systemUptime; reminded = false
      guide = message; progress = 0; say(message)
    case .failure(let error):
      if error is CancellationError { return }
      // Only the frames this check covered are saved; frames kept meanwhile may already show the next sheet.
      if Self.stopsChecks(error) {
        // A key, billing or model problem would fail every page: from now on pages are saved once nothing new appears,
        // starting with this one, which the wearer may still be scanning.
        checksOff = error.localizedDescription
        say("Page checks are off. \(error.localizedDescription) Pages are saved without a check.")
        pageFrames.touch(at: ProcessInfo.processInfo.systemUptime)
        if finishRequested { await commitPage(id: id, frames: frames) }
        return
      }
      checkFailures += 1
      if checkFailures >= 2 {
        failedCheckPages += 1
        if failedCheckPages >= 2 {
          checksOff = "The AI did not answer the page checks."
          say("Couldn't check page \(number), so it's saved without a check. Page checks are off for this scan.")
        } else {
          say("Couldn't check page \(number), so it's saved without a check.")
        }
        await commitPage(id: id, frames: frames); return
      }
      retryCheckAt = ProcessInfo.processInfo.systemUptime + 2
      guide = "Couldn't check page \(number). Trying again…"; say("Checking page \(number) again.")
    }
  }

  /// Errors that would repeat for every page (key, billing, model or request problems), as opposed to a dropped
  /// connection, an overload, a slow or malformed answer, or one declined page.
  private static func stopsChecks(_ error: any Error) -> Bool {
    if let service = error as? AIServiceError { return !service.isRetryable }
    return false
  }

  /// Saves the page: the checked frames, or every kept frame (👉, 👍 without a check, or no check available),
  /// in the order they were first taken, and continues like a saved still.
  private func commitPage(id: UUID, frames chosen: [KeptFrame]? = nil, jpegs encoded: [Data]? = nil, checked: Bool = false) async {
    let kept = chosen ?? openFrames
    guard runID == id, phase == .seeking, !kept.isEmpty else { return }
    pageCheck?.cancel(); pageCheck = nil
    let summary = "\(kept.count) photo\(kept.count == 1 ? "" : "s")"
    phase = .checking; progress = 0; guide = "Saving page \(openNumber): \(summary)…"
    let images = kept.map(\.image)
    do {
      let (jpegs, thumbnail) = try await Task.detached(priority: .userInitiated) {
        let jpegs = try encoded ?? images.map { try PageAnalyzer.encodeJPEG($0, quality: 0.9) }
        return (jpegs, PageAnalyzer.thumbnail(jpegs[0])) // a small preview, not a full frame kept per page
      }.value
      guard runID == id else { return }
      // The next page is whatever looks unlike every view of this one, and does not repeat its text.
      turnGate.saved(kept.map(\.sample), at: ProcessInfo.processInfo.systemUptime)
      let words = pageFrames.words(of: Set(kept.map(\.id)))
      discardOpenPage()
      savedPageWords = words; stillSpoken = false
      try await saved(jpegs, thumbnail: thumbnail, restart: nil, id: id, summary: summary, checked: checked)
    } catch {
      guard runID == id else { return }
      fail(error.localizedDescription + " Your saved pages are kept.")
    }
  }

  private func discardOpenPage() {
    pageFrames = PageFrames(configuration: Self.frameConfiguration)
    keptImages = [:]; reading = false; lastRead = -Double.infinity; pageGeneration += 1
    pageCheck?.cancel(); pageCheck = nil; lastChange = -Double.infinity; checkedThrough = -Double.infinity
    checkRounds = 0; checkFailures = 0; retryCheckAt = .infinity; lastRetake = ""; finishAnyway = false
    verdictThrough = -Double.infinity; verdictAt = -Double.infinity; reminded = false
    openPhotos = []; photoCheck?.cancel(); photoCheck = nil; pageChecks = 0; earlierSpoken = false
  }

  /// The page being scanned: the one it replaces, or the next new page.
  private var openNumber: Int { (replacing ?? pages.count) + 1 }
  private func pageName(_ index: Int) -> String { "Page \(index + 1)" }
  /// "3 photos" for the page being scanned.
  private func pageSummary() -> String {
    let count = pageFrames.kept.count
    return "\(count) photo\(count == 1 ? "" : "s")"
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
    phase = .capturing; guide = "Taking \(pageName(replacing ?? pages.count).lowercased()). Keep still…"; progress = 0
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
    guide = "The photo didn't come through. Show \(pageName(replacing ?? pages.count).lowercased()) again."; say(guide)
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
      // A photo picked on the phone is the user's choice (2.7); only glasses stills are judged on the device.
      if !imported && (!photo.sample.acceptable || !photo.sample.closeEnough) {
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
      try await saved([photo.jpeg], thumbnail: photo.thumbnail, restart: restart, id: id)
    } catch {
      restart?.cancel(); guard runID == id else { return }
      fail(cameraProblem.map { $0 + " Your saved pages are kept." } ?? error.localizedDescription)
    }
  }

  /// Saves the page (a still or a set of frames) and moves on: the next page, the next unclear page, or solving.
  /// `restart` is the preview restart running after a still; frames never stop the preview.
  /// `checked`: the AI confirmed the page can be read and solved, so the wearer hears it is clear.
  private func saved(_ jpegs: [Data], thumbnail: CGImage?, restart: Task<Void, any Error>?, id: UUID,
                     summary: String? = nil, checked: Bool = false) async throws {
    let index = replacing ?? pages.count
    let replacedEarlierPage = replacing.map { $0 < pages.count - 1 } ?? false
    pages = try draft.add(frames: jpegs, to: pages, replacing: replacing)
    packetSolved = false
    let page = pages[index]
    if let thumbnail { thumbnails[page.id] = UIImage(cgImage: thumbnail) }
    capturedPreview = thumbnails[page.id]; replacing = nil; attempts = 0; lastSaved = index; noteActivity()
    pruneThumbnails()
    syncJobs() // the previous page now has its next-page context and can be solved
    let urls = Set(pages.flatMap(\.frames)), solver = self.solver
    Task { await solver.forget(keeping: urls) }
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    if photoScan && !imported { photoPageSaved(index, checked: checked); return }
    if finishRequested {
      restart?.cancel(); finishRequested = false; phase = .idle; finishScanning(); return
    }
    if let message = cameraProblem { fail(message + " Your saved pages are kept."); return }
    if imported {
      phase = .idle; restoreIdleTimer()
      guide = "\(pageName(index)) saved. Add another photo, or finish to solve."
    } else if fixing {
      // Asked for after Finish: continue with the next unclear page, or go straight back to solving.
      if let next = nextFixTarget() {
        try await restart?.value
        guard runID == id else { return }
        askAgain(for: next, after: "\(pageName(index)) \(checked ? "is clear" : "saved").")
      } else {
        restart?.cancel(); fixing = false; phase = .idle
        say("\(pageName(index)) \(checked ? "is clear" : "saved")."); finishScanning()
      }
    } else if replacedEarlierPage {
      // The sheets in front of the wearer were already scanned, so a page turn must not add them again.
      // The camera stays on: 👉 at the first new page continues, 👍 solves.
      try await restart?.value
      guard runID == id else { return }
      phase = .awaitingNext; holdForNext = true; progress = 0
      if pages.count < Self.maxPages {
        guide = "\(pageName(index)) replaced. Turn to the next new page, then give a thumbs-right. Thumbs-up solves."
        say("\(pageName(index)) replaced. At the next new page, thumbs-right. Or thumbs-up to solve.")
      } else {
        guide = "\(pageName(index)) replaced. Give a thumbs-up to solve."; say(guide)
      }
    } else {
      try await restart?.value
      guard runID == id else { return }
      if finishRequested { finishRequested = false; phase = .idle; finishScanning(); return }
      phase = .awaitingNext; progress = 0; awaitingSince = ProcessInfo.processInfo.systemUptime; nextHintGiven = false
      if pages.count < Self.maxPages {
        let saved = checked ? "\(pageName(index)) is clear." : "\(pageName(index)) saved" + (summary.map { ": \($0)" } ?? "") + "."
        guide = saved + " Turn the page. Thumbs-left retakes it; thumbs-up finishes."
        say(helpGiven.insert("saved").inserted ? saved + " Turn the page. Thumbs-up when you're done." : saved + " Turn the page.")
      } else {
        guide = "Page limit reached. Give a thumbs-up to finish."; say(guide)
      }
    }
  }
  /// Hands-free scanning keeps guiding instead of giving up after unclear stills.
  private func retakeUnclearStill(_ reason: String) throws {
    guard !imported else { throw SolverError.message(reason + " Choose a clearer photo.") }
    let number = (replacing ?? pages.count) + 1
    guide = "That photo wasn't clear. Show \(pageName(number - 1).lowercased()) again. \(reason)"
    say("Show \(pageName(number - 1).lowercased()) again. \(reason)")
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
    // Glasses photos always solve as they go: each page once the next one is saved.
    solveSetup = (solveWhileScanning || photoScan) && (try? configuration.validate()) != nil ? configuration : nil
  }

  // MARK: Glasses photos

  /// The wearer takes each photo with the glasses' capture button. Nothing streams from the glasses: Meta AI imports the
  /// photos into Photos, and each one is checked with the page it belongs to as soon as it arrives. A page is saved once
  /// it is clear (or the wearer keeps it), and solved as soon as the next page is saved.
  private func startPhotos(replacing index: Int?) {
    begin(imported: false); replacing = index; photoScan = true
    planFinal = false; helpGiven = []; handsFree = true; fixing = false; lastSaved = nil
    refreshSolveSetup(); syncJobs()
    let keyMissing = (try? configurationProvider().validate()) == nil
    checkKey = !keyMissing; checksOff = nil; failedCheckPages = 0
    photosReceived = 0; photoHintGiven = false; needsPhotoAccess = false
    photoStatus = "Waiting for the first photo from Meta AI…"
    // Continue where this packet's last scan stopped (at most 10 minutes back), allowing a small clock difference.
    let now = Date()
    // Retaking a page of a finished packet: older photos are not part of it.
    let resume = index != nil && packetSolved ? now : photosResumeFrom ?? now
    let start = max(min(resume, now), now.addingTimeInterval(-600))
    retakeFrom = index != nil ? now : nil
    let since = start.addingTimeInterval(-ButtonPhotos.lookback)
    photoRunStart = start; lastPhotoTaken = nil
    let id = runID
    phase = .connecting; guide = "Opening your photos…"
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        try await prepareVoice(id: id)
        watchingPhotos = true // photos can arrive before `start` returns
        try await photos.start(since: since) { [weak self] photo in self?.receivePhoto(photo, run: id) }
        try Task.checkCancellation(); guard runID == id else { return }
      } catch {
        guard runID == id else { return }
        needsPhotoAccess = error is PhotoSourceError
        fail(error.localizedDescription); return
      }
      photosResumeFrom = nil
      phase = .seeking; noteActivity(); photoStart = ProcessInfo.processInfo.systemUptime
      startPhotoTimer(run: id)
      let number = openNumber
      if let index {
        guide = "Take page \(index + 1) again with the capture button."; say("Take page \(index + 1) again.")
      } else if keyMissing {
        guide = "No API key yet, so each photo is saved as its own page. Add a key in Settings before you finish."
        say("Ready. No API key yet, so each photo is saved as its own page.")
      } else {
        guide = "Page \(number): take photos with the capture button on your glasses. You'll hear when it's clear. A photo of a thumbs-up solves."
        say(pages.isEmpty ? "Ready. Take a photo of page 1 with the capture button. I'll tell you when it's clear."
          : "Ready for page \(number).")
      }
      pumpPhotos()
    }
  }

  private func receivePhoto(_ photo: IncomingPhoto, run: UUID) {
    guard runID == run, photoScan, !usedPhotos.contains(photo.id) else { return }
    usedPhotos.insert(photo.id); photosReceived += 1; noteActivity()
    lastPhotoTaken = max(lastPhotoTaken ?? photo.taken, photo.taken)
    let delay = max(0, Int(photo.arrived.timeIntervalSince(photo.taken).rounded()))
    photoStatus = "\(photosReceived) photo\(photosReceived == 1 ? "" : "s") received. The last one reached the phone \(delay) s after it was taken."
    intake.append(photo); persistPhotoState() // pending, so a relaunch looks back for it rather than skipping it
    drainIntake(run: run)
  }

  /// Looks at each photo, in order, for a hand command held up to the glasses before it joins a page, so a command
  /// never overtakes the photos taken before it.
  private func drainIntake(run: UUID) {
    guard intakeTask == nil else { return }
    let analyzer = self.analyzer
    intakeTask = Task { [weak self] in
      while let self, self.runID == run, let photo = self.intake.first {
        let jpeg = photo.jpeg
        let gesture = await analyzer.photoGesture(jpeg)
        let thumbnail = await Task.detached(priority: .userInitiated) { PageAnalyzer.thumbnail(jpeg, maxPixel: 720) }.value
        guard self.runID == run else { return } // still in `intake`, so a stopped scan releases it
        self.intake.removeFirst()
        if let thumbnail { self.preview = thumbnail }
        self.photoEvents.append(gesture.map { .command(Self.command(for: $0), taken: photo.taken) }
          ?? .photo(PagePhoto(id: photo.id, jpeg: jpeg, taken: photo.taken)))
        self.pumpPhotos()
      }
      guard let self, self.runID == run else { return }
      self.intakeTask = nil; self.pumpPhotos()
    }
  }
  private static func command(for gesture: HandGesture) -> ScanCommand {
    switch gesture {
    case .thumbsUp: return .finish
    case .thumbsRight, .openPalm: return .next
    case .thumbsLeft, .thumbsDown: return .previous
    }
  }
  /// Photos still on their way: in a check, queued, being looked at, or being read from the library.
  private var photoBusy: Bool {
    photoCheck != nil || !photoEvents.isEmpty || !intake.isEmpty || intakeTask != nil || photos.isDelivering
  }
  private var photosWaiting: Bool {
    !intake.isEmpty || photoEvents.contains { if case .photo = $0 { return true }; return false }
  }

  /// The page photos queued next (up to the first command). During a retake, photos taken before it began are held for
  /// the pages after it; during a 👍 finish, photos taken after the 👍 photo are left for the next packet.
  private func takeQueuedPhotos() -> [PagePhoto] {
    var batch: [PagePhoto] = []
    while case .photo(let photo)? = photoEvents.first { photoEvents.removeFirst(); batch.append(photo) }
    if finishRequested, let cutoff = finishCutoff {
      let after = batch.filter { $0.taken > cutoff }
      for photo in after { usedPhotos.remove(photo.id) }
      batch.removeAll { $0.taken > cutoff }
    }
    if replacing != nil, let from = retakeFrom {
      heldPhotos += batch.filter { $0.taken < from }
      batch.removeAll { $0.taken < from }
    }
    return batch
  }
  /// A queued 👍 photo finishes with the photos taken before it; 👈 retakes the page before, as of when it was taken.
  private func photoCommand(_ command: ScanCommand, taken: Date) {
    switch command {
    case .finish: noteActivity(); finishCutoff = taken; finishScanning()
    case .previous: noteActivity(); previousPage(asOf: taken)
    case .next, .cancel: handle(command)
    }
  }
  /// The wearer is told what to do instead of finishing.
  private func cancelFinish() { finishRequested = false; finishCutoff = nil }

  /// Moves the photos taken next into the open page and checks it: one check at a time, in the order photos were taken,
  /// so a command photo (👍 solve, 👉 keep the page, 👈 retake the page before) applies after the photos before it.
  private func pumpPhotos() {
    guard photoScan, phase == .seeking, photoCheck == nil else { return }
    if case .command(let command, let taken)? = photoEvents.first {
      photoEvents.removeFirst(); photoCommand(command, taken: taken); pumpPhotos(); return
    }
    let batch = takeQueuedPhotos()
    guard !batch.isEmpty else {
      if !photoEvents.isEmpty { pumpPhotos(); return } // a command follows the photos held or left out
      if finishRequested && !photoBusy { finishScanning() }
      return
    }
    guard replacing != nil || pages.count < Self.maxPages else {
      photoEvents = []; finishRequested = true; finishAnyway = true
      guide = "That's the limit of \(Self.maxPages) pages. Solving."; say(guide)
      if !photoBusy { finishScanning() }
      return
    }
    openPhotos += batch
    if checksActive { startPhotoCheck(); return }
    // Without a check nothing tells sheets apart, so each photo is its own page.
    photoEvents.insert(contentsOf: openPhotos.dropFirst().map { .photo($0) }, at: 0)
    openPhotos = [openPhotos[0]]
    commitPhotoPage(checked: false)
  }

  /// Checks every photo of the open page together. A retake is compared with an earlier photo of that page, and a new
  /// page with a photo of the page before it, so a late photo of a finished sheet never starts a duplicate page.
  private func startPhotoCheck() {
    let checked = openPhotos
    guard !checked.isEmpty else { return }
    let run = runID, generation = pageGeneration, number = openNumber, configuration = configurationProvider()
    let checker = self.checker
    let reference = replacing.flatMap { pages.indices.contains($0) ? pages[$0].frames.first : nil }
    let earlierPage = replacing == nil ? pages.last?.frames.first : nil
    guide = "Checking page \(number)…"; progress = 0
    if pageChecks == 0 && checkFailures == 0 { say("Checking page \(number).") }
    photoCheck = Task { [weak self] in
      let outcome: Result<PageVerdict, any Error>
      do {
        let (sameSheet, earlier) = await Task.detached(priority: .userInitiated) {
          (reference.flatMap { try? Data(contentsOf: $0) }, earlierPage.flatMap { try? Data(contentsOf: $0) })
        }.value
        let context = PageCheckContext(reference: sameSheet, earlier: earlier, buttonPhotos: true)
        let jpegs = checked.map(\.jpeg)
        outcome = .success(try await withDeadline(Self.photoCheckTimeout) {
          try await checker.check(jpegs, page: number, context: context, configuration: configuration)
        })
      } catch { outcome = .failure(error) }
      self?.photoChecked(outcome, photos: checked, run: run, generation: generation)
    }
  }

  private func photoChecked(_ outcome: Result<PageVerdict, any Error>, photos checked: [PagePhoto], run: UUID, generation: Int) {
    guard runID == run, generation == pageGeneration, photoScan, phase == .seeking else { return }
    photoCheck = nil; pageChecks += 1
    let number = openNumber
    switch outcome {
    case .success(let verdict):
      failedCheckPages = 0; checkFailures = 0
      func ids(_ numbers: [Int]) -> Set<String> {
        Set(numbers.filter { checked.indices.contains($0 - 1) }.map { checked[$0 - 1].id })
      }
      let earlier = ids(verdict.earlierSheet), other = ids(verdict.otherSheet)
      let unusable = earlier.union(other).union(ids(verdict.blurry))
      openPhotos.removeAll { unusable.contains($0.id) }
      // Photos of the next sheet wait until this page is done; while retaking a page, other sheets are not wanted.
      if replacing == nil {
        laterPhotos = (laterPhotos + checked.filter { other.contains($0.id) && !earlier.contains($0.id) }).sorted { $0.taken < $1.taken }
      }
      if !earlier.isEmpty && !earlierSpoken && number > 1 {
        earlierSpoken = true; say("That's page \(number - 1) again. It's already saved.")
      }
      if verdict.clear && !openPhotos.isEmpty { commitPhotoPage(checked: true); return }
      if openPhotos.isEmpty {
        if !laterPhotos.isEmpty {
          // Nothing usable of this page: the next sheet's photos start it.
          photoEvents.insert(contentsOf: laterPhotos.map { .photo($0) }, at: 0); laterPhotos = []
        } else if checked.allSatisfy({ earlier.contains($0.id) }) {
          guide = "Page \(number): take a photo of it with the capture button."
        } else {
          let message = replacing != nil && !other.isEmpty ? "That's a different sheet. Take page \(number) again."
            : "Page \(number): \(verdict.say)"
          guide = message; progress = 0; say(message)
        }
        pumpPhotos(); return
      }
      let advice = verdict.say
      let message: String
      if finishRequested && !photosWaiting {
        cancelFinish(); finishAnyway = true
        message = "Page \(number): \(advice) Or a thumbs-up photo solves anyway."
      } else if finishRequested {
        message = "Page \(number): \(advice)" // photos already taken may still make it clear before finishing
      } else if verdict.notShownYet && laterPhotos.isEmpty {
        message = "Page \(number): \(advice)" // the wearer may still be photographing the sheet
      } else {
        checkRounds += 1
        if !laterPhotos.isEmpty {
          message = "Page \(number) isn't clear yet: \(advice) Go back to it, or a thumbs-right photo keeps it as it is."
        } else if checkRounds >= Self.maxCheckRounds {
          message = "Page \(number) still isn't clear: \(advice) A thumbs-right photo keeps it as it is."
        } else {
          message = "Page \(number): \(advice)"
        }
      }
      lastRetake = advice; verdictAt = ProcessInfo.processInfo.systemUptime
      guide = message; progress = 0; say(message)
      pumpPhotos()
    case .failure(let error):
      if error is CancellationError { return }
      if Self.stopsChecks(error) {
        // A key, billing or model problem would fail every page.
        checksOff = error.localizedDescription
        say("Page checks are off. \(error.localizedDescription) Each photo is saved as its own page.")
        commitPhotoPage(checked: false); return
      }
      checkFailures += 1
      if checkFailures >= 2 {
        failedCheckPages += 1
        if failedCheckPages >= 2 {
          checksOff = "The AI did not answer the page checks."
          say("Couldn't check page \(number), so it's saved without a check. Page checks are off; each photo is now its own page.")
        } else {
          say("Couldn't check page \(number), so it's saved without a check.")
        }
        commitPhotoPage(checked: false); return
      }
      guide = "Couldn't check page \(number). Trying again…"; say("Checking page \(number) again.")
      photoCheck = Task { [weak self] in
        try? await Task.sleep(for: .seconds(2))
        guard let self, self.runID == run, self.pageGeneration == generation, self.phase == .seeking else { return }
        self.photoCheck = nil; self.startPhotoCheck()
      }
    }
  }

  /// Saves the open page's photos in the order they were taken; the photos after them continue with the next page.
  private func commitPhotoPage(checked: Bool) {
    let kept = openPhotos.sorted { $0.taken < $1.taken }
    guard photoScan, phase == .seeking, !kept.isEmpty else { return }
    let run = runID
    photoCheck?.cancel(); photoCheck = nil
    phase = .checking; progress = 0; guide = "Saving page \(openNumber)…"
    Task { [weak self] in
      let jpegs = kept.map(\.jpeg)
      let thumbnail = await Task.detached(priority: .userInitiated) { PageAnalyzer.thumbnail(jpegs[0]) }.value
      guard let self, self.runID == run else { return }
      self.discardOpenPage()
      do { try await self.saved(jpegs, thumbnail: thumbnail, restart: nil, id: run, checked: checked) }
      catch {
        guard self.runID == run else { return }
        self.openPhotos = kept // released by `fail`, so continuing the scan picks them up again
        self.fail(error.localizedDescription + " Your saved pages are kept.")
      }
    }
  }

  /// 👉 (a thumbs-right photo, the phone or a voice command): the open page is saved as it is, checked or not.
  private func keepPhotoPage() {
    guard phase == .seeking else { return }
    openPhotos += takeQueuedPhotos() // photos already taken of this page belong to it
    guard !openPhotos.isEmpty else {
      let message = "Take a photo of page \(openNumber) first."
      guide = message; say(message); return
    }
    commitPhotoPage(checked: false)
  }

  /// A page is saved: say so, and go on with any photos already taken after it.
  private func photoPageSaved(_ index: Int, checked: Bool) {
    phase = .seeking; progress = 0; lastPageSavedAt = Date(); retakeFrom = nil
    let waiting = (heldPhotos + laterPhotos).sorted { $0.taken < $1.taken }
    if !waiting.isEmpty { photoEvents.insert(contentsOf: waiting.map { .photo($0) }, at: 0); heldPhotos = []; laterPhotos = [] }
    persistPhotoState()
    let done = "\(pageName(index)) \(checked ? "is clear" : "saved")."
    if finishRequested || !photoEvents.isEmpty || pages.count >= Self.maxPages {
      guide = done; say(done) // photos of the next page are already here, or the scan is finishing
    } else {
      let next = "Take page \(pages.count + 1)."
      guide = "\(done) \(next) A photo of a thumbs-up solves everything."
      say(helpGiven.insert("photoSaved").inserted ? "\(done) \(next) When you're done, take a photo of a thumbs-up." : "\(done) \(next)")
    }
    pumpPhotos()
  }

  /// Finishing a glasses-photo scan: photos still on their way are checked first, and the open page is saved (once
  /// clear, or as it is after the wearer heard it is unclear). Returns true once only solving is left.
  private func finishPhotoPages() -> Bool {
    if photoBusy {
      if !finishRequested { say("Finishing after the last photos are checked.") }
      finishRequested = true; guide = "Finishing after the last photos are checked…"; return false
    }
    if !openPhotos.isEmpty {
      if checksActive && !finishAnyway && !lastRetake.isEmpty {
        finishAnyway = true; cancelFinish()
        let message = "Page \(openNumber) still isn't clear: \(lastRetake) Or a thumbs-up photo solves anyway."
        guide = message; say(message); return false
      }
      finishRequested = true; commitPhotoPage(checked: false); return false
    }
    if !laterPhotos.isEmpty || !heldPhotos.isEmpty {
      // An unfinished retake is dropped; photos taken before it become pages.
      replacing = nil; retakeFrom = nil
      photoEvents = (heldPhotos + laterPhotos).sorted { $0.taken < $1.taken }.map { .photo($0) }
      heldPhotos = []; laterPhotos = []
      finishRequested = true; pumpPhotos(); return false
    }
    guard !pages.isEmpty else {
      // Every photo so far was unreadable or of a page already done.
      cancelFinish()
      guide = "No page is saved yet. Take a photo of page 1."; say(guide); return false
    }
    return true
  }

  /// Stops watching for photos. Photos not yet on a saved page are freed, so continuing the scan picks them up again.
  private func stopPhotos() {
    photos.stop()
    if watchingPhotos {
      let pending = pendingPhotos()
      for photo in pending { usedPhotos.remove(photo.id) }
      photosResumeFrom = resumePoint(pending)
    }
    watchingPhotos = false
    intakeTask?.cancel(); intakeTask = nil; intake = []; photoEvents = []
    photoCheck?.cancel(); photoCheck = nil; photoTimer?.cancel(); photoTimer = nil
    openPhotos = []; laterPhotos = []; heldPhotos = []
    if photoScan { persistPhotoState() }
  }

  /// Photos received but not on a saved page yet.
  private func pendingPhotos() -> [(id: String, taken: Date)] {
    intake.map { ($0.id, $0.taken) }
      + photoEvents.compactMap { event in
        if case .photo(let photo) = event { return (photo.id, photo.taken) }
        return nil
      }
      + (openPhotos + laterPhotos + heldPhotos).map { ($0.id, $0.taken) }
  }
  /// Where a continued scan looks back from: the oldest photo not yet on a page, else the newest photo received, else
  /// when this scan started.
  private func resumePoint(_ pending: [(id: String, taken: Date)]) -> Date {
    min(pending.map(\.taken).min() ?? lastPhotoTaken ?? photoRunStart ?? Date(), Date())
  }
  /// Kept with the draft, so a scan continued after iOS ended the app finds photos taken meanwhile and skips used ones.
  private func persistPhotoState() {
    let pending = watchingPhotos ? pendingPhotos() : []
    let resume = watchingPhotos ? resumePoint(pending) : photosResumeFrom
    let used = usedPhotos.subtracting(pending.map(\.id))
    try? draft.savePhotoState(PhotoScanState(resumeFrom: resume, used: used.sorted()))
  }

  private func startPhotoTimer(run: UUID) {
    photoTimer?.cancel()
    photoTimer = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        guard let self, self.runID == run, self.photoScan, self.isCollecting else { return }
        self.photoTick()
      }
    }
  }
  /// Says how photos reach the phone if none has arrived soon after Start, and solves after a long pause.
  private func photoTick() {
    let now = ProcessInfo.processInfo.systemUptime
    if photosReceived == 0, !photoHintGiven, !photosAway, now - photoStart >= Self.photoHintAfter {
      photoHintGiven = true
      guide = "No photo has reached the phone yet. In the Meta AI app, turn on Auto-import, or open its gallery to import your photos."
      say("No photos yet. Open Meta AI on your phone to import them.")
    }
    guard phase == .seeking, !photoBusy, !photosAway, now - lastActivity >= Self.photoIdleFinish else { return }
    guard !packetSolved, !pages.isEmpty || !openPhotos.isEmpty || !laterPhotos.isEmpty || !heldPhotos.isEmpty else {
      pauseScanning(packetSolved ? "Paused: no page was retaken, so your PDF is unchanged." : "Paused after 10 minutes without a photo.")
      say("Scanning paused."); return
    }
    noteActivity(); say("No new photos for 10 minutes. Solving.")
    finishAnyway = true; finishScanning()
  }

  // MARK: Solving

  func finishScanning() {
    if [.capturing, .checking].contains(phase) {
      finishRequested = true; guide = "Finishing after this photo is saved."; say("Finishing after this photo."); return
    }
    if photoScan && phase == .seeking && !finishPhotoPages() { return }
    if phase == .seeking, captureMode == .frames, !imported, !pageFrames.isEmpty {
      // Save the page being scanned first; solving starts as soon as it is saved. A page not yet confirmed clear is
      // checked first, unless the wearer already heard it is unclear and gives 👍 again to solve anyway.
      let run = runID
      if checksActive && !finishAnyway {
        if pageCheck == nil && lastChange <= verdictThrough && !lastRetake.isEmpty {
          finishAnyway = true
          let message = "Page \(openNumber) still isn't clear: \(lastRetake) Or thumbs-up to solve anyway."
          guide = message; say(message); return
        }
        finishRequested = true
        if pageCheck == nil { startCheck(id: run) }
        guide = "Checking page \(openNumber) before solving…"; return
      }
      finishRequested = true
      Task { [weak self] in await self?.commitPage(id: run) }
      return
    }
    guard canFinish else {
      if photoScan && isCollecting && packetSolved {
        // A retake of a finished packet that saved nothing: the PDF stays as it is.
        cancelFinish(); pauseScanning("No page was retaken, so your PDF is unchanged."); say(guide)
      }
      return
    }
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
    let frames = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.frames) })
    // Neighbors are context: their photos nearest this page (frames are in capture order) keep requests small.
    let job = PageJob(key: key, number: index + 1, primaryFrames: pages[index].frames,
      previousFrames: Array((key.previous.flatMap { frames[$0] } ?? []).suffix(2)),
      nextFrames: Array((key.next.flatMap { frames[$0] } ?? []).prefix(2)), mustSolve: mustSolve)
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
        } else if isCollecting && photoScan {
          // Glasses photos: the PDF lists that page for review; it can be retaken from the phone afterwards.
          solveStatus = message + " It's marked for review in the PDF; retake it from the phone afterwards."
          say(message + " It will be marked for review.")
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
    if handsFree, let target = nextFixTarget() {
      // Glasses photos: an unreadable page goes into the PDF for review instead of a camera retake.
      if photoScan { leftOut.formUnion(unclear.keys) } else { startFix(at: target); return }
    }
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
      let names = failed.compactMap { key in pages.firstIndex { $0.id == key.page }.map(pageName) }
      let detail = jobErrors[failed[0]] ?? ""
      let summary = failed.count == 1 ? detail : "\(names.joined(separator: ", ")) could not be solved. \(detail)"
      endBackgroundWork()
      if handsFree && !photoScan {
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
      guide = "Completing \(labels.joined(separator: ", ")) on \(pageName(number - 1).lowercased())…"
      refreshPageStates(); return
    }
    // A page the wearer chose to leave out stays visible in the PDF, with its photo, as an item to review.
    for (index, page) in pages.enumerated() where leftOut.contains(page.id) {
      let reason = unclear[page.id] ?? "The photo could not be read."
      let note = PageSolutionItem(label: pageName(index), problem: "This page could not be read, so it was left out.",
        steps: ["Retake \(pageName(index).lowercased()) and finish again to add its solutions."], answer: "—", check: "—",
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
    phase = .connecting; guide = unclear[pages[index].id] ?? "\(pageName(index)) is unclear."
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
        fail(error.localizedDescription + " Retake \(pageName(index).lowercased()) with the Retake button under it, then tap Done.")
      }
    }
  }

  private func askAgain(for index: Int, after prefix: String?, speak: Bool = true) {
    retake(page: index, inView: false); noteActivity()
    let reason = unclear[pages[index].id] ?? "\(pageName(index)) is unclear."
    guide = "\(reason) Show \(pageName(index).lowercased()) again, or give a thumbs-up to solve without it."
    if speak { say([prefix, fixRequest(for: index)].compactMap { $0 }.joined(separator: " ")) }
  }
  private func fixRequest(for index: Int) -> String {
    (unclear[pages[index].id] ?? "\(pageName(index)) is unclear.") + " Show \(pageName(index).lowercased()) again, or thumbs-up to solve without it."
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
    let id = runID, sources = pages.map(\.frames), names = pages.indices.map(pageName)
    let missing = pages.indices.filter { leftOut.contains(pages[$0].id) }.map(pageName)
    phase = .saving; progress = 1; guide = "Making your PDF…"
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        let solution = try PagePlan.combine(entries, providers: providers)
        // A packet solved again after a retake replaces its earlier folder: one folder per packet.
        let saved = try await saver.save(page: solution, sources: sources, names: names, replacing: draft.savedFolder)
        try Task.checkCancellation(); guard runID == id else { return }
        result = saved; phase = .finished
        let review = solution.problems.contains { $0.reviewNote?.hasPrefix("NEEDS REVIEW") == true }
        guide = review ? "Your PDF is ready. Check items marked NEEDS REVIEW." : "Your PDF is ready."
        guide += " Files › On My iPhone › Glasses Solver › Solutions › \(saved.pdf.deletingLastPathComponent().lastPathComponent)."
        if let calculator = saved.calculator {
          guide += " Calculator pictures: copy the folder \(calculator.lastPathComponent) to your fx-CG50."
        }
        if !missing.isEmpty { guide += " Left out unreadable: \(missing.joined(separator: ", "))." }
        // Keep the pages and cached answers so one page can be retaken and the PDF rebuilt quickly.
        // The next Start (or a new photo) begins a fresh packet; the PDF folder holds every original.
        try? draft.markSolved(); packetSolved = true
        try? draft.rememberFolder(saved.pdf.deletingLastPathComponent().lastPathComponent)
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
    photosResumeFrom = nil // `usedPhotos` stays: a new packet's look-back must not reuse the last packet's photos
    let solver = self.solver
    Task { await solver.forget(keeping: []) }
  }

  // MARK: Helpers

  private func fail(_ message: String) {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel(); analysisTask = nil; cancelPreviewRestart(); cameraProblem = nil
    camera.stop(); stopPhotos(); voice.stopCommands(); gate.reset(); restoreIdleTimer(); fixing = false
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
