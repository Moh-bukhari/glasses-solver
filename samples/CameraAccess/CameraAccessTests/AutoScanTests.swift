@testable import CameraAccess
import XCTest
import UIKit
import PDFKit
import CoreImage
import AVFoundation
import Speech
import MWDATCore
import MWDATMockDevice

@MainActor
final class AutoScanTests: XCTestCase {
  func goodSample(shift: Double = 0) -> PageSample {
    PageSample(contentBounds: CGRect(x: 0.2 + shift, y: 0.2, width: 0.6, height: 0.6),
      luminance: 0.8, contrast: 0.2, sharpness: 0.02, fingerprint: Array(repeating: 0.05, count: 256))
  }

  func testStablePageTriggersOnceAndNeverRetriggers() {
    var gate = StabilityGate()
    for n in 0...4 { XCTAssertLessThan(gate.observe(goodSample(), at: Double(n) * 0.3), 1) }
    XCTAssertEqual(gate.observe(goodSample(), at: 1.5), 1)
    XCTAssertTrue(gate.latched)
    XCTAssertEqual(gate.observe(goodSample(shift: 0.1), at: 2), 1)
  }
  func testMovementBadFrameAndLongGapsRestartTheHold() {
    var gate = StabilityGate()
    _ = gate.observe(goodSample(), at: 0)
    _ = gate.observe(goodSample(), at: 0.4)
    XCTAssertEqual(gate.observe(goodSample(shift: 0.08), at: 0.8), 0)
    XCTAssertEqual(gate.observe(PageSample(issue: "blur"), at: 1.1), 0)
    XCTAssertEqual(gate.observe(goodSample(), at: 1.4), 0)
    XCTAssertEqual(gate.observe(goodSample(), at: 3.4), 0)
    XCTAssertFalse(gate.latched)
  }
  func testSlowCumulativeDriftCannotTrigger() {
    var gate = StabilityGate()
    for n in 0..<20 { XCTAssertLessThan(gate.observe(goodSample(shift: Double(n) * 0.02), at: Double(n) * 0.3), 1) }
  }
  func testDirectionalCuesFollowWritingInWearerCoordinates() {
    func cue(_ x: Double, _ y: Double, _ w: Double, _ h: Double, line: Double = 0.025) -> ScanCue {
      ContentFraming.cue(bounds: CGRect(x: x, y: y, width: w, height: h), lineHeight: line, imageHeight: 1280)
    }
    XCTAssertEqual(cue(0.01, 0.42, 0.25, 0.16), .left)
    XCTAssertEqual(cue(0.78, 0.42, 0.20, 0.16), .right)
    XCTAssertEqual(cue(0.3, 0.84, 0.4, 0.1), .tiltUp)
    XCTAssertEqual(cue(0.3, 0.04, 0.4, 0.1), .tiltDown)
    XCTAssertEqual(cue(0.44, 0.44, 0.12, 0.12), .closer)
    XCTAssertEqual(cue(0.2, 0.4, 0.6, 0.1, line: 0.004), .closer)
    XCTAssertEqual(cue(0.005, 0.2, 0.99, 0.6), .farther)
    XCTAssertEqual(cue(0.08, 0.17, 0.8, 0.66), .hold)
    XCTAssertEqual(ContentFraming.cue(bounds: nil, lineHeight: 0, imageHeight: 1280), .findProblem)
  }
  func testBackgroundLabelsDoNotPullTargetAwayFromCenter() {
    let target = CGRect(x: 0.25, y: 0.46, width: 0.5, height: 0.06)
    let background = CGRect(x: 0.82, y: 0.90, width: 0.12, height: 0.04)
    XCTAssertEqual(ContentFraming.primaryGroup([background, target]), [target])
  }
  func testFramingAdviceAndMissingTextOutlineCannotBlockAStablePhoto() {
    for cue in [ScanCue.left, .closer, .farther, .findProblem] {
      var gate = StabilityGate(), sample = goodSample()
      sample.contentBounds = nil; sample.cue = cue
      XCTAssertTrue(sample.acceptable)
      for n in 0..<10 { XCTAssertLessThan(gate.observe(sample, at: Double(n) * 0.3), 1) }
      XCTAssertEqual(gate.observe(sample, at: 3), 1)
    }
  }
  func testTextDetectionJitterIsToleratedButImageMotionResetsHold() {
    var gate = StabilityGate()
    for n in 0...5 {
      var sample = goodSample()
      if n % 2 == 0 { sample.contentBounds = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.2) }
      let value = gate.observe(sample, at: Double(n) * 0.3)
      if n == 5 { XCTAssertEqual(value, 1) }
    }
    gate.reset()
    var sample = goodSample(); sample.contentBounds = nil
    _ = gate.observe(sample, at: 0)
    sample.fingerprint = Array(repeating: 0.3, count: 256)
    XCTAssertEqual(gate.observe(sample, at: 0.4), 0)
    XCTAssertFalse(gate.latched)
  }
  func testVoiceDirectionsDebounceRepeatAndYieldPromptlyToHold() {
    var voice = GuidanceSpeechGate()
    XCTAssertFalse(voice.shouldSpeak(.left, at: 0))
    XCTAssertTrue(voice.shouldSpeak(.left, at: 0.35))
    XCTAssertFalse(voice.shouldSpeak(.right, at: 0.5))
    XCTAssertFalse(voice.shouldSpeak(.right, at: 0.85))
    XCTAssertTrue(voice.shouldSpeak(.hold, at: 1.2))
    XCTAssertFalse(voice.shouldSpeak(.hold, at: 1.3))
    XCTAssertTrue(voice.shouldSpeak(.hold, at: 8.3))
    voice.reset()
    voice.noteAnnouncement(at: 0)
    XCTAssertFalse(voice.shouldSpeak(.right, at: 0.1))
    XCTAssertTrue(voice.shouldSpeak(.right, at: 0.9), "The ready announcement must not suppress the first direction.")
    XCTAssertFalse(voice.shouldSpeak(.right, at: 2))
    XCTAssertTrue(voice.shouldSpeak(.right, at: 8))
  }
  func testBorderlessProblemAnd720PixelPhotoPassWithoutCleanup() async throws {
    let analyzer = PageAnalyzer(), image = problemImage()
    let preview = try await analyzer.analyze(image.cgImage!, still: false)
    XCTAssertTrue(preview.acceptable, preview.issue ?? "")
    let prepared = try await analyzer.prepare(image.jpegData(compressionQuality: 0.95)!)
    XCTAssertTrue(prepared.sample.acceptable, prepared.sample.issue ?? "")
    XCTAssertEqual(prepared.width, 720)
    XCTAssertEqual(prepared.height, 1280)
    let decoded = try XCTUnwrap(UIImage(data: prepared.jpeg)?.cgImage)
    XCTAssertEqual(decoded.width, 720)
    XCTAssertEqual(decoded.height, 1280)
  }
  func testClutteredBackgroundAndPartialTiltedPaperAreAllowed() async throws {
    let analyzer = PageAnalyzer()
    let result = try await analyzer.analyze(problemImage(cluttered: true).cgImage!, still: true)
    XCTAssertTrue(result.acceptable, "\(result.issue ?? "") sharpness=\(result.sharpness)")
  }
  func testOffCenterStillCanBeSentDespitePositioningAdvice() async throws {
    let analyzer = PageAnalyzer()
    let result = try await analyzer.prepare(problemImage(offCenter: true).jpegData(compressionQuality: 0.95)!)
    XCTAssertTrue(result.sample.acceptable, result.sample.issue ?? "")
    XCTAssertNotNil(result.sample.contentBounds, "Real text detection must supply directions, not only the fallback.")
    XCTAssertEqual(result.sample.cue, .tiltUp)
  }
  func testClearPagePassesAndBlurAndBlankFail() async throws {
    let analyzer = PageAnalyzer()
    let clear = paperImage()
    let good = try await analyzer.analyze(clear.cgImage!, still: true)
    XCTAssertTrue(good.acceptable, "\(good.issue ?? "") sharpness=\(good.sharpness)")
    let blank = paperImage(blank: true)
    let bad = try await analyzer.analyze(blank.cgImage!, still: true)
    XCTAssertFalse(bad.acceptable, "Blank sheet passed: bounds=\(String(describing: bad.contentBounds)) contrast=\(bad.contrast) sharpness=\(bad.sharpness)")
    let ci = CIImage(cgImage: clear.cgImage!).applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 18.0])
    let blurred = CIContext().createCGImage(ci, from: CGRect(x: 0, y: 0, width: 1200, height: 1600))!
    let blur = try await analyzer.analyze(blurred, still: true)
    XCTAssertFalse(blur.acceptable, "Blur unexpectedly passed: \(blur.sharpness)")
  }
  func testPDFContainsLastStepAcrossPagesAndSourcePhoto() throws {
    let problem = SolvedProblem(problem: "Solve 2x + 3 = 11", steps: (1...180).map { "Step \($0): subtract three and divide by two. Check the equation carefully. This line must survive pagination." }, answer: "FINAL SENTINEL x = 4", check: "2 × 4 + 3 = 11")
    let page = SolvedPage(readable: true, retakeReason: "", title: "Pagination test", problems: [problem])
    let data = try SolutionPDF.render(page: page, source: paperImage())
    let pdf = try XCTUnwrap(PDFDocument(data: data))
    XCTAssertGreaterThan(pdf.pageCount, 3)
    let extracted = pdf.string ?? ""
    // PDFKit may insert whitespace and move underscore glyphs into a later text run.
    // Use words for the marker and assert the final answer too; visual layout is reviewed separately.
    let compact = extracted.filter { !$0.isWhitespace }
    XCTAssertTrue(compact.contains("FINALSENTINELx=4"), String(extracted.suffix(1800)))
    XCTAssertTrue(compact.contains("180.Step180:"))
    XCTAssertTrue(compact.contains("Sourcephotograph"))
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "com.adobe.pdf")
    attachment.name = "pagination-proof.pdf"; attachment.lifetime = .keepAlways; add(attachment)
  }
  func testHandsFreeCaptureAutomaticallySolvesAndPresentsExactlyOnePDF() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.95)!)
    let analyzer = FakePageAnalyzer(sample: goodSample())
    let solver = FakePageSolver()
    let saver = FakeSolutionSaver()
    let model = makeModel(camera, analyzer, solver, saver)
    model.start()
    await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    XCTAssertEqual(camera.shutters, 1, "The wearer is released at the shutter, before the still is checked.")
    model.finishScanning()
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(model.phase, .finished, model.guide)
    XCTAssertTrue(model.showPDF)
    XCTAssertEqual(camera.captures, 1)
    XCTAssertEqual(saver.saves, 1)
    let count = await solver.calls
    XCTAssertEqual(count, 1)
    XCTAssertTrue(model.pages.isEmpty, "A saved PDF holds the originals; the next Start begins a new packet.")
    for _ in 0..<20 { camera.onFrame?(paperImage().cgImage!) }
    XCTAssertEqual(camera.captures, 1)
    model.stop()
  }
  func testNoDetectedTextOutlineStillCompletesHandsFree() async throws {
    let camera = FakeScanCamera(data: problemImage().jpegData(compressionQuality: 0.95)!)
    var sample = goodSample(); sample.contentBounds = nil; sample.cue = .findProblem
    let solver = FakePageSolver(), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: sample), solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model, count: 12)
    await waitUntil { model.phase == .awaitingNext }
    model.finishScanning()
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(model.phase, .finished, model.guide)
    XCTAssertEqual(camera.captures, 1); XCTAssertEqual(saver.saves, 1)
    XCTAssertTrue(model.showPDF); model.stop()
  }
  func testBadStillIsRetakenWithoutSendingToAI() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: goodSample(), rejectFirstStill: true)
    let solver = FakePageSolver()
    let saver = FakeSolutionSaver()
    let model = makeModel(camera, analyzer, solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { camera.resumes == 1 && model.phase == .seeking }
    let calls = await solver.calls
    XCTAssertEqual(calls, 0)
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    model.finishScanning()
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(camera.captures, 2)
    XCTAssertEqual(saver.saves, 1)
    model.stop()
  }
  func testUnreadableBatchKeepsAllPhotosWithoutPartialPDF() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(failure: AIResultError.unreadable("Page 1: exponent unclear.")), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    model.importPhoto(camera.data); await waitUntil { model.pages.count == 1 }
    model.finishScanning(); await waitUntil { model.phase == .failed }
    let calls = await solver.calls
    XCTAssertEqual(calls, 1); XCTAssertEqual(model.pages.count, 1)
    XCTAssertEqual(saver.saves, 0); XCTAssertFalse(model.showPDF)
    XCTAssertTrue(model.guide.contains("exponent unclear"), model.guide)
    model.stop()
  }
  func testGlassesDisconnectAfterPhotoDoesNotDiscardSolution() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(delay: true)
    let saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    model.importPhoto(camera.data)
    await waitUntil { model.pages.count == 1 && model.phase == .idle }
    model.finishScanning()
    await waitUntil { model.phase == .solving }
    camera.onProblem?("Glasses disconnected")
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(saver.saves, 1)
    XCTAssertTrue(model.showPDF)
    model.stop()
  }
  func testCancelIgnoresLateAIResponse() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(delay: true)
    let saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    model.importPhoto(camera.data)
    await waitUntil { model.pages.count == 1 && model.phase == .idle }
    model.finishScanning()
    await waitUntil { model.phase == .solving }
    model.stop()
    try await Task.sleep(for: .milliseconds(800))
    XCTAssertEqual(saver.saves, 0)
    XCTAssertFalse(model.showPDF)
    XCTAssertEqual(model.phase, .idle)
  }
  func testSDKPreviewToFullPhotoTransitionWithMockGlasses() async throws {
    try? Wearables.configure()
    MockDeviceKit.shared.enable()
    let glasses = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
    glasses.powerOn(); glasses.unfold(); glasses.don()
    await waitUntil { Wearables.shared.devices.contains(glasses.deviceIdentifier) }
    XCTAssertEqual(Wearables.shared.registrationState, .registered)
    MockDeviceKit.shared.permissions.set(.camera, .granted)
    MockDeviceKit.shared.permissions.setRequestResult(.camera, result: .granted)
    let camera = AutoScanCamera(wearables: Wearables.shared)
    var receivedFrame = false
    var commands: [ScanCommand] = [], notices: [String] = []
    camera.onFrame = { _ in receivedFrame = true }
    camera.onCommand = { commands.append($0) }
    camera.onNotice = { notices.append($0) }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("scan-fixture-\(UUID()).jpg")
    try paperImage().jpegData(compressionQuality: 0.95)!.write(to: file)
    glasses.services.cameraCapture.setCapturedPhoto(fileURL: file)
    let video = try XCTUnwrap(Bundle.main.url(forResource: "plant", withExtension: "mp4"))
    glasses.services.camera.setCameraFeed(fileURL: video)
    do {
      try await camera.start()
      // A cold CI simulator can spend several seconds preparing the bundled video feed.
      // Still require a delivered SDK frame; do not substitute a fake frame or skip this gate.
      await waitUntil(timeout: 20) { receivedFrame }
      XCTAssertTrue(receivedFrame, "The preview must deliver images before automatic quality checks can run.")
      // One mock session per test process: glasses buttons are checked here, before the full photo.
      await waitUntil(timeout: 25) { camera.inputsActive }
      XCTAssertTrue(camera.inputsActive, "Glasses buttons never activated. Notices: \(notices)")
      glasses.services.input.select()
      await waitUntil { commands.count == 1 }
      glasses.services.input.capture(pressType: .shortPress)
      await waitUntil { commands.count == 2 }
      glasses.services.input.capture(pressType: .hold)
      await waitUntil { commands.count == 3 }
      XCTAssertEqual(commands, [.finish, .next, .retakeLast])
      // The full-resolution photo must still work with Inputs attached.
      let captured = try await camera.capture()
      XCTAssertNotNil(UIImage(data: captured))
      camera.stop()
      await MockDeviceKit.shared.disable()
      try? FileManager.default.removeItem(at: file)
    } catch {
      camera.stop()
      await MockDeviceKit.shared.disable()
      try? FileManager.default.removeItem(at: file)
      throw error
    }
  }
  func testMissingKeyAllowsCollectionButDoesNotUpload() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver()
    let model = AutoScanModel(camera: camera, analyzer: FakePageAnalyzer(sample: goodSample()), solver: solver,
      draft: temporaryDraft(), voice: FakeScanVoice(), configurationProvider: { SolverConfiguration() })
    model.voiceGuidance = false; model.importPhoto(camera.data)
    await waitUntil { model.pages.count == 1 }
    model.finishScanning()
    XCTAssertTrue(model.needsKey); XCTAssertEqual(camera.starts, 0)
    let calls = await solver.calls; XCTAssertEqual(calls, 0)
    model.stop()
  }

  func testDistantSmallTextNeverTimesOutIntoCapture() {
    var gate = StabilityGate(), sample = goodSample()
    sample.closeEnough = false; sample.cue = .closer
    for n in 0..<80 { XCTAssertEqual(gate.observe(sample, at: Double(n) * 0.35), 0) }
    sample.closeEnough = true; sample.cue = .hold
    for n in 0...6 { _ = gate.observe(sample, at: 30 + Double(n) * 0.3) }
    XCTAssertTrue(gate.latched)
  }
  func testPageTurnDoesNotRecaptureStationaryWritingOrHeadMotion() {
    var turn = PageTurnGate(), saved = goodSample()
    saved.contentFingerprint = Array(repeating: 0.05, count: 256)
    turn.saved(saved, at: 0)
    var headMoved = saved
    headMoved.fingerprint = Array(repeating: 0.6, count: 256)
    for n in 1...20 { XCTAssertFalse(turn.observe(headMoved, at: Double(n))) }
    var next = saved; next.contentFingerprint = Array(repeating: 0.3, count: 256)
    XCTAssertFalse(turn.observe(next, at: 21)); XCTAssertFalse(turn.observe(next, at: 22))
    XCTAssertTrue(turn.observe(next, at: 23))
  }
  func testVoiceCommandsAndQuietDefault() {
    XCTAssertEqual(ScanCommand.parse("please finish scanning"), .finish)
    XCTAssertEqual(ScanCommand.parse("Next page."), .next)
    XCTAssertEqual(ScanCommand.parse("retake last page"), .retakeLast)
    XCTAssertEqual(ScanCommand.parse("cancel scanning"), .cancel)
    XCTAssertNil(ScanCommand.parse("I am scanning a page"))
    XCTAssertEqual(ScanVoice.quietVolume, 0.05, accuracy: 0.0001)
  }
  func testProductionVoiceCallbacksCanRunOffMainActor() async throws {
    let voice = ScanVoice()
    // Execute exactly the closures installed in AVAudioEngine and Speech, not a fake listener.
    // An implicitly MainActor callback aborts the process here under Swift 6.
    let tap = voice.makeAudioTap(), resultHandler = voice.makeRecognitionHandler()
    let usedBackgroundThread = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
      DispatchQueue.global(qos: .userInitiated).async { @Sendable in
        do {
          let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
          let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
          buffer.frameLength = 1024
          buffer.floatChannelData?[0].initialize(repeating: 0, count: 1024)
          let time = AVAudioTime(sampleTime: 0, atRate: 48000)
          for _ in 0..<32 { tap(buffer, time) }
          resultHandler(nil, URLError(.cancelled))
          continuation.resume(returning: !Thread.isMainThread)
        } catch { continuation.resume(throwing: error) }
      }
    }
    XCTAssertTrue(usedBackgroundThread)
    voice.stopCommands()
  }
  func testOldSpeechPermissionCannotReviveListenerAfterStopAndRestart() async {
    var requests: [CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>] = []
    var microphoneRequests = 0, statuses: [String] = []
    let voice = ScanVoice(speechAuthorization: {
      await withCheckedContinuation { requests.append($0) }
    }, microphoneAuthorization: { microphoneRequests += 1; return false })
    voice.onStatus = { statuses.append($0) }
    let old = Task { await voice.startCommands() }
    await waitUntil { requests.count == 1 }
    voice.stopCommands()
    let current = Task { await voice.startCommands() }
    await waitUntil { requests.count == 2 }
    guard requests.count == 2 else { XCTFail("Both permission requests should be pending"); return }
    requests[0].resume(returning: .authorized); await old.value
    XCTAssertEqual(microphoneRequests, 0); XCTAssertTrue(statuses.isEmpty)
    requests[1].resume(returning: .denied); await current.value
    XCTAssertEqual(statuses.count, 1); XCTAssertEqual(microphoneRequests, 0)
    voice.stopCommands()
  }
  func testCancelledPermissionTaskCannotStartMicrophone() async {
    var request: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>?
    var microphoneRequests = 0, statuses: [String] = []
    let voice = ScanVoice(speechAuthorization: {
      await withCheckedContinuation { request = $0 }
    }, microphoneAuthorization: { microphoneRequests += 1; return false })
    voice.onStatus = { statuses.append($0) }
    let pending = Task { await voice.startCommands() }
    await waitUntil { request != nil }
    pending.cancel(); request?.resume(returning: .authorized); await pending.value
    XCTAssertEqual(microphoneRequests, 0); XCTAssertTrue(statuses.isEmpty)
    voice.stopCommands()
  }
  func testLateMicrophonePermissionCannotChangeNewVoiceRun() async {
    var microphone: CheckedContinuation<Bool, Never>?
    var speechRequests = 0, statuses: [String] = []
    let voice = ScanVoice(speechAuthorization: {
      speechRequests += 1; return speechRequests == 1 ? .authorized : .denied
    }, microphoneAuthorization: {
      await withCheckedContinuation { microphone = $0 }
    })
    voice.onStatus = { statuses.append($0) }
    let old = Task { await voice.startCommands() }
    await waitUntil { microphone != nil }
    voice.stopCommands(); await voice.startCommands()
    XCTAssertEqual(statuses.count, 1)
    microphone?.resume(returning: true); await old.value
    XCTAssertEqual(statuses.count, 1, "An old microphone answer must not activate audio or overwrite the current status.")
    voice.stopCommands()
  }
  func testCameraAndReadyCueWaitForVoicePreparation() async {
    let camera = FakeScanCamera(data: Data()), voice = FakeScanVoice()
    var ready: CheckedContinuation<Void, Never>?
    voice.startHook = { await withCheckedContinuation { ready = $0 } }
    let model = AutoScanModel(camera: camera, analyzer: FakePageAnalyzer(sample: goodSample()),
      solver: FakePageSolver(), saver: FakeSolutionSaver(), draft: temporaryDraft(), voice: voice)
    model.voiceCommands = true
    model.start(); await waitUntil { ready != nil }
    XCTAssertEqual(model.phase, .connecting); XCTAssertEqual(camera.starts, 0)
    XCTAssertTrue(voice.messages.isEmpty)
    ready?.resume(); await waitUntil { model.phase == .seeking }
    XCTAssertEqual(camera.starts, 1); XCTAssertEqual(voice.messages.count, 1)
    model.stop()
  }
  func testStoppingDuringVoicePreparationDoesNotStartCameraLater() async {
    let camera = FakeScanCamera(data: Data()), voice = FakeScanVoice()
    var ready: CheckedContinuation<Void, Never>?
    voice.startHook = { await withCheckedContinuation { ready = $0 } }
    let model = AutoScanModel(camera: camera, analyzer: FakePageAnalyzer(sample: goodSample()),
      solver: FakePageSolver(), saver: FakeSolutionSaver(), draft: temporaryDraft(), voice: voice)
    model.voiceCommands = true
    model.start(); await waitUntil { ready != nil }
    model.stop(); ready?.resume()
    await waitUntil { voice.startReturned }
    XCTAssertEqual(model.phase, .idle); XCTAssertEqual(camera.starts, 0)
    XCTAssertTrue(voice.messages.isEmpty)
  }
  func testPagesSolveWhileScanningWithNeighborsAndStationaryFramesDoNotRecapture() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    for _ in 0..<12 { camera.onFrame?(paperImage().cgImage!) }
    var calls = await solver.calls
    XCTAssertEqual(calls, 0, "The newest page waits for the next page as context.")
    XCTAssertEqual(model.pages.count, 1); XCTAssertEqual(camera.captures, 1)
    model.handle(.next)
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.pages.count == 2 && model.phase == .awaitingNext }
    await waitUntil { model.pageStates[model.pages[0].id] == .solved }
    calls = await solver.calls
    XCTAssertEqual(calls, 1, "Page 1 is solved during scanning, once page 2 exists.")
    let first = await solver.jobs.first
    XCTAssertEqual(first?.number, 1); XCTAssertNotNil(first?.next); XCTAssertNil(first?.previous)
    XCTAssertEqual(model.pageStates[model.pages[1].id], .waiting)
    model.handle(.finish); await waitUntil { model.phase == .finished }
    calls = await solver.calls
    XCTAssertEqual(calls, 2, "Finish solves only the last page.")
    let last = await solver.jobs.last
    XCTAssertEqual(last?.number, 2); XCTAssertNotNil(last?.previous); XCTAssertNil(last?.next)
    XCTAssertEqual(saver.saves, 1); XCTAssertEqual(saver.sourceCount, 2)
    XCTAssertEqual(saver.lastPage?.problems.map(\.label), ["1(a) p1", "1(a) p2"])
    XCTAssertTrue(model.showPDF); model.stop()
  }
  func testSolveAtFinishWhenSolvingWhileScanningIsOff() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    model.solveWhileScanning = false
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    model.handle(.next)
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.pages.count == 2 && model.phase == .awaitingNext }
    try await Task.sleep(for: .milliseconds(300))
    var calls = await solver.calls
    XCTAssertEqual(calls, 0, "Nothing is uploaded before Finish when the option is off.")
    model.finishScanning(); await waitUntil { model.phase == .finished }
    calls = await solver.calls
    XCTAssertEqual(calls, 2); XCTAssertEqual(saver.saves, 1); model.stop()
  }
  func testThumbsUpGestureFinishesAndSolvesWithoutTouchingThePhone() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: goodSample()), solver = FakePageSolver(), saver = FakeSolutionSaver()
    let model = makeModel(camera, analyzer, solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    await analyzer.setGesture(.thumbsUp)
    for _ in 0..<8 {
      guard model.phase == .awaitingNext else { break }
      camera.onFrame?(paperImage().cgImage!)
      try await Task.sleep(for: .milliseconds(350))
    }
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(model.phase, .finished, model.guide)
    XCTAssertEqual(camera.captures, 1, "A raised command hand must never be photographed.")
    XCTAssertEqual(saver.saves, 1); model.stop()
  }
  func testThumbsUpBeforeAnyPageDoesNotFinish() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    var sample = goodSample(); sample.gesture = .thumbsUp
    let solver = FakePageSolver(), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: sample), solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model, count: 10)
    XCTAssertEqual(model.phase, .seeking); XCTAssertEqual(camera.captures, 0)
    let calls = await solver.calls; XCTAssertEqual(calls, 0); model.stop()
  }
  func testGlassesClicksFinishAndRetake() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    let firstID = model.pages[0].id
    camera.onCommand?(.retakeLast)
    XCTAssertEqual(model.phase, .seeking)
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext && model.pages.first?.id != firstID }
    XCTAssertEqual(model.pages.count, 1, "A retake replaces the page instead of adding one.")
    camera.onCommand?(.finish)
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(saver.saves, 1); XCTAssertEqual(camera.captures, 2); model.stop()
  }
  func testFailedPageIsRetriedAloneAndSolvedPagesAreKept() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(failFirstAttemptOfPage: 1), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    model.importPhoto(camera.data); await waitUntil { model.pages.count == 1 && model.phase == .idle }
    model.importPhoto(camera.data); await waitUntil { model.pages.count == 2 && model.phase == .idle }
    model.finishScanning(); await waitUntil { model.phase == .failed }
    XCTAssertTrue(model.guide.contains("Solved pages are kept"), model.guide)
    XCTAssertEqual(model.pageStates[model.pages[1].id], .solved)
    var calls = await solver.calls; XCTAssertEqual(calls, 2)
    model.finishScanning(); await waitUntil { model.phase == .finished }
    calls = await solver.calls
    XCTAssertEqual(calls, 3, "Only the failed page is solved again.")
    XCTAssertEqual(saver.saves, 1); model.stop()
  }
  func testSwitchingTabsDuringSolvingDoesNotCancelIt() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(delay: true), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    model.importPhoto(camera.data); await waitUntil { model.pages.count == 1 && model.phase == .idle }
    model.finishScanning(); await waitUntil { model.phase == .solving }
    model.viewDisappeared(); model.backgrounded()
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(saver.saves, 1); model.stop()
  }
  func testDraftRestoresInOrderAndRetakeReplacesOnlyOnePage() throws {
    let store = temporaryDraft(), bytes = paperImage().jpegData(compressionQuality: 0.9)!
    defer { try? store.clear() }
    var pages = try store.add(bytes, to: [], replacing: nil)
    pages = try store.add(bytes, to: pages, replacing: nil)
    let first = pages[0].id, oldSecond = pages[1].url
    pages = try store.add(bytes, to: pages, replacing: 1)
    let restored = store.load()
    XCTAssertEqual(restored.map(\.id), pages.map(\.id)); XCTAssertEqual(restored[0].id, first)
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldSecond.path))
    XCTAssertEqual(try Data(contentsOf: restored[1].url), bytes)
  }
  func testCombinedPDFIncludesCoverageAllPartsAndAllSourcePhotos() throws {
    var page = solvedPage(); page.coverage = "2 pages. All 2 subparts included."
    page = SolvedPage(readable: true, retakeReason: "", title: "Combined packet", problems: [
      SolvedProblem(problem: "First question", steps: ["First work"], answer: "FIRST ANSWER", check: "Check", label: "1(a)", sourcePages: [1]),
      SolvedProblem(problem: "Second question", steps: ["Second work"], answer: "LAST ANSWER", check: "SECOND VERIFICATION", label: "1(b)", sourcePages: [2], reviewNote: "NEEDS REVIEW: Missing unit")
    ], coverage: page.coverage, providers: "OpenAI + Claude")
    let data = try SolutionPDF.render(page: page, sources: [paperImage(), paperImage()])
    let pdf = try XCTUnwrap(PDFDocument(data: data)), text = (pdf.string ?? "").filter { !$0.isWhitespace }
    for marker in ["Coveragechecklist", "FIRSTANSWER", "LASTANSWER", "NEEDSREVIEW", "Sourcephotograph1", "Sourcephotograph2"] {
      XCTAssertTrue(text.contains(marker), "Missing \(marker)")
    }
    XCTAssertGreaterThanOrEqual(pdf.pageCount, 3)
    XCTAssertTrue((pdf.page(at: 0)?.string ?? "").contains("SECOND VERIFICATION"), "A short two-part solution should not strand its final check on an otherwise empty page.")
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "com.adobe.pdf")
    attachment.name = "batch-pdf-proof.pdf"; attachment.lifetime = .keepAlways; add(attachment)
  }

  private func temporaryDraft() -> ScanDraftStore {
    ScanDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID())"))
  }
  private func makeModel(_ camera: FakeScanCamera, _ analyzer: FakePageAnalyzer, _ solver: FakePageSolver, _ saver: FakeSolutionSaver) -> AutoScanModel {
    let model = AutoScanModel(camera: camera, analyzer: analyzer, solver: solver, saver: saver,
      draft: temporaryDraft(), voice: FakeScanVoice(),
      configurationProvider: { SolverConfiguration(openAIKey: "test-key-never-sent", openAIModel: "gpt-4.1") })
    model.voiceGuidance = false; return model
  }
  private func sendStableFrames(_ camera: FakeScanCamera, model: AutoScanModel, count: Int = 8) async throws {
    let image = paperImage().cgImage!
    for _ in 0..<count {
      guard model.phase == .seeking else { break }
      camera.onFrame?(image)
      try await Task.sleep(for: .milliseconds(350))
    }
  }
  private func waitUntil(timeout: Double = 5, _ predicate: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while !predicate() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(40)) }
  }
  private func solvedPage() -> SolvedPage {
    SolvedPage(readable: true, retakeReason: "", title: "Linear equation", problems: [SolvedProblem(problem: "2x + 3 = 11", steps: ["Subtract 3.", "Divide by 2."], answer: "x = 4", check: "2 × 4 + 3 = 11")])
  }
  /// A complete problem without a visible sheet outline; optionally surrounded by clutter.
  private func problemImage(cluttered: Bool = false, offCenter: Bool = false) -> UIImage {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 720, height: 1280), format: format).image { renderer in
      UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 720, height: 1280))
      let context = renderer.cgContext
      if cluttered {
        for n in 0..<30 {
          UIColor(hue: CGFloat(n % 7) / 7, saturation: 0.65, brightness: 0.6, alpha: 1).setFill()
          renderer.fill(CGRect(x: CGFloat((n * 83) % 700), y: CGFloat((n * 157) % 1250), width: 110, height: 75))
        }
        context.translateBy(x: 360, y: 640); context.rotate(by: 0.19)
        context.translateBy(x: -360, y: -640)
        UIColor.white.setFill(); context.fill(CGRect(x: -150, y: 360, width: 1020, height: 520))
      }
      let origin = offCenter ? CGPoint(x: 70, y: 75) : CGPoint(x: 70, y: 470)
      for (index, text) in ["Solve for x:", "2x + 3 = 11", "Show your steps."].enumerated() {
        (text as NSString).draw(at: CGPoint(x: origin.x, y: origin.y + CGFloat(index) * 70),
          withAttributes: [.font: UIFont.systemFont(ofSize: 38), .foregroundColor: UIColor.black])
      }
    }
  }
  private func paperImage(blank: Bool = false) -> UIImage {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1600), format: format).image { context in
      UIColor.darkGray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
      UIColor.white.setFill(); context.fill(CGRect(x: 120, y: 160, width: 960, height: 1280))
      if !blank {
        for line in 0..<19 { ("Problem \(line + 1): 2x + 3 = 11. Find x." as NSString)
          .draw(at: CGPoint(x: 180, y: 230 + line * 55), withAttributes: [.font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.black]) }
      }
    }
  }
}

@MainActor
private final class FakeScanCamera: ScanCamera {
  var onFrame: ((CGImage) -> Void)?
  var onProblem: ((String) -> Void)?
  var onProgress: ((Double) -> Void)?
  var onNotice: ((String) -> Void)?
  var onShutter: (() -> Void)?
  var onCommand: ((ScanCommand) -> Void)?
  var glassesButtons = true
  let data: Data
  var captures = 0, resumes = 0, starts = 0, shutters = 0
  init(data: Data) { self.data = data }
  func start() async throws { starts += 1 }
  func resumePreview() async throws { resumes += 1 }
  func capture() async throws -> Data { captures += 1; shutters += 1; onShutter?(); return data }
  func stop() {}
}
private actor FakePageAnalyzer: PageAnalyzing {
  var sample: PageSample
  var rejectFirstStill: Bool
  init(sample: PageSample, rejectFirstStill: Bool = false) { self.sample = sample; self.rejectFirstStill = rejectFirstStill }
  func setGesture(_ gesture: HandGesture?) { sample.gesture = gesture }
  func analyze(_ image: CGImage, still: Bool) async throws -> PageSample { sample }
  func prepare(_ data: Data) async throws -> PreparedPhoto {
    var value = sample; value.gesture = nil
    if rejectFirstStill { value.issue = "Hold still; blurry photo."; rejectFirstStill = false }
    return PreparedPhoto(jpeg: data, sample: value, width: 1200, height: 1600)
  }
}
/// Returns one solved item per page, labeled with its page number, after optional failures/delays.
private actor FakePageSolver: PageSolving {
  let delay: Bool
  let failure: (any Error)?
  let failFirstAttemptOfPage: Int?
  private(set) var calls = 0
  private(set) var jobs: [PageJob] = []
  private var failedOnce = false
  init(delay: Bool = false, failure: (any Error)? = nil, failFirstAttemptOfPage: Int? = nil) {
    self.delay = delay; self.failure = failure; self.failFirstAttemptOfPage = failFirstAttemptOfPage
  }
  func solve(_ job: PageJob, configuration: SolverConfiguration,
             progress: @escaping @Sendable (String) -> Void) async throws -> PageResult {
    calls += 1; jobs.append(job)
    if delay { try? await Task.sleep(for: .milliseconds(500)) }
    if let failure { throw failure }
    if job.number == failFirstAttemptOfPage && !failedOnce {
      failedOnce = true; throw SolverError.message("Page \(job.number): service unavailable.")
    }
    let item = PageSolutionItem(label: "1(a) p\(job.number)", problem: "2x + 3 = 11 on page \(job.number)",
      steps: ["Subtract 3.", "Divide by 2."], answer: "x = 4", check: "2 × 4 + 3 = 11", status: "solved",
      reviewNote: "", sourcePages: [job.number])
    return PageResult(readable: true, retake: "", title: "Linear equation", checklist: [item.label], solutions: [item], skipped: [])
  }
  func forget(keeping urls: Set<URL>) {}
}
@MainActor
private final class FakeSolutionSaver: SolutionSaving {
  var saves = 0
  var sourceCount = 0
  var lastPage: SolvedPage?
  func save(page: SolvedPage, sources: [URL]) async throws -> SavedSolution {
    saves += 1; sourceCount = sources.count; lastPage = page
    return SavedSolution(id: UUID(), title: page.title, date: Date(), pdf: URL(fileURLWithPath: "/tmp/test.pdf"), source: URL(fileURLWithPath: "/tmp/test.jpg"))
  }
}

@MainActor
private final class FakeScanVoice: ScanSpeaking {
  var onCommand: ((ScanCommand) -> Void)?
  var onStatus: ((String) -> Void)?
  var privateOnly = true
  var startHook: (() async -> Void)?
  var startReturned = false
  var messages: [String] = []
  func prepareOutput() {}
  func startCommands() async { await startHook?(); startReturned = true }
  func stopCommands() {}
  func say(_ message: String, volume: Float) { messages.append(message) }
  func stopSpeaking() {}
}
