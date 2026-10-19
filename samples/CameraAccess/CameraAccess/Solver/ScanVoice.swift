import Foundation
import AVFoundation
import Speech

enum ScanCommand: Equatable {
  case finish, next, retakeLast, cancel
  static func parse(_ text: String) -> Self? {
    let words = text.lowercased().split { !$0.isLetter }.joined(separator: " ")
    if words.hasSuffix("finish scanning") || words.hasSuffix("done scanning") { return .finish }
    if words.hasSuffix("next page") { return .next }
    if words.hasSuffix("retake last page") { return .retakeLast }
    if words.hasSuffix("cancel scanning") { return .cancel }
    return nil
  }
}
@MainActor
protocol ScanSpeaking: AnyObject {
  var onCommand: ((ScanCommand) -> Void)? { get set }
  var onStatus: ((String) -> Void)? { get set }
  func startCommands() async
  func stopCommands()
  func say(_ message: String, volume: Float)
  func stopSpeaking()
}

/// The real-time audio callback touches only this locked feed, never UI state.
private final class RecognitionFeed: @unchecked Sendable {
  private let lock = NSLock()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var muted = false
  func replace(_ value: SFSpeechAudioBufferRecognitionRequest?) {
    lock.lock(); let old = request; request = value; lock.unlock(); old?.endAudio()
  }
  func mute(_ value: Bool) { lock.lock(); muted = value; lock.unlock() }
  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock(); defer { lock.unlock() }
    if !muted { request?.append(buffer) }
  }
}

@MainActor
final class ScanVoice: NSObject, ScanSpeaking, AVSpeechSynthesizerDelegate {
  static let quietVolume: Float = 0.05
  var onCommand: ((ScanCommand) -> Void)?
  var onStatus: ((String) -> Void)?
  private let speech = AVSpeechSynthesizer()
  private var engine: AVAudioEngine?
  private var tappedInput: AVAudioInputNode?
  private let feed = RecognitionFeed()
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private let speechAuthorization: @MainActor () async -> SFSpeechRecognizerAuthorizationStatus
  private let microphoneAuthorization: @MainActor () async -> Bool
  private var recognition: SFSpeechRecognitionTask?
  private var restart: Task<Void, Never>?
  private var unmute: Task<Void, Never>?
  private var active = false
  private var listening = false
  private var startupID = UUID()
  private var audioObservers: [NSObjectProtocol] = []
  private var generation = UUID()
  private var speechGeneration = UUID()
  private var lastCommand = -Double.infinity
  private var failures = 0
  init(speechAuthorization: @escaping @MainActor () async -> SFSpeechRecognizerAuthorizationStatus = ScanVoice.authorizeSpeech,
       microphoneAuthorization: @escaping @MainActor () async -> Bool = ScanVoice.authorizeMicrophone) {
    self.speechAuthorization = speechAuthorization; self.microphoneAuthorization = microphoneAuthorization
    super.init(); speech.delegate = self
  }

  private static func authorizeSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
    }
  }
  private static func authorizeMicrophone() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { @Sendable allowed in continuation.resume(returning: allowed) }
    }
  }

  func startCommands() async {
    guard !active, !Task.isCancelled else { return }
    active = true; startupID = UUID(); let id = startupID
    let granted = await speechAuthorization()
    guard continueStartup(id) else { return }
    guard granted == .authorized else {
      stopCommands(); onStatus?("Voice commands unavailable. Allow Speech Recognition in iPhone Settings, or use Finish scanning."); return
    }
    let microphone = await microphoneAuthorization()
    guard continueStartup(id) else { return }
    guard microphone else {
      stopCommands(); onStatus?("Voice commands unavailable. Allow Microphone in iPhone Settings, or use Finish scanning."); return
    }
    guard let recognizer, recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
      stopCommands(); onStatus?("On-device English speech is unavailable. Use Finish scanning on screen."); return
    }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
      try session.setActive(true)
      guard session.isInputAvailable, !session.currentRoute.inputs.isEmpty else { throw SolverError.message("No microphone input.") }
      // An engine created before Bluetooth activation can retain the previous route's format.
      let engine = AVAudioEngine(); self.engine = engine
      let input = engine.inputNode, format = input.outputFormat(forBus: 0)
      let hardware = input.inputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0,
            hardware.sampleRate > 0, hardware.channelCount > 0 else { throw SolverError.message("Microphone is not ready.") }
      input.installTap(onBus: 0, bufferSize: 1024, format: nil, block: makeAudioTap())
      tappedInput = input; try engine.start()
      listening = true; failures = 0; lastCommand = -Double.infinity
      observeAudioChanges(engine: engine, id: id); startRecognition()
      onStatus?("Listening on device: “next page”, “retake last page”, “finish scanning”.")
    } catch {
      stopCommands(); onStatus?("Voice commands could not start. Use Finish scanning. \(error.localizedDescription)")
    }
  }
  private func continueStartup(_ id: UUID) -> Bool {
    guard active, startupID == id else { return false }
    if Task.isCancelled { stopCommands(); return false }
    return true
  }

  // Explicitly Sendable is essential: an unannotated AVAudio callback created in
  // this MainActor class otherwise traps on the audio thread in Swift 6.
  func makeAudioTap() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
    let feed = self.feed
    return { @Sendable buffer, _ in feed.append(buffer) }
  }

  private func observeAudioChanges(engine: AVAudioEngine, id: UUID) {
    let center = NotificationCenter.default
    let notices: [(Notification.Name, AnyObject?)] = [
      (.AVAudioEngineConfigurationChange, engine),
      (AVAudioSession.interruptionNotification, AVAudioSession.sharedInstance()),
      (AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.sharedInstance())
    ]
    for (name, object) in notices {
      audioObservers.append(center.addObserver(forName: name, object: object, queue: nil) { @Sendable [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, self.active, self.startupID == id else { return }
          self.stopCommands()
          self.onStatus?("Microphone connection changed. Scanning continues. Use Finish scanning, or pause and resume to restore voice commands.")
        }
      })
    }
  }

  func stopCommands() {
    active = false; listening = false; startupID = UUID(); generation = UUID(); restart?.cancel(); restart = nil
    for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
    audioObservers.removeAll()
    feed.replace(nil); recognition?.cancel(); recognition = nil
    engine?.stop()
    tappedInput?.removeTap(onBus: 0); tappedInput = nil; engine = nil
  }
  private func startRecognition() {
    guard active, listening, let recognizer else { return }
    generation = UUID()
    recognition?.cancel(); restart?.cancel()
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
    request.taskHint = .confirmation
    request.contextualStrings = ["finish scanning", "next page", "retake last page", "cancel scanning"]
    feed.replace(request)
    recognition = recognizer.recognitionTask(with: request, resultHandler: makeRecognitionHandler())
    scheduleRestart(after: 45)
  }
  func makeRecognitionHandler() -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
    let id = generation
    return { @Sendable [weak self] result, error in
      let text = result?.bestTranscription.formattedString, final = result?.isFinal ?? false
      let failed = error != nil
      Task { @MainActor [weak self] in
        guard let self, self.active, self.listening, self.generation == id else { return }
        let time = ProcessInfo.processInfo.systemUptime
        if !self.speech.isSpeaking, time - self.lastCommand > 2, let text, let command = ScanCommand.parse(text) {
          self.lastCommand = time; self.onCommand?(command)
          if self.active { self.startRecognition() }
          return
        }
        if final || failed {
          self.failures = failed ? self.failures + 1 : 0
          if self.failures >= 3 {
            self.stopCommands(); self.onStatus?("Voice recognition stopped. Use Finish scanning on screen.")
          } else { self.scheduleRestart(after: 1) }
        }
      }
    }
  }
  private func scheduleRestart(after seconds: Double) {
    restart?.cancel()
    restart = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(seconds)); try Task.checkCancellation() }
      catch { return }
      self?.startRecognition()
    }
  }
  func say(_ message: String, volume: Float) {
    unmute?.cancel(); feed.mute(true); speechGeneration = UUID()
    speech.stopSpeaking(at: .immediate)
    let utterance = AVSpeechUtterance(string: message)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
    utterance.volume = max(Self.quietVolume, min(1, volume))
    speech.speak(utterance)
  }
  func stopSpeaking() {
    speechGeneration = UUID(); unmute?.cancel(); speech.stopSpeaking(at: .immediate); feed.mute(false)
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor [weak self] in self?.resumeAfterSpeech() }
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor [weak self] in self?.resumeAfterSpeech() }
  }
  private func resumeAfterSpeech() {
    let id = speechGeneration; unmute?.cancel()
    unmute = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(900)); try Task.checkCancellation() } catch { return }
      guard let self, self.speechGeneration == id, !self.speech.isSpeaking else { return }
      // Reset the transcript so audio from before a cue cannot combine with a later command.
      if self.active { self.startRecognition() }
      self.feed.mute(false)
    }
  }
}
