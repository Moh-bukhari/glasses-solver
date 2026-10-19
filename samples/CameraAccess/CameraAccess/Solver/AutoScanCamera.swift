import Foundation
import MWDATCore
import MWDATCamera
import MWDATInputs
import UIKit

@MainActor
protocol ScanCamera: AnyObject {
  var onFrame: ((CGImage) -> Void)? { get set }
  var onProblem: ((String) -> Void)? { get set }
  var onProgress: ((Double) -> Void)? { get set }
  var onNotice: ((String) -> Void)? { get set }
  /// The still exists on the glasses; the wearer may move while it transfers.
  var onShutter: (() -> Void)? { get set }
  /// Clicks on the glasses (experimental Meta Inputs), already mapped to scan commands.
  var onCommand: ((ScanCommand) -> Void)? { get set }
  var glassesButtons: Bool { get set }
  func start() async throws
  func resumePreview() async throws
  func capture() async throws -> Data
  func stop()
}

extension ScanCommand {
  /// A single touchpad tap (pause/resume) and tap-and-hold (stop) are reserved by the glasses and never arrive.
  static func glasses(_ event: InputEvent) -> ScanCommand? {
    switch event {
    case .select(let source, _): return source == .captouch ? .finish : nil // touchpad double-tap
    case .capture(let press, _, _):
      switch press {
      case .shortPress: return .next
      case .doublePress: return .finish
      case .hold: return .retakeLast
      }
    case .button: return .finish
    default: return nil
    }
  }
}

@MainActor
final class AutoScanCamera: ScanCamera {
  var onFrame: ((CGImage) -> Void)?
  var onProblem: ((String) -> Void)?
  var onProgress: ((Double) -> Void)?
  var onNotice: ((String) -> Void)?
  var onShutter: (() -> Void)?
  var onCommand: ((ScanCommand) -> Void)?
  var glassesButtons = true
  private let wearables: WearablesInterface
  private let selector: AutoDeviceSelector
  private var session: DeviceSession?
  private var camera: MWDATCamera.Camera?
  private var sessionTokens = ListenerTokenBag()
  private var streamTokens = ListenerTokenBag()
  private var photoTokens = ListenerTokenBag()
  private var inputsTokens = ListenerTokenBag()
  private var generation = UUID()
  private var sessionFailure: String?
  private var streamFailure: String?
  private var photoFailure: PhotoError?
  private var streamState: StreamState = .stopped
  private var photoState: PhotoState = .stopped
  private var photoData: Data?
  private var streamPhotoData: Data?
  private var capturing = false
  private var photoRequested = false
  private var streamPhotoRequested = false
  private var shutterAnnounced = false
  private var fallback = false
  private var pausedNoticeShown = false
  private var inputs: Inputs?
  private var inputsTask: Task<Void, Never>?
  private var inputsWasActive = false
  private var inputsStale = false
  private var inputsUnavailable = false
  private var inputsFailures = 0
  private var nextInputsAttach = ContinuousClock.now
  private var restartingPreview = false
  private var lastCommand: (command: ScanCommand, at: ContinuousClock.Instant)?
  /// Integration-test hook: glasses buttons are attached and delivering.
  var inputsActive: Bool { inputs?.state == .active }

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    selector = AutoDeviceSelector(wearables: wearables)
  }

  func start() async throws {
    stop()
    // Permission lookup needs a connected device, including when a device was just paired.
    try await wait(seconds: 12, message: "Put on your connected glasses and try again.") {
      self.selector.activeDevice != nil
    }
    // Request permission before starting a device session: Meta AI temporarily backgrounds us.
    if try await wearables.checkPermissionStatus(.camera) != .granted {
      guard try await wearables.requestPermission(.camera) == .granted else {
        throw SolverError.message("Allow camera access in Meta AI, then start again.")
      }
    }
    try Task.checkCancellation()
    let id = generation
    let newSession = try wearables.createSession(deviceSelector: selector)
    session = newSession
    newSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        guard let self, self.generation == id else { return }
        // A compatibility warning is explicitly non-blocking; never end the scan for it.
        if case .dwaOutOfStuRange = error { self.onNotice?("Meta AI suggests a glasses update. Scanning continues."); return }
        self.sessionFailure = error.localizedDescription
        self.onProblem?(error.localizedDescription)
      }
    }.store(in: sessionTokens)
    newSession.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        guard let self, self.generation == id else { return }
        switch state {
        case .stopped:
          // Touch-and-hold on the touchpad stops the session while the glasses stay connected.
          self.onProblem?(self.selector.activeDevice != nil
            ? "Scanning was stopped from the glasses. Tap Continue scanning on your phone."
            : "Glasses disconnected. Put them on and start again.")
        case .paused: self.notePause(true)
        case .started: self.notePause(self.streamState == .paused)
        default: break // starting/stopping are transitions, not a resume
        }
      }
    }.store(in: sessionTokens)
    try newSession.start()
    try await wait(seconds: 20, message: "Glasses connection timed out. Start again.") { newSession.state == .started }
    guard let newCamera = try newSession.addCamera(config: StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 7)) else {
      throw SolverError.message("Could not start the glasses camera.")
    }
    camera = newCamera
    newCamera.stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        guard let self, self.generation == id else { return }
        self.streamState = state
        if state == .paused { self.notePause(true) }
        else if state == .streaming { self.notePause(self.session?.state == .paused) }
      }
    }.store(in: streamTokens)
    newCamera.stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        guard let self, self.generation == id else { return }
        self.streamFailure = error.localizedDescription
        // During capture or a preview restart the error surfaces from the wait, so the model can reconnect.
        if !self.capturing && !self.restartingPreview { self.onProblem?(error.localizedDescription) }
      }
    }.store(in: streamTokens)
    newCamera.stream.videoFramePublisher.listen { [weak self] frame in
      // SDK decoding is outside MainActor; CGImage is immutable and transferable.
      guard let image = frame.makeUIImage()?.cgImage else { return }
      Task { @MainActor in
        guard let self, self.generation == id, !self.capturing else { return }
        // Inputs attach reliably only once the link delivers frames, and photo capture can deactivate them.
        self.attachInputsIfNeeded(id: id)
        self.onFrame?(image)
      }
    }.store(in: streamTokens)
    newCamera.stream.photoDataPublisher.listen { [weak self] photo in
      Task { @MainActor in
        guard let self, self.generation == id, self.capturing, self.streamPhotoRequested else { return }
        self.streamPhotoData = photo.data
      }
    }.store(in: streamTokens)
    newCamera.photo.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        guard let self, self.generation == id else { return }; self.photoState = state
      }
    }.store(in: photoTokens)
    newCamera.photo.photoDataPublisher.listen { [weak self] photo in
      Task { @MainActor in
        // Photos the wearer takes with the shutter button arrive here too; keep only the one we asked for.
        guard let self, self.generation == id, self.capturing, self.photoRequested else { return }
        self.photoData = photo.imageData
      }
    }.store(in: photoTokens)
    newCamera.photo.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        guard let self, self.generation == id else { return }; self.photoFailure = error
      }
    }.store(in: photoTokens)
    newCamera.photo.transferProgressPublisher.listen { [weak self] progress in
      Task { @MainActor in
        guard let self, self.generation == id, self.capturing, self.photoRequested else { return }
        self.announceShutter()
        self.onProgress?(progress.fraction)
      }
    }.store(in: photoTokens)
    try await resumePreview()
  }

  func resumePreview() async throws {
    guard let camera, let session, session.state != .stopped else { throw SolverError.message("Glasses session ended. Start again.") }
    capturing = false; streamFailure = nil
    restartingPreview = true; defer { restartingPreview = false }
    // Never restart the stream while the wearer has paused the session; resume when they tap again.
    try await wait(seconds: 10, message: "Glasses session ended. Start again.") { session.state == .started }
    // Stream and Photo cannot share the camera: a failed still may leave Photo running.
    if photoState != .stopped {
      camera.photo.stop()
      try? await wait(seconds: 5, message: "Photo capture did not stop.") { self.photoState == .stopped }
      streamFailure = nil
    }
    camera.stream.start()
    try await wait(seconds: 20, message: "Camera preview timed out.") { self.streamState == .streaming }
  }

  func capture() async throws -> Data {
    guard let camera, streamState == .streaming, !capturing else { throw SolverError.message("Wait for the camera preview to resume.") }
    capturing = true; photoData = nil; streamPhotoData = nil; photoFailure = nil
    photoRequested = false; streamPhotoRequested = false; shutterAnnounced = false
    defer { capturing = false; photoRequested = false; streamPhotoRequested = false }
    if !fallback {
      camera.stream.stop()
      try await wait(seconds: 10, message: "Could not pause preview for a full-resolution photo.") { self.streamState == .stopped }
      camera.photo.start()
      do {
        try await waitPhoto(seconds: 15) { self.photoState == .started }
        camera.photo.capturePhoto(resolution: .full, quality: .high)
        photoRequested = true
        try await waitPhoto(seconds: 60) { self.photoData != nil }
        let data = photoData!
        announceShutter()
        camera.photo.stop()
        try await wait(seconds: 10, message: "Photo capture did not finish stopping.") { self.photoState == .stopped }
        return data
      } catch {
        camera.photo.stop()
        try Task.checkCancellation()
        // Unsupported experimental Photo is the only automatic fallback. Other failures stop safely.
        switch photoFailure {
        case .serviceUnavailable?, .sessionSetupFailed?:
          try await wait(seconds: 10, message: "Full-resolution capture could not stop.") { self.photoState == .stopped }
          fallback = true
          onNotice?("Full-resolution capture unavailable. Checking a standard still instead.")
          streamFailure = nil
          camera.stream.start()
          try await wait(seconds: 20, message: "Standard camera preview could not restart.") { self.streamState == .streaming }
        default: throw error
        }
      }
    }
    streamPhotoRequested = true
    guard camera.stream.capturePhoto(format: .jpeg) else { throw SolverError.message("The glasses could not capture a photo.") }
    try await wait(seconds: 30, message: "Photo transfer timed out.") { self.streamPhotoData != nil }
    let data = streamPhotoData!
    announceShutter()
    camera.stream.stop()
    try await wait(seconds: 10, message: "Camera preview could not stop.") { self.streamState == .stopped }
    return data
  }

  func stop() {
    generation = UUID() // invalidate callbacks before stopping SDK objects
    detachInputs()
    camera?.photo.stop(); camera?.stop(); session?.stop()
    photoTokens.clear(); streamTokens.clear(); sessionTokens.clear()
    camera = nil; session = nil
    photoState = .stopped; streamState = .stopped
    sessionFailure = nil; streamFailure = nil; photoFailure = nil
    photoData = nil; streamPhotoData = nil; capturing = false; fallback = false
    photoRequested = false; streamPhotoRequested = false; pausedNoticeShown = false
    inputsUnavailable = false; inputsFailures = 0; nextInputsAttach = .now; lastCommand = nil; restartingPreview = false
  }

  private func announceShutter() {
    guard !shutterAnnounced else { return }
    shutterAnnounced = true; onShutter?()
  }

  private func notePause(_ paused: Bool) {
    if paused, !pausedNoticeShown {
      pausedNoticeShown = true
      onNotice?("Paused from the glasses. Tap the side of your glasses once to continue.")
    } else if !paused, pausedNoticeShown {
      pausedNoticeShown = false
      onNotice?("Resumed. Keep scanning.")
    }
  }

  // MARK: Glasses buttons (experimental Meta Inputs)

  private func attachInputsIfNeeded(id: UUID) {
    guard glassesButtons, !inputsUnavailable, !capturing, generation == id, ContinuousClock.now >= nextInputsAttach,
      let session, session.state == .started else { return }
    if inputs != nil {
      guard inputsStale else { return }
      detachInputs()
    }
    let attached: Inputs?
    do {
      attached = try session.addInputs(configuration: InputsConfiguration(sources: [.captouch, .captureButton, .actionButton], consumeBack: true))
    } catch { inputsFailed(); return }
    guard let attached else { inputsFailed(); return }
    inputs = attached; inputsStale = false; inputsWasActive = false
    let events = attached.events
    inputsTask = Task { [weak self] in
      for await event in events {
        guard let self, self.generation == id else { return }
        self.receive(event)
      }
    }
    attached.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        guard let self, self.generation == id, self.inputs === attached else { return }
        if state == .active { self.inputsWasActive = true; self.inputsFailures = 0 }
        // A full-resolution photo or a doff deactivates Inputs; re-attach on the next preview frame.
        else if state == .inactive, self.inputsWasActive { self.inputsStale = true }
      }
    }.store(in: inputsTokens)
    attached.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        guard let self, self.generation == id, self.inputs === attached else { return }
        if error == .permissionDenied || error == .capabilityUnavailable {
          self.inputsUnavailable = true
          self.onNotice?("Glasses buttons are not enabled for this app. Use a thumbs-up or the screen to finish.")
        } else { self.inputsFailed() }
      }
    }.store(in: inputsTokens)
  }

  /// Retry with backoff; after repeated failures stop trying for this scan and say so once.
  private func inputsFailed() {
    inputsFailures += 1; inputsStale = true
    if inputsFailures >= 3 {
      inputsUnavailable = true
      onNotice?("Glasses buttons are unavailable. Use a thumbs-up or the screen to finish.")
    } else { nextInputsAttach = .now + .seconds(2 * inputsFailures) }
  }

  private func detachInputs() {
    inputsTask?.cancel(); inputsTask = nil
    inputsTokens.clear(); inputsTokens = ListenerTokenBag()
    if inputs != nil, session?.state == .started { try? session?.removeInputs() }
    inputs = nil; inputsStale = false; inputsWasActive = false
  }

  private func receive(_ event: InputEvent) {
    guard let command = ScanCommand.glasses(event) else { return }
    let now = ContinuousClock.now
    if let last = lastCommand, last.command == command, now - last.at < .milliseconds(500) { return }
    lastCommand = (command, now)
    onCommand?(command)
  }

  // MARK: Bounded, pause-aware state waits

  private var isPaused: Bool { session?.state == .paused || streamState == .paused }

  /// Time spent paused from the glasses (up to two minutes) does not count against a step's limit.
  private func wait(seconds: Double, message: String, until predicate: () -> Bool) async throws {
    var remaining = Duration.seconds(seconds), pauseAllowance = Duration.seconds(120)
    var last = ContinuousClock.now
    while !predicate() {
      try Task.checkCancellation()
      if let failure = sessionFailure ?? streamFailure { throw SolverError.message(failure) }
      let now = ContinuousClock.now
      if isPaused && pauseAllowance > .zero { pauseAllowance -= now - last } else { remaining -= now - last }
      last = now
      guard remaining > .zero else { throw SolverError.message(message) }
      try await Task.sleep(for: .milliseconds(30))
    }
    try Task.checkCancellation()
  }
  private func waitPhoto(seconds: Double, until predicate: () -> Bool) async throws {
    var remaining = Duration.seconds(seconds), pauseAllowance = Duration.seconds(120)
    var last = ContinuousClock.now
    while !predicate() {
      try Task.checkCancellation()
      if let photoFailure { throw photoFailure }
      if let sessionFailure { throw SolverError.message(sessionFailure) }
      let now = ContinuousClock.now
      if isPaused && pauseAllowance > .zero { pauseAllowance -= now - last } else { remaining -= now - last }
      last = now
      guard remaining > .zero else { throw SolverError.message("Full-resolution photo timed out. Keep the glasses connected and try again.") }
      try await Task.sleep(for: .milliseconds(30))
    }
    try Task.checkCancellation()
  }
}
