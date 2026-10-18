import Foundation
import Observation
import AVFoundation
import UIKit

@Observable
@MainActor
final class AutoScanModel {
  enum Phase: String { case idle, connecting, seeking, capturing, checking, solving, saving, finished, failed }
  private(set) var phase: Phase = .idle
  private(set) var guide = "Point your glasses at the problem you want to solve."
  private(set) var progress = 0.0
  private(set) var preview: CGImage?
  private(set) var sample = PageSample()
  private(set) var result: SavedSolution?
  private(set) var capturedPreview: UIImage?
  private(set) var attempts = 0
  private(set) var needsKey = false
  var showPDF = false
  var voiceGuidance = true
  var isRunning: Bool { [.connecting, .seeking, .capturing, .checking, .solving, .saving].contains(phase) }
  var canRetry: Bool { phase == .failed && pendingJPEG != nil }

  @ObservationIgnored private let camera: any ScanCamera
  @ObservationIgnored private let analyzer: any PageAnalyzing
  @ObservationIgnored private let solver: any PageSolving
  @ObservationIgnored private let saver: any SolutionSaving
  @ObservationIgnored private let keyProvider: () -> String
  @ObservationIgnored private let modelProvider: () -> String
  @ObservationIgnored private let speech = AVSpeechSynthesizer()
  @ObservationIgnored private var worker: Task<Void, Never>?
  @ObservationIgnored private var analysisTask: Task<Void, Never>?
  @ObservationIgnored private var runID = UUID()
  @ObservationIgnored private var gate = StabilityGate()
  @ObservationIgnored private var lastFrameTime = -Double.infinity
  @ObservationIgnored private var speechGate = GuidanceSpeechGate()
  @ObservationIgnored private var aiRetakes = 0
  @ObservationIgnored private var pendingJPEG: Data?
  @ObservationIgnored private var previousIdleTimer: Bool?
  @ObservationIgnored private var isImported = false
  @ObservationIgnored private var settingsKey = ""
  @ObservationIgnored private var settingsModel = ""

  init(camera: any ScanCamera, analyzer: any PageAnalyzing = PageAnalyzer(),
       solver: any PageSolving = SolverClient(), saver: any SolutionSaving = SolutionStore(),
       keyProvider: @escaping () -> String = { SolverKeychain.read() },
       modelProvider: @escaping () -> String = { UserDefaults.standard.string(forKey: "solverModel") ?? "gpt-5.4" }) {
    self.camera = camera; self.analyzer = analyzer; self.solver = solver; self.saver = saver
    self.keyProvider = keyProvider; self.modelProvider = modelProvider
    camera.onFrame = { [weak self] image in self?.receive(image) }
    camera.onProblem = { [weak self] message in
      guard let self, self.isRunning else { return }
      if [.checking, .solving, .saving].contains(self.phase) {
        // Once the still is on the phone, a glasses disconnect must not discard the job.
        self.camera.stop()
      } else { self.fail(message) }
    }
    camera.onProgress = { [weak self] fraction in
      guard let self, self.phase == .capturing else { return }
      self.progress = fraction; self.guide = "Receiving full-resolution photo… \(Int(fraction * 100))%"
    }
    camera.onNotice = { [weak self] message in self?.guide = message; self?.say(message) }
  }

  func start() {
    guard !isRunning, configure() else { return }
    begin(imported: false)
    let id = runID
    phase = .connecting; guide = "Connecting to your glasses…"
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        try await camera.start()
        guard runID == id else { return }
        phase = .seeking; guide = "Point at the problem. The paper edges do not need to fit."
        say("Ready. Look at the problem you want to solve.")
      } catch {
        guard runID == id else { return }; fail(error.localizedDescription)
      }
    }
  }

  func importPhoto(_ data: Data) {
    guard !isRunning, configure() else { return }
    begin(imported: true)
    let id = runID
    phase = .checking; guide = "Checking the selected photo…"
    worker = Task { [weak self] in
      guard let self else { return }
      await process(data: data, id: id)
    }
  }

  func retrySavedPhoto() {
    guard let jpeg = pendingJPEG, !isRunning, configure() else { return }
    begin(imported: true, keepPhoto: true)
    phase = .solving
    let id = runID
    worker = Task { [weak self] in
      guard let self else { return }
      do { try await solve(jpeg, id: id) }
      catch { guard runID == id else { return }; fail(error.localizedDescription) }
    }
  }

  func stop() {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel()
    worker = nil; analysisTask = nil; camera.stop(); gate.reset()
    phase = .idle; progress = 0; guide = "Auto scan stopped."
    speech.stopSpeaking(at: .immediate); restoreIdleTimer()
  }

  func backgrounded() {
    // The first permission grant intentionally switches into Meta AI before a session exists.
    guard isRunning, phase != .connecting else { return }
    stop(); guide = "Paused when the app left the screen. Return and start again."
  }

  private func configure() -> Bool {
    settingsKey = keyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
    settingsModel = modelProvider().trimmingCharacters(in: .whitespacesAndNewlines)
    needsKey = settingsKey.isEmpty
    guard !needsKey else { guide = "Add your OpenAI API key in Settings first."; return false }
    guard !settingsModel.isEmpty else { guide = "Choose an AI model in Settings first."; return false }
    return true
  }

  private func begin(imported: Bool, keepPhoto: Bool = false) {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel(); analysisTask = nil
    camera.stop(); gate.reset(); speechGate.reset(); isImported = imported
    result = nil; showPDF = false; progress = 0; attempts = 0; aiRetakes = 0
    sample = PageSample(); preview = nil; lastFrameTime = -Double.infinity
    if !keepPhoto { pendingJPEG = nil; capturedPreview = nil }
    if previousIdleTimer == nil { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled }
    UIApplication.shared.isIdleTimerDisabled = true
  }

  private func receive(_ image: CGImage) {
    guard phase == .seeking else { return }
    preview = image
    let time = ProcessInfo.processInfo.systemUptime
    guard analysisTask == nil, time - lastFrameTime >= 0.33 else { return }
    lastFrameTime = time
    let id = runID
    analysisTask = Task { [weak self] in
      guard let self else { return }
      do {
        let value = try await analyzer.analyze(image, still: false)
        try Task.checkCancellation()
        guard runID == id, phase == .seeking else { return }
        analysisTask = nil
        sample = value
        progress = gate.observe(value, at: time)
        if !value.acceptable {
          guide = value.issue ?? ScanCue.findProblem.message
          speakCue(value.cue, at: time)
        } else if progress < 1 {
          // Offer directions first. A steady, detailed view can proceed even if framing is imperfect.
          let cue: ScanCue = progress >= 0.5 ? .hold : value.cue
          guide = cue == .hold ? "Hold still… \(Int(progress * 100))%" : cue.message
          speakCue(cue, at: time)
        } else {
          phase = .capturing; guide = "Taking a photo. Keep still…"; progress = 0
          say("Capturing. Keep still.")
          worker = Task { [weak self] in
            guard let self else { return }
            do {
              attempts += 1
              let data = try await camera.capture()
              guard runID == id else { return }
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
      phase = .checking; guide = "Checking the captured photo…"; progress = 0
      let photo = try await analyzer.prepare(data)
      try Task.checkCancellation()
      guard runID == id else { return }
      capturedPreview = UIImage(data: photo.jpeg)
      if !photo.sample.acceptable {
        try await retake(photo.sample.issue ?? "The photo was not clear enough.", id: id)
        return
      }
      pendingJPEG = photo.jpeg
      try await solve(photo.jpeg, id: id)
    } catch { guard runID == id else { return }; fail(error.localizedDescription) }
  }

  private func solve(_ jpeg: Data, id: UUID) async throws {
    phase = .solving; guide = "AI is reading and solving the photographed problem…"; progress = 0
    say("Photo received. Checking and solving your problem.")
    let page = try await solver.solve(jpeg: jpeg, key: settingsKey, model: settingsModel)
    try Task.checkCancellation()
    guard runID == id else { return }
    if !page.readable {
      aiRetakes += 1; pendingJPEG = nil
      guard aiRetakes <= 1 else { throw SolverError.message("AI still cannot read the problem. \(page.retakeReason)") }
      try await retake(page.retakeReason.isEmpty ? "The AI needs a clearer view of the writing." : page.retakeReason, id: id)
      return
    }
    phase = .saving; guide = "Creating your PDF…"
    let saved = try saver.save(page: page, jpeg: jpeg)
    try Task.checkCancellation()
    guard runID == id else { return }
    result = saved; pendingJPEG = nil
    camera.stop(); gate.reset(); restoreIdleTimer()
    phase = .finished; guide = "Your solution PDF is ready."; showPDF = true
    say("Your solution PDF is ready on your phone.")
  }

  private func retake(_ reason: String, id: UUID) async throws {
    guard !isImported else { throw SolverError.message(reason + " Choose a clearer photo.") }
    guard attempts < 3 else { throw SolverError.message("Three captures were not clear enough. " + reason) }
    guide = reason; say(reason)
    try await Task.sleep(for: .seconds(2))
    try Task.checkCancellation()
    guard runID == id else { return }
    do { try await camera.resumePreview() }
    catch {
      try Task.checkCancellation()
      guard runID == id else { return }
      try await camera.start()
    }
    gate.reset(); progress = 0; phase = .seeking; guide = reason
  }

  private func fail(_ message: String) {
    runID = UUID(); worker?.cancel(); analysisTask?.cancel(); analysisTask = nil
    camera.stop(); gate.reset(); restoreIdleTimer()
    phase = .failed; guide = message; progress = 0
    say("Scan stopped. " + message)
  }
  private func restoreIdleTimer() {
    if let previousIdleTimer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
    previousIdleTimer = nil
  }
  private func speakCue(_ cue: ScanCue, at time: TimeInterval) {
    guard voiceGuidance, speechGate.shouldSpeak(cue, at: time) else { return }
    speak(cue.message)
  }
  private func say(_ message: String) {
    guard voiceGuidance else { return }
    speechGate.noteAnnouncement(at: ProcessInfo.processInfo.systemUptime)
    speak(message)
  }
  private func speak(_ message: String) {
    if speech.isSpeaking { speech.stopSpeaking(at: .word) }
    let utterance = AVSpeechUtterance(string: message)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
    speech.speak(utterance)
  }
}
