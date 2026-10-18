import Foundation
import MWDATCore
import MWDATCamera
import UIKit

@MainActor
protocol ScanCamera: AnyObject {
  var onFrame: ((CGImage) -> Void)? { get set }
  var onProblem: ((String) -> Void)? { get set }
  var onProgress: ((Double) -> Void)? { get set }
  var onNotice: ((String) -> Void)? { get set }
  func start() async throws
  func resumePreview() async throws
  func capture() async throws -> Data
  func stop()
}

@MainActor
final class AutoScanCamera: ScanCamera {
  var onFrame: ((CGImage) -> Void)?
  var onProblem: ((String) -> Void)?
  var onProgress: ((Double) -> Void)?
  var onNotice: ((String) -> Void)?
  private let wearables: WearablesInterface
  private let selector: AutoDeviceSelector
  private var session: DeviceSession?
  private var camera: MWDATCamera.Camera?
  private var sessionTokens = ListenerTokenBag()
  private var streamTokens = ListenerTokenBag()
  private var photoTokens = ListenerTokenBag()
  private var generation = UUID()
  private var sessionFailure: String?
  private var streamFailure: String?
  private var photoFailure: PhotoError?
  private var streamState: StreamState = .stopped
  private var photoState: PhotoState = .stopped
  private var photoData: Data?
  private var streamPhotoData: Data?
  private var capturing = false
  private var fallback = false

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
        self.sessionFailure = error.localizedDescription
        self.onProblem?(error.localizedDescription)
      }
    }.store(in: sessionTokens)
    newSession.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        guard let self, self.generation == id else { return }
        if state == .stopped { self.onProblem?("Glasses disconnected. Put them on and start again.") }
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
        if state == .paused { self.onNotice?("Preview paused. Tap your glasses to resume.") }
      }
    }.store(in: streamTokens)
    newCamera.stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        guard let self, self.generation == id else { return }
        self.streamFailure = error.localizedDescription
        if !self.capturing { self.onProblem?(error.localizedDescription) }
      }
    }.store(in: streamTokens)
    newCamera.stream.videoFramePublisher.listen { [weak self] frame in
      // SDK decoding is outside MainActor; CGImage is immutable and transferable.
      guard let image = frame.makeUIImage()?.cgImage else { return }
      Task { @MainActor in
        guard let self, self.generation == id, !self.capturing else { return }
        self.onFrame?(image)
      }
    }.store(in: streamTokens)
    newCamera.stream.photoDataPublisher.listen { [weak self] photo in
      Task { @MainActor in
        guard let self, self.generation == id, self.capturing else { return }
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
        guard let self, self.generation == id, self.capturing else { return }
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
        guard let self, self.generation == id, self.capturing else { return }
        self.onProgress?(progress.fraction)
      }
    }.store(in: photoTokens)
    try await resumePreview()
  }

  func resumePreview() async throws {
    guard let camera, session?.state == .started else { throw SolverError.message("Glasses session ended. Start again.") }
    capturing = false; streamFailure = nil
    camera.stream.start()
    try await wait(seconds: 20, message: "Camera preview timed out.") { self.streamState == .streaming }
  }

  func capture() async throws -> Data {
    guard let camera, streamState == .streaming, !capturing else { throw SolverError.message("Wait for the camera preview to resume.") }
    capturing = true; photoData = nil; streamPhotoData = nil; photoFailure = nil
    defer { capturing = false }
    if !fallback {
      camera.stream.stop()
      try await wait(seconds: 10, message: "Could not pause preview for a full-resolution photo.") { self.streamState == .stopped }
      camera.photo.start()
      do {
        try await waitPhoto(seconds: 15) { self.photoState == .started }
        camera.photo.capturePhoto(resolution: .full, quality: .high)
        try await waitPhoto(seconds: 60) { self.photoData != nil }
        let data = photoData!
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
    guard camera.stream.capturePhoto(format: .jpeg) else { throw SolverError.message("The glasses could not capture a photo.") }
    try await wait(seconds: 30, message: "Photo transfer timed out.") { self.streamPhotoData != nil }
    let data = streamPhotoData!
    camera.stream.stop()
    try await wait(seconds: 10, message: "Camera preview could not stop.") { self.streamState == .stopped }
    return data
  }

  func stop() {
    generation = UUID() // invalidate callbacks before stopping SDK objects
    camera?.photo.stop(); camera?.stop(); session?.stop()
    photoTokens.clear(); streamTokens.clear(); sessionTokens.clear()
    camera = nil; session = nil
    photoState = .stopped; streamState = .stopped
    sessionFailure = nil; streamFailure = nil; photoFailure = nil
    photoData = nil; streamPhotoData = nil; capturing = false; fallback = false
  }

  private func wait(seconds: Double, message: String, until predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !predicate() {
      try Task.checkCancellation()
      if let failure = sessionFailure ?? streamFailure { throw SolverError.message(failure) }
      guard ContinuousClock.now < deadline else { throw SolverError.message(message) }
      try await Task.sleep(for: .milliseconds(80))
    }
    try Task.checkCancellation()
  }
  private func waitPhoto(seconds: Double, until predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !predicate() {
      try Task.checkCancellation()
      if let photoFailure { throw photoFailure }
      if let sessionFailure { throw SolverError.message(sessionFailure) }
      guard ContinuousClock.now < deadline else { throw SolverError.message("Full-resolution photo timed out. Keep the glasses connected and try again.") }
      try await Task.sleep(for: .milliseconds(80))
    }
    try Task.checkCancellation()
  }
}
