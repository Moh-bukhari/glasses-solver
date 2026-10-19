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
    var guideAtShutter = ""
    camera.captureHook = { [weak model] in guideAtShutter = model?.guide ?? "" }
    model.start()
    await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    XCTAssertTrue(guideAtShutter.hasPrefix("Got it"), "The wearer is released at the shutter, before the still is checked: \(guideAtShutter)")
    model.finishScanning()
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(model.phase, .finished, model.guide)
    XCTAssertTrue(model.showPDF)
    XCTAssertEqual(camera.captures, 1)
    XCTAssertEqual(saver.saves, 1)
    let count = await solver.calls
    XCTAssertEqual(count, 1)
    XCTAssertTrue(model.packetSolved); XCTAssertFalse(model.canFinish)
    XCTAssertEqual(model.pages.count, 1, "The solved packet stays fixable until the next Start.")
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
      XCTAssertEqual(commands, [.finish, .next, .previous])
      // A single touchpad tap pauses; the scan reports it and resumes on the next tap instead of failing.
      glasses.services.captouch.tap()
      await waitUntil { notices.contains { $0.hasPrefix("Paused from the glasses") } }
      XCTAssertTrue(notices.contains { $0.hasPrefix("Paused from the glasses") }, "Notices: \(notices)")
      glasses.services.captouch.tap()
      await waitUntil { notices.contains { $0.hasPrefix("Resumed") } }
      XCTAssertTrue(notices.contains { $0.hasPrefix("Resumed") }, "Notices: \(notices)")
      receivedFrame = false
      await waitUntil(timeout: 10) { receivedFrame }
      XCTAssertTrue(receivedFrame, "Preview frames resume after the glasses pause.")
      // The full-resolution photo must still work with Inputs attached.
      let captured = try await camera.capture()
      XCTAssertNotNil(UIImage(data: captured))
      // Evidence only: whether this mock restarts the stream after a full photo. The app falls back to a
      // full reconnect (AutoScanModel.resume) when it cannot; real glasses behavior needs a device check.
      do { try await camera.resumePreview(); print("MOCK-PROBE post-photo stream restart: ok") }
      catch { print("MOCK-PROBE post-photo stream restart failed: \(error.localizedDescription)") }
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
    XCTAssertEqual(ScanCommand.parse("retake last page"), .previous)
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
    model.voiceCommands = true; model.captureMode = .frames
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
    model.voiceCommands = true; model.captureMode = .frames
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
    for _ in 0..<9 { camera.onFrame?(paperImage().cgImage!); try await Task.sleep(for: .milliseconds(350)) }
    XCTAssertEqual(model.phase, .awaitingNext, "Stationary writing past the 2 s guard is not a page turn.")
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
    XCTAssertEqual(camera.captures, 1)
    XCTAssertEqual(saver.saves, 1); model.stop()
  }
  func testChangedWritingTurnsThePageAutomatically() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: goodSample()), solver = FakePageSolver(), saver = FakeSolutionSaver()
    let model = makeModel(camera, analyzer, solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    await analyzer.setContent(0.3)
    for _ in 0..<12 {
      guard model.phase == .awaitingNext else { break }
      camera.onFrame?(paperImage().cgImage!); try await Task.sleep(for: .milliseconds(350))
    }
    XCTAssertEqual(model.phase, .seeking, "A new page in view re-arms capture without any command.")
    model.stop()
  }
  /// Scans two pages hands-free; the AI cannot read page 1 while page 2 is being scanned.
  private func scanTwoPagesWithUnclearFirstPage(_ camera: FakeScanCamera, _ model: AutoScanModel) async throws {
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    model.handle(.next)
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.pages.count == 2 && model.solveStatus.contains("bottom line") }
    XCTAssertTrue(model.solveStatus.contains("ask for it again when you finish"), model.solveStatus)
  }
  func testUnclearPageIsAskedForAgainAfterFinishWithoutThePhone() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: goodSample())
    let solver = FakePageSolver(unreadableOnceOnPage: 1), saver = FakeSolutionSaver()
    let model = makeModel(camera, analyzer, solver, saver)
    try await scanTwoPagesWithUnclearFirstPage(camera, model)
    let original = model.pages.map(\.id)
    model.handle(.finish)
    await waitUntil { model.phase == .seeking && camera.starts == 2 }
    XCTAssertTrue(model.guide.contains("Show page 1 again"), model.guide)
    // The sheet still in view (page 2) is never saved as page 1; the view must change first.
    try await sendStableFrames(camera, model: model, count: 7)
    XCTAssertEqual(camera.captures, 2); XCTAssertEqual(model.phase, .seeking, model.guide)
    XCTAssertTrue(model.guide.contains("Turn to page 1"), model.guide)
    await analyzer.setContent(0.3) // the wearer turns back to page 1
    try await sendStableFrames(camera, model: model, count: 20)
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(model.phase, .finished, model.guide)
    XCTAssertEqual(camera.captures, 3); XCTAssertEqual(model.pages.count, 2)
    XCTAssertNotEqual(model.pages[0].id, original[0]); XCTAssertEqual(saver.saves, 1)
    XCTAssertEqual(saver.lastPage?.problems.map(\.label), ["1(a) p1", "1(a) p2"])
    model.stop()
  }
  func testThumbsUpWhileAskedForAnUnclearPageSolvesWithoutIt() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(unreadableOnceOnPage: 1), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    try await scanTwoPagesWithUnclearFirstPage(camera, model)
    model.handle(.finish)
    await waitUntil { model.phase == .seeking && camera.starts == 2 }
    model.handle(.finish)
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(model.phase, .finished, model.guide)
    XCTAssertEqual(camera.captures, 2); XCTAssertEqual(saver.saves, 1)
    let note = saver.lastPage?.problems.first
    XCTAssertEqual(note?.label, "Page 1"); XCTAssertEqual(note?.sourcePages, [1])
    XCTAssertTrue(note?.reviewNote?.hasPrefix("NEEDS REVIEW") == true, note?.reviewNote ?? "")
    XCTAssertEqual(saver.lastPage?.problems.last?.label, "1(a) p2")
    XCTAssertTrue(model.guide.contains("Left out unreadable: Page 1."), model.guide)
    let calls = await solver.calls
    XCTAssertEqual(calls, 2, "The unreadable photo is never sent again.")
    model.stop()
  }
  func testHandsFreeSolveFailureWaitsForThumbsUpToRetry() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: goodSample())
    let solver = FakePageSolver(failFirstAttemptOfPage: 1), saver = FakeSolutionSaver()
    let model = makeModel(camera, analyzer, solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    model.handle(.finish)
    await waitUntil { model.phase == .awaitingNext && camera.starts == 2 }
    XCTAssertTrue(model.guide.contains("thumbs-up to try again"), model.guide)
    await analyzer.setContent(0.3)
    for _ in 0..<10 { camera.onFrame?(paperImage().cgImage!); try await Task.sleep(for: .milliseconds(350)) }
    XCTAssertEqual(model.phase, .awaitingNext, "Waiting for a gesture, not a page turn.")
    model.handle(.finish)
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(saver.saves, 1); XCTAssertEqual(camera.captures, 1)
    model.stop()
  }
  func testSidewaysThumbsMoveToTheNextPageAndRetakeThePreviousOne() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: goodSample()), solver = FakePageSolver(), saver = FakeSolutionSaver()
    let model = makeModel(camera, analyzer, solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    func hold(_ gesture: HandGesture, until done: () -> Bool) async throws {
      await analyzer.setGesture(gesture)
      for _ in 0..<10 where !done() { camera.onFrame?(paperImage().cgImage!); try await Task.sleep(for: .milliseconds(350)) }
      await analyzer.setGesture(nil)
    }
    try await hold(.thumbsRight) { model.phase == .seeking }
    XCTAssertEqual(model.phase, .seeking, "👉 skips waiting for a page turn.")
    try await sendStableFrames(camera, model: model, count: 12)
    await waitUntil { model.pages.count == 2 && model.phase == .awaitingNext }
    let second = model.pages[1].id
    try await hold(.thumbsLeft) { model.phase == .seeking }
    XCTAssertEqual(model.phase, .seeking, "👈 retakes the page just scanned.")
    try await sendStableFrames(camera, model: model, count: 12)
    await waitUntil { model.phase == .awaitingNext && model.pages.last?.id != second }
    XCTAssertEqual(model.pages.count, 2, "A retake replaces the page instead of adding one.")
    XCTAssertNotEqual(model.pages[1].id, second); XCTAssertEqual(camera.captures, 3)
    model.stop()
  }
  func testPreviousStepsBackAndWaitsForThatPageBeforeCapturing() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: goodSample()), solver = FakePageSolver(), saver = FakeSolutionSaver()
    let model = makeModel(camera, analyzer, solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    model.handle(.next)
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.pages.count == 2 && model.phase == .awaitingNext }
    let original = model.pages.map(\.id)
    model.handle(.previous); XCTAssertEqual(model.phase, .seeking) // page 2, still in view
    model.handle(.previous) // one more page back: page 1 is not in view
    XCTAssertTrue(model.guide.contains("Retaking page 1"), model.guide)
    model.handle(.previous); XCTAssertTrue(model.guide.contains("page 1"), "There is nothing before page 1. \(model.guide)")
    try await sendStableFrames(camera, model: model, count: 7)
    XCTAssertEqual(camera.captures, 2, "Page 2, still in front of the wearer, is not saved as page 1.")
    await analyzer.setContent(0.3) // turned back to page 1
    try await sendStableFrames(camera, model: model, count: 20)
    await waitUntil { model.phase == .awaitingNext && model.pages.first?.id != original[0] }
    XCTAssertEqual(model.pages.count, 2); XCTAssertEqual(model.pages[1].id, original[1])
    XCTAssertNotEqual(model.pages[0].id, original[0])
    XCTAssertTrue(model.guide.contains("thumbs-right"), "Fixed an earlier page: wait for 👉 at the next new page. \(model.guide)")
    model.stop()
  }
  func testLaunchShortcutStartsScanningOnceTheAppIsActive() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), FakePageSolver(), FakeSolutionSaver())
    model.startFromShortcut(); XCTAssertEqual(model.phase, .idle, "Nothing starts without a shortcut request.")
    model.requestShortcutStart(); XCTAssertTrue(model.shortcutPending); XCTAssertEqual(model.shortcutRequests, 1)
    model.startFromShortcut(); XCTAssertFalse(model.shortcutPending)
    await waitUntil { model.phase == .seeking }
    XCTAssertEqual(camera.starts, 1)
    model.requestShortcutStart(); model.startFromShortcut()
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(camera.starts, 1, "A second shortcut press while scanning does not restart the camera.")
    XCTAssertEqual(model.phase, .seeking); model.stop()
  }
  /// Sends preview frames for about `seconds` while seeking, one every 350 ms.
  private func sendFrames(_ camera: FakeScanCamera, model: AutoScanModel, seconds: Double) async throws {
    let image = paperImage().cgImage!
    for _ in 0..<Int(seconds / 0.35) {
      guard model.phase == .seeking else { break }
      camera.onFrame?(image); try await Task.sleep(for: .milliseconds(350))
    }
  }
  func testEachPageIsCheckedBeforeTheScanMovesOnAndSolvedOnlyAfterThumbsUp() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: frameSample()), solver = FakePageSolver(), saver = FakeSolutionSaver()
    let checker = FakePageChecker([.success(.unclear("Look at the bottom of the page, closer."))]), voice = FakeScanVoice()
    let model = makeModel(camera, analyzer, solver, saver, capture: .frames, voice: voice, checker: checker, solveWhileScanning: false)
    await analyzer.setText(text(viewA))
    model.start(); await waitUntil { model.phase == .seeking }
    try await show(camera) { voice.messages.contains("Page 1: Look at the bottom of the page, closer.") }
    XCTAssertTrue(voice.messages.contains("Checking page 1."), "\(voice.messages)")
    XCTAssertTrue(voice.messages.contains("Page 1: Look at the bottom of the page, closer."), "\(voice.messages)")
    XCTAssertEqual(model.phase, .seeking, "An unclear page is not saved; the wearer keeps looking at it.")
    XCTAssertTrue(model.pages.isEmpty)
    await analyzer.setContent(0.3); await analyzer.setText(text(rest)) // the bottom of page 1
    try await show(camera) { model.phase == .awaitingNext }
    XCTAssertEqual(model.pages.count, 1); XCTAssertEqual(model.pages[0].frames.count, 2, "Both views are photos of page 1.")
    XCTAssertTrue(voice.messages.contains { $0.hasPrefix("Page 1 is clear. Turn the page.") }, "\(voice.messages)")
    var checks = await checker.photoCounts
    XCTAssertEqual(checks, [1, 2], "The second check sees every photo of the page.")
    var calls = await solver.calls
    XCTAssertEqual(calls, 0, "Nothing is solved before the thumbs-up.")
    XCTAssertEqual(camera.captures, 0, "No full-resolution still, so the preview never pauses.")
    await analyzer.setContent(0.9); await analyzer.setText(text(viewB)) // the wearer turns to page 2
    try await show(camera, limit: 30) { model.pages.count == 2 && model.phase == .awaitingNext }
    XCTAssertTrue(voice.messages.contains { $0.hasPrefix("Page 2 is clear.") }, "\(voice.messages)")
    checks = await checker.photoCounts
    XCTAssertEqual(checks, [1, 2, 1])
    model.handle(.finish); await waitUntil { model.phase == .finished }
    XCTAssertEqual(model.phase, .finished, model.guide)
    XCTAssertEqual(saver.frameCounts, [2, 1])
    calls = await solver.calls; XCTAssertEqual(calls, 2)
    model.stop()
  }
  func testAPhotoOfAnotherSheetIsLeftOutOfThePage() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: frameSample())
    let checker = FakePageChecker([.success(.unclear("Show the rest of the page.")),
      .success(PageVerdict(clear: true, say: "", dropped: [2]))])
    let model = makeModel(camera, analyzer, FakePageSolver(), FakeSolutionSaver(), capture: .frames, checker: checker)
    await analyzer.setText(text(viewA))
    model.start(); await waitUntil { model.phase == .seeking }
    try await show(camera) { model.guide.hasPrefix("Page 1: Show the rest") }
    await analyzer.setContent(0.5); await analyzer.setText(text(viewC)) // a glance at another sheet
    try await show(camera) { model.phase == .awaitingNext }
    let checks = await checker.photoCounts
    XCTAssertEqual(checks, [1, 2])
    XCTAssertEqual(model.pages.count, 1); XCTAssertEqual(model.pages[0].frames.count, 1, "Only page 1's photo is saved.")
    model.stop()
  }
  func testThumbsUpOnAnUnclearPageWarnsOnceThenSolvesAnyway() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: frameSample()), saver = FakeSolutionSaver(), voice = FakeScanVoice()
    let checker = FakePageChecker([.success(.unclear("Hold still over the table."))])
    let model = makeModel(camera, analyzer, FakePageSolver(), saver, capture: .frames, voice: voice, checker: checker)
    await analyzer.setText(text(viewA))
    model.start(); await waitUntil { model.phase == .seeking }
    try await show(camera) { voice.messages.contains("Page 1: Hold still over the table.") }
    model.handle(.finish)
    XCTAssertTrue(voice.messages.contains("Page 1 still isn't clear: Hold still over the table. Or thumbs-up to solve anyway."),
      "\(voice.messages)")
    XCTAssertEqual(model.phase, .seeking)
    model.handle(.finish) // the wearer solves anyway
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(model.phase, .finished, model.guide); XCTAssertEqual(saver.frameCounts, [1])
    model.stop()
  }
  func testThumbsUpChecksTheOpenPageFirst() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: frameSample()), saver = FakeSolutionSaver(), voice = FakeScanVoice()
    let checker = FakePageChecker([.success(.unclear("The bottom line is cut off; show it."))])
    let model = makeModel(camera, analyzer, FakePageSolver(), saver, capture: .frames, voice: voice, checker: checker)
    await analyzer.setText(text(viewA))
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendFrames(camera, model: model, seconds: 1.4) // a view is kept, but the page was not checked yet
    model.handle(.finish)
    try await show(camera) { voice.messages.contains { $0.hasPrefix("Page 1: The bottom line is cut off") } }
    XCTAssertTrue(voice.messages.contains("Page 1: The bottom line is cut off; show it. Or thumbs-up to solve anyway."),
      "\(voice.messages)")
    XCTAssertTrue(model.pages.isEmpty, "An unclear page is not solved without asking.")
    await analyzer.setContent(0.3); await analyzer.setText(text(rest)) // the wearer shows the bottom line
    try await show(camera) { model.phase == .awaitingNext }
    XCTAssertTrue(voice.messages.contains { $0.hasPrefix("Page 1 is clear.") }, "\(voice.messages)")
    model.handle(.finish); await waitUntil { model.phase == .finished }
    XCTAssertEqual(saver.frameCounts, [2]); model.stop()
  }
  func testACloserLookTheCheckAskedForIsCheckedAgain() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: frameSample()), voice = FakeScanVoice()
    let checker = FakePageChecker([.success(.unclear("Look closer at question 2, and hold still."))])
    let model = makeModel(camera, analyzer, FakePageSolver(), FakeSolutionSaver(), capture: .frames, voice: voice, checker: checker)
    await analyzer.setText(text(viewA))
    model.start(); await waitUntil { model.phase == .seeking }
    try await show(camera) { voice.messages.contains("Page 1: Look closer at question 2, and hold still.") }
    // A close-up of question 2: the same view, larger text, but it no longer shows question 1.
    await analyzer.setLinePixels(45); await analyzer.setText(text(["2. Find the slope of the line", "Show all of your work clearly"]))
    try await show(camera) { model.phase == .awaitingNext }
    let checks = await checker.photoCounts
    XCTAssertEqual(checks, [1, 2], "The close-up is kept and the page is checked again.")
    XCTAssertEqual(model.pages.first?.frames.count, 2); model.stop()
  }
  func testARetakeIsCheckedAgainstThePageItReplaces() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: frameSample()), voice = FakeScanVoice()
    let checker = FakePageChecker([.success(.clear),
      .success(PageVerdict(clear: false, say: "Turn to the right sheet.", dropped: [1], wrongSheet: true))])
    let model = makeModel(camera, analyzer, FakePageSolver(), FakeSolutionSaver(), capture: .frames, voice: voice, checker: checker)
    await analyzer.setText(text(viewA))
    model.start(); await waitUntil { model.phase == .seeking }
    try await show(camera) { model.phase == .awaitingNext }
    let original = try XCTUnwrap(model.pages.first?.id)
    model.handle(.previous); XCTAssertEqual(model.phase, .seeking) // 👈 retake page 1
    await analyzer.setContent(0.5); await analyzer.setText(text(viewB)) // but another sheet is in view
    try await show(camera) { voice.messages.contains("That's a different sheet. Turn to page 1.") }
    XCTAssertEqual(model.pages.map(\.id), [original], "Another sheet is never saved as page 1.")
    await analyzer.setContent(0.05); await analyzer.setText(text(viewA)) // page 1 again
    try await show(camera) { model.phase == .awaitingNext }
    XCTAssertEqual(model.pages.count, 1); XCTAssertNotEqual(model.pages.first?.id, original)
    let references = await checker.references
    XCTAssertEqual(references, [false, true, true], "Retake checks include an earlier photo of the page.")
    model.stop()
  }
  func testAPartlyShownPageIsGuidedWithoutEscalating() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: frameSample()), voice = FakeScanVoice()
    let notYet = PageVerdict(clear: false, say: "Show the bottom of the sheet.", dropped: [], notShownYet: true)
    let checker = FakePageChecker([.success(notYet), .success(notYet), .success(notYet)])
    let model = makeModel(camera, analyzer, FakePageSolver(), FakeSolutionSaver(), capture: .frames, voice: voice, checker: checker)
    await analyzer.setText(text(viewA))
    model.start(); await waitUntil { model.phase == .seeking }
    for (round, view) in [(1, viewA), (2, rest), (3, viewC)] { // three parts, each checked while the bottom is still unseen
      if round > 1 { await analyzer.setContent(0.3 * Double(round)); await analyzer.setText(text(view)) }
      try await show(camera, limit: 12) { false }
    }
    let checks = await checker.photoCounts
    XCTAssertEqual(checks.count, 3)
    XCTAssertEqual(voice.messages.filter { $0.contains("Show the bottom of the sheet.") }, ["Page 1: Show the bottom of the sheet."],
      "Said once, without asking to keep the page as it is.")
    await analyzer.setContent(0.95); await analyzer.setText(text(viewB)) // the bottom: the default checker says clear
    try await show(camera) { model.phase == .awaitingNext }
    XCTAssertEqual(model.pages.count, 1); model.stop()
  }
  func testAfterThreeUnclearChecksThePageWaitsForTheWearer() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: frameSample()), voice = FakeScanVoice()
    let checker = FakePageChecker(Array(repeating: .success(.unclear("Look closer at question 2.")), count: 4))
    let model = makeModel(camera, analyzer, FakePageSolver(), FakeSolutionSaver(), capture: .frames, voice: voice, checker: checker)
    await analyzer.setText(text(viewA))
    model.start(); await waitUntil { model.phase == .seeking }
    for (round, view) in [(1, viewA), (2, rest), (3, viewB)] {
      if round > 1 { await analyzer.setContent(0.3 * Double(round)); await analyzer.setText(text(view)) }
      try await show(camera) { voice.messages.filter { $0.contains("question 2") }.count == round }
    }
    XCTAssertTrue(voice.messages.contains("Page 1: Still unclear. Look closer at question 2. Or thumbs-right to keep it as it is."),
      "\(voice.messages)")
    XCTAssertTrue(voice.messages.contains("Page 1 still isn't clear: Look closer at question 2. Thumbs-right keeps it."),
      "\(voice.messages)")
    try await show(camera, limit: 6) { false } // nothing new: no fourth check of the same photos
    let checks = await checker.photoCounts
    XCTAssertEqual(checks.count, 3); XCTAssertEqual(model.phase, .seeking)
    model.handle(.next) // 👉 keeps the page as it is
    await waitUntil { model.phase == .awaitingNext && model.pages.count == 1 }
    XCTAssertEqual(model.pages.count, 1); model.stop()
  }
  func testAPageCheckThatCannotRunNeverBlocksTheScan() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: frameSample()), voice = FakeScanVoice()
    let denied = AIServiceError.http(provider: .openAI, status: 401, retryAfter: nil, detail: "invalid key")
    let checker = FakePageChecker([.failure(denied)])
    let model = makeModel(camera, analyzer, FakePageSolver(), FakeSolutionSaver(), capture: .frames, voice: voice, checker: checker)
    await analyzer.setText(text(viewA))
    model.start(); await waitUntil { model.phase == .seeking }
    try await show(camera) { model.phase == .awaitingNext }
    XCTAssertEqual(model.pages.count, 1, "The page is saved without a check.")
    XCTAssertTrue(voice.messages.contains { $0.hasPrefix("Page checks are off.") }, "\(voice.messages)")
    await analyzer.setContent(0.9); await analyzer.setText(text(viewB))
    try await show(camera, limit: 40) { model.pages.count == 2 && model.phase == .awaitingNext }
    let checks = await checker.photoCounts
    XCTAssertEqual(checks, [1], "Later pages are saved when nothing new appears, without trying again.")
    XCTAssertEqual(model.pages.count, 2)
    model.stop()
  }
  func testASlowOrDroppedCheckIsRetriedThenTheScanContinues() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: frameSample()), voice = FakeScanVoice()
    let checker = FakePageChecker([.failure(URLError(.timedOut)), .failure(URLError(.networkConnectionLost))])
    let model = makeModel(camera, analyzer, FakePageSolver(), FakeSolutionSaver(), capture: .frames, voice: voice, checker: checker)
    await analyzer.setText(text(viewA))
    model.start(); await waitUntil { model.phase == .seeking }
    try await show(camera, limit: 30) { model.phase == .awaitingNext }
    let checks = await checker.photoCounts
    XCTAssertEqual(checks, [1, 1], "One retry while the wearer holds still.")
    XCTAssertEqual(model.pages.count, 1)
    XCTAssertTrue(voice.messages.contains("Couldn't check page 1, so it's saved without a check."), "\(voice.messages)")
    model.stop()
  }
  func testThumbsRightSavesTheFramesNowAndThumbsUpSavesThenSolves() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: frameSample()), solver = FakePageSolver(), saver = FakeSolutionSaver()
    let model = makeModel(camera, analyzer, solver, saver, capture: .frames)
    await analyzer.setText(text(viewA))
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendFrames(camera, model: model, seconds: 1.5)
    model.handle(.next) // 👉 page done
    await waitUntil { model.phase == .awaitingNext && model.pages.count == 1 }
    XCTAssertEqual(model.pages.first?.frames.count, 1)
    model.handle(.next) // 👉 at the next page
    XCTAssertEqual(model.phase, .seeking)
    await analyzer.setContent(0.3); await analyzer.setText(text(viewB))
    try await sendFrames(camera, model: model, seconds: 1.5)
    model.handle(.finish) // 👍 with page 2 still open: it is saved first, then everything is solved
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(model.phase, .finished, model.guide)
    XCTAssertEqual(saver.frameCounts, [1, 1]); XCTAssertEqual(camera.captures, 0)
    let calls = await solver.calls; XCTAssertEqual(calls, 2)
    model.stop()
  }
  func testTheSameSheetSeenAgainAfterSavingIsNotTheNextPage() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: frameSample()), voice = FakeScanVoice()
    let model = makeModel(camera, analyzer, FakePageSolver(), FakeSolutionSaver(), capture: .frames, voice: voice)
    await analyzer.setText(text(viewA))
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendFrames(camera, model: model, seconds: 1.5)
    model.handle(.next); await waitUntil { model.phase == .awaitingNext && model.pages.count == 1 }
    await analyzer.setContent(0.6) // the whole sheet from farther away: a different image, the same writing
    for _ in 0..<20 where model.phase == .awaitingNext {
      camera.onFrame?(paperImage().cgImage!); try await Task.sleep(for: .milliseconds(350))
    }
    try await sendFrames(camera, model: model, seconds: 2)
    XCTAssertTrue(voice.messages.contains { $0.hasPrefix("Still page 1.") }, "\(voice.messages)")
    XCTAssertEqual(model.pages.count, 1)
    await analyzer.setContent(0.9); await analyzer.setText(text(viewB)) // now the next sheet
    try await sendFrames(camera, model: model, seconds: 1.5)
    model.handle(.next); await waitUntil { model.pages.count == 2 }
    XCTAssertEqual(model.pages.count, 2, "New writing is the next page.")
    model.stop()
  }
  /// Sends preview frames, whatever the phase, until `done` (at most `limit` frames, one every 350 ms).
  private func show(_ camera: FakeScanCamera, limit: Int = 20, until done: () -> Bool) async throws {
    for _ in 0..<limit where !done() { camera.onFrame?(paperImage().cgImage!); try await Task.sleep(for: .milliseconds(350)) }
  }
  func testThumbsUpBeforeAnyFrameIsKeptDoesNotFinish() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    var far = frameSample(); far.linePixels = 12 // readable outline but too small for the AI
    let analyzer = FakePageAnalyzer(sample: far), voice = FakeScanVoice()
    let model = makeModel(camera, analyzer, FakePageSolver(), FakeSolutionSaver(), capture: .frames, voice: voice)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendFrames(camera, model: model, seconds: 2)
    XCTAssertTrue(voice.messages.contains(ScanCue.closer.message), "Small text asks the wearer to move closer. \(voice.messages)")
    let reads = await analyzer.reads; XCTAssertEqual(reads, 0, "Too-small text is never read or kept.")
    model.handle(.finish)
    XCTAssertEqual(model.phase, .seeking); XCTAssertTrue(model.pages.isEmpty)
    model.stop()
  }
  func testFixingOnePageAfterThePDFResolvesOnlyItsNeighborhood() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    for count in 1...3 { model.importPhoto(camera.data); await waitUntil { model.pages.count == count && model.phase == .idle } }
    model.finishScanning(); await waitUntil { model.phase == .finished }
    var calls = await solver.calls; XCTAssertEqual(calls, 3)
    model.importPhoto(camera.data, replacing: 2)
    await waitUntil { model.phase == .idle && !model.packetSolved }
    XCTAssertTrue(model.canFinish); XCTAssertEqual(model.pages.count, 3)
    model.finishScanning(); await waitUntil { model.phase == .finished }
    calls = await solver.calls
    XCTAssertEqual(calls, 5, "Only the replaced page and its neighbor are solved again.")
    XCTAssertEqual(saver.saves, 2); model.stop()
  }
  func testAGlassesPauseNoticeDoesNotEndTheScan() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    camera.onNotice?("Paused from the glasses. Tap the side of your glasses once to continue.")
    XCTAssertEqual(model.phase, .seeking)
    camera.onNotice?("Resumed. Keep scanning.")
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    XCTAssertEqual(model.pages.count, 1); model.stop()
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
    camera.onCommand?(.previous)
    XCTAssertEqual(model.phase, .seeking)
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext && model.pages.first?.id != firstID }
    XCTAssertEqual(model.pages.count, 1, "A retake replaces the page instead of adding one.")
    camera.onCommand?(.finish)
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(saver.saves, 1); XCTAssertEqual(camera.captures, 2); model.stop()
  }
  func testFinishDuringCaptureStillSolvesWhenThatPhotoIsUnclear() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: goodSample()), solver = FakePageSolver(), saver = FakeSolutionSaver()
    let model = makeModel(camera, analyzer, solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    await analyzer.rejectNextStill()
    camera.captureHook = { [weak model] in model?.handle(.finish) }
    model.handle(.next)
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(model.phase, .finished, "A finish requested mid-capture must not strand the scan. \(model.guide)")
    XCTAssertEqual(camera.captures, 2); XCTAssertEqual(saver.sourceCount, 1, "The unclear photo is not added.")
    model.stop()
  }
  func testRetakingAnEarlierPageWaitsForThumbsRightInsteadOfAppendingTheNextSheet() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: goodSample())
    let solver = FakePageSolver(), saver = FakeSolutionSaver()
    let model = makeModel(camera, analyzer, solver, saver)
    for count in 1...3 { model.importPhoto(camera.data); await waitUntil { model.pages.count == count && model.phase == .idle } }
    let original = model.pages.map(\.id)
    model.start(replacing: 0); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext && model.pages.first?.id != original[0] }
    XCTAssertEqual(model.phase, .awaitingNext, model.guide)
    XCTAssertEqual(model.pages.count, 3); XCTAssertEqual(Array(model.pages.map(\.id).dropFirst()), Array(original.dropFirst()))
    XCTAssertTrue(model.guide.contains("replaced") && model.guide.contains("thumbs-right"), model.guide)
    // Turning to page 2 (already scanned) must not add it again; the camera stays on for 👉 or 👍.
    await analyzer.setContent(0.3)
    for _ in 0..<10 { camera.onFrame?(paperImage().cgImage!); try await Task.sleep(for: .milliseconds(350)) }
    XCTAssertEqual(model.phase, .awaitingNext); XCTAssertEqual(camera.captures, 1)
    model.handle(.next); XCTAssertEqual(model.phase, .seeking)
    XCTAssertTrue(model.guide.hasPrefix("Page 4"), model.guide)
    model.stop()
  }
  func testQuestionSkippedByBothNeighborsIsClaimedBeforeThePDF() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(orphanOnPage: 2), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    model.solveWhileScanning = false
    model.importPhoto(camera.data); await waitUntil { model.pages.count == 1 && model.phase == .idle }
    model.importPhoto(camera.data); await waitUntil { model.pages.count == 2 && model.phase == .idle }
    model.finishScanning(); await waitUntil { model.phase == .finished }
    XCTAssertEqual(model.phase, .finished, model.guide)
    let calls = await solver.calls, claim = await solver.jobs.last
    XCTAssertEqual(calls, 3, "Page 2 is solved again, once, to claim the orphaned item.")
    XCTAssertEqual(claim?.number, 2); XCTAssertEqual(claim?.mustSolve, ["5(b)"])
    XCTAssertTrue(saver.lastPage?.problems.contains { $0.label == "5(b)" } == true)
    model.stop()
  }
  func testFailedPageIsRetriedAloneAndSolvedPagesAreKept() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(failFirstAttemptOfPage: 1), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    model.solveWhileScanning = false // both pages are first solved at Finish, where page 1 fails once
    model.importPhoto(camera.data); await waitUntil { model.pages.count == 1 && model.phase == .idle }
    model.importPhoto(camera.data); await waitUntil { model.pages.count == 2 && model.phase == .idle }
    model.finishScanning(); await waitUntil { model.phase == .failed }
    XCTAssertTrue(model.guide.contains("Solved pages are kept"), model.guide)
    let second = try XCTUnwrap(model.pages.last?.id)
    XCTAssertEqual(model.pageStates[second], .solved)
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
  func testDraftKeepsEveryPhotoOfAPageAndReplacesThemTogether() throws {
    let store = temporaryDraft()
    defer { try? store.clear() }
    let parts = (1...3).map { Data(repeating: UInt8($0), count: 32) }
    var pages = try store.add(Data(repeating: 9, count: 32), to: [], replacing: nil) // a single still, as 2.0 saved it
    pages = try store.add(frames: parts, to: pages, replacing: nil)
    var restored = store.load()
    XCTAssertEqual(restored.map(\.frames.count), [1, 3])
    XCTAssertEqual(try restored[1].frames.map { try Data(contentsOf: $0) }, parts, "Photos keep their capture order.")
    XCTAssertEqual(restored[1].url, restored[1].frames[0])
    let oldFrames = pages[1].frames
    pages = try store.add(frames: [parts[0]], to: pages, replacing: 1)
    restored = store.load()
    XCTAssertEqual(restored.map(\.frames.count), [1, 1])
    XCTAssertTrue(oldFrames.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "A retake removes every old photo.")
    pages = try store.remove(at: 0, from: pages)
    XCTAssertEqual(store.load().map(\.id), pages.map(\.id))
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

  // MARK: Glasses photos (capture button)

  private func photoModel(_ checker: FakePageChecker = FakePageChecker(), solver: FakePageSolver = FakePageSolver(),
                          analyzer: FakePageAnalyzer? = nil) -> (AutoScanModel, FakePhotoSource, FakeScanVoice, FakeSolutionSaver) {
    let photos = FakePhotoSource(), voice = FakeScanVoice(), saver = FakeSolutionSaver()
    let model = makeModel(FakeScanCamera(data: Data()), analyzer ?? FakePageAnalyzer(sample: goodSample()), solver, saver,
      capture: .buttonPhotos, voice: voice, checker: checker, solveWhileScanning: false, photos: photos)
    return (model, photos, voice, saver)
  }
  func testButtonPhotosArePagedByChecksAndSolvedAsTheyGo() async throws {
    let checker = FakePageChecker([.success(.unclear("Take a closer photo of question 2.")), .success(.clear), .success(.clear)])
    let camera = FakeScanCamera(data: Data()), photos = FakePhotoSource(), voice = FakeScanVoice(), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), FakePageSolver(), saver, capture: .buttonPhotos,
      voice: voice, checker: checker, solveWhileScanning: false, photos: photos)
    model.start()
    await waitUntil { model.phase == .seeking }
    XCTAssertEqual(camera.starts, 0, "Button photos need no glasses camera stream.")
    XCTAssertEqual(photos.starts, 1)
    photos.take()
    await waitUntil { model.guide.contains("closer photo") }
    XCTAssertTrue(model.pages.isEmpty, "An unclear page is not saved.")
    photos.take()
    await waitUntil { model.pages.count == 1 }
    XCTAssertEqual(model.pages.first?.frames.count, 2, "Every photo of the page is kept.")
    XCTAssertTrue(voice.messages.contains { $0.hasPrefix("Page 1 is clear. Take page 2.") }, "\(voice.messages)")
    photos.take()
    await waitUntil { model.pages.count == 2 && model.solvedPages == 1 }
    XCTAssertEqual(model.solvedPages, 1, "Page 1 is solved as soon as page 2 is saved, without the solve-while-scanning setting.")
    let earlier = await checker.earlier, counts = await checker.photoCounts
    XCTAssertEqual(earlier, [false, false, true], "Page 2 is checked against a photo of page 1.")
    XCTAssertEqual(counts, [1, 2, 1])
    model.finishScanning()
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(saver.frameCounts, [2, 1])
    XCTAssertEqual(photos.stops > 0, true, "Watching Photos stops once solving starts.")
  }
  func testAPhotoOfTheNextSheetWaitsUntilThePageIsClear() async throws {
    let checker = FakePageChecker([.success(.unclear("Take a closer photo of the table.")),
      .success(PageVerdict(clear: false, say: "Take a closer photo of the table.", dropped: [2], otherSheet: [2])),
      .success(.clear), .success(.clear)])
    let (model, photos, voice, _) = photoModel(checker)
    model.start()
    await waitUntil { model.phase == .seeking }
    photos.take()
    await waitUntil { model.guide.contains("table") }
    photos.take() // page 2, too early
    await waitUntil { model.guide.contains("isn't clear yet") }
    XCTAssertTrue(model.pages.isEmpty)
    XCTAssertTrue(voice.messages.contains { $0.contains("Go back to it") }, "\(voice.messages)")
    photos.take() // a closer photo of page 1
    await waitUntil { model.pages.count == 2 }
    XCTAssertEqual(model.pages.map(\.frames.count), [2, 1], "The early photo of page 2 becomes page 2 once page 1 is clear.")
    let counts = await checker.photoCounts
    XCTAssertEqual(counts, [1, 2, 2, 1])
  }
  func testALatePhotoOfTheSavedPageDoesNotStartANewPage() async throws {
    let checker = FakePageChecker([.success(.clear),
      .success(PageVerdict(clear: false, say: "Turn to the right sheet.", dropped: [1], earlierSheet: [1])), .success(.clear)])
    let (model, photos, voice, _) = photoModel(checker)
    model.start()
    await waitUntil { model.phase == .seeking }
    photos.take()
    await waitUntil { model.pages.count == 1 }
    photos.take()
    await waitUntil { voice.messages.contains { $0.hasPrefix("That's page 1 again") } }
    XCTAssertEqual(model.pages.count, 1)
    photos.take()
    await waitUntil { model.pages.count == 2 }
    XCTAssertEqual(model.pages.map(\.frames.count), [1, 1])
  }
  func testCommandPhotosKeepAPageAsItIsAndFinish() async throws {
    let analyzer = FakePageAnalyzer(sample: goodSample())
    await analyzer.setPhotoGesture(.thumbsRight, for: "photo-2"); await analyzer.setPhotoGesture(.thumbsUp, for: "photo-4")
    let checker = FakePageChecker([.success(.unclear("Take a closer photo of question 3.")), .success(.clear)])
    let (model, photos, _, saver) = photoModel(checker, analyzer: analyzer)
    model.start()
    await waitUntil { model.phase == .seeking }
    photos.take()
    await waitUntil { model.guide.contains("question 3") }
    photos.take() // 👉: keep page 1 as it is
    await waitUntil { model.pages.count == 1 }
    photos.take()
    await waitUntil { model.pages.count == 2 }
    photos.take() // 👍: solve
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(saver.frameCounts, [1, 1], "Command photos are never pages.")
    let counts = await checker.photoCounts
    XCTAssertEqual(counts, [1, 1])
  }
  func testFinishingOnAnUnclearPageWarnsOnceThenSolvesAnyway() async throws {
    let checker = FakePageChecker([.success(.clear), .success(.unclear("Take a photo of the bottom of the sheet."))])
    let (model, photos, voice, saver) = photoModel(checker)
    model.start()
    await waitUntil { model.phase == .seeking }
    photos.take()
    await waitUntil { model.pages.count == 1 }
    photos.take()
    await waitUntil { model.guide.contains("bottom") }
    model.handle(.finish)
    XCTAssertEqual(model.phase, .seeking)
    XCTAssertTrue(voice.messages.last?.contains("solves anyway") == true, "\(voice.messages)")
    model.handle(.finish)
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(saver.frameCounts, [1, 1])
  }
  func testWithoutChecksEachButtonPhotoIsItsOwnPage() async throws {
    let (model, photos, _, _) = photoModel()
    model.checkPages = false
    model.start()
    await waitUntil { model.phase == .seeking }
    photos.take(); photos.take(); photos.take()
    await waitUntil { model.pages.count == 3 }
    XCTAssertEqual(model.pages.map(\.frames.count), [1, 1, 1])
  }
  func testAContinuedScanNeverUsesAPhotoTwice() async throws {
    let checker = FakePageChecker()
    let (model, photos, _, _) = photoModel(checker)
    model.start()
    await waitUntil { model.phase == .seeking }
    photos.take("a")
    await waitUntil { model.pages.count == 1 }
    model.pause()
    model.start()
    await waitUntil { model.phase == .seeking && photos.starts == 2 }
    XCTAssertLessThanOrEqual(try XCTUnwrap(photos.since), Date().addingTimeInterval(-ButtonPhotos.lookback + 1))
    photos.take("a") // the library shows it again: already on page 1
    photos.take("b")
    await waitUntil { model.pages.count == 2 }
    let counts = await checker.photoCounts
    XCTAssertEqual(counts, [1, 1])
  }
  func testARetakeDuringAPhotoCheckGoesOnWithTheWaitingPhotos() async throws {
    let checker = FakePageChecker(delay: .milliseconds(400))
    let (model, photos, _, _) = photoModel(checker)
    model.start()
    await waitUntil { model.phase == .seeking }
    photos.take()
    await waitUntil { model.pages.count == 1 }
    let first = try XCTUnwrap(model.pages.first?.id)
    photos.take() // page 2, being checked
    await waitUntil { model.guide.hasPrefix("Checking page 2") }
    photos.take() // waits for that check
    model.handle(.previous) // retake page 1: page 2's check is dropped, the waiting photo goes on
    await waitUntil { model.pages.count == 1 && model.pages.first?.id != first }
    XCTAssertNotEqual(model.pages.first?.id, first, "The waiting photo replaced page 1 instead of stalling.")
    let references = await checker.references
    XCTAssertEqual(references.last, true, "The retake is compared with page 1's earlier photo.")
  }
  func testANewPacketNeverReusesTheLastPacketsPhotos() async throws {
    let analyzer = FakePageAnalyzer(sample: goodSample())
    await analyzer.setPhotoGesture(.thumbsUp, for: "done")
    let (model, photos, _, _) = photoModel(analyzer: analyzer)
    model.start()
    await waitUntil { model.phase == .seeking }
    photos.take("p1")
    await waitUntil { model.pages.count == 1 }
    photos.take("done")
    await waitUntil { model.phase == .finished }
    model.start() // a new packet looks back 30 s, so the library shows the last packet's photos again
    await waitUntil { model.phase == .seeking && photos.starts == 2 }
    XCTAssertTrue(model.pages.isEmpty)
    photos.take("p1"); photos.take("done"); photos.take("q1")
    await waitUntil { model.pages.count == 1 }
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(model.phase, .seeking, "The last packet's thumbs-up photo doesn't finish the new one.")
    XCTAssertEqual(model.pages.count, 1)
  }
  func testPhotosNeedFullAccess() async throws {
    let (model, photos, _, _) = photoModel()
    photos.error = PhotoSourceError.limitedAccess
    model.start()
    await waitUntil { model.phase == .failed }
    XCTAssertTrue(model.needsPhotoAccess)
    XCTAssertTrue(model.guide.contains("Full Access"), model.guide)
  }
  func testAnUnreadableButtonPhotoPageIsMarkedForReviewInsteadOfACameraRetake() async throws {
    let (model, photos, _, saver) = photoModel(solver: FakePageSolver(unreadableOnceOnPage: 1))
    model.start()
    await waitUntil { model.phase == .seeking }
    photos.take()
    await waitUntil { model.pages.count == 1 }
    photos.take()
    await waitUntil { model.pages.count == 2 }
    model.finishScanning()
    await waitUntil { model.phase == .finished }
    XCTAssertTrue(saver.lastPage?.problems.contains { $0.problem.contains("could not be read") } == true)
    XCTAssertTrue(model.guide.contains("Left out unreadable: Page 1"), model.guide)
  }
  func testSolutionFoldersAreNamedByDateAndTitle() {
    let date = Date(timeIntervalSince1970: 1_792_000_000), utc = TimeZone(identifier: "UTC")!
    XCTAssertEqual(SolutionFolder.name(title: "Physics: HW 3/4\nForces.", date: date, timeZone: utc),
      "2026-10-14 17.46 Physics HW 3 4 Forces")
    XCTAssertEqual(SolutionFolder.name(title: "  ", date: date, timeZone: utc), "2026-10-14 17.46")
    XCTAssertEqual(SolutionFolder.unique("A", existing: ["A", "A 2"]), "A 3")
    XCTAssertEqual(SolutionFolder.unique("B", existing: ["A"]), "B")
    XCTAssertEqual(SolutionFolder.photoName(page: 2, photo: 1, of: 1), "Page 2.jpg")
    XCTAssertEqual(SolutionFolder.photoName(page: 2, photo: 3, of: 3), "Page 2 (3).jpg")
  }

  private func temporaryDraft() -> ScanDraftStore {
    ScanDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID())"))
  }
  /// Still-photo capture unless `capture` says otherwise; most flows predate live frames and still apply to stills.
  /// Older flows solve while scanning, as 2.3 and earlier did by default; 2.4 solves after the thumbs-up.
  private func makeModel(_ camera: FakeScanCamera, _ analyzer: FakePageAnalyzer, _ solver: FakePageSolver, _ saver: FakeSolutionSaver,
                         capture: AutoScanModel.CaptureMode = .photos, voice: FakeScanVoice? = nil,
                         checker: FakePageChecker = FakePageChecker(), solveWhileScanning: Bool = true,
                         photos: FakePhotoSource = FakePhotoSource()) -> AutoScanModel {
    let model = AutoScanModel(camera: camera, analyzer: analyzer, solver: solver, checker: checker, saver: saver,
      draft: temporaryDraft(), voice: voice ?? FakeScanVoice(), photos: photos,
      configurationProvider: { SolverConfiguration(openAIKey: "test-key-never-sent", openAIModel: "gpt-4.1") })
    model.voiceGuidance = voice != nil; model.captureMode = capture; model.solveWhileScanning = solveWhileScanning
    return model
  }
  /// A steady, close-up preview frame: text 30 px tall in a 1280-px frame.
  private func frameSample() -> PageSample {
    var sample = goodSample(); sample.linePixels = 30; sample.frameHeight = 1280; return sample
  }
  private func text(_ lines: [String]) -> FrameText {
    FrameText(lines: lines.enumerated().map { index, line in
      ReadLine(text: line, confidence: 1, box: CGRect(x: 0.1, y: 0.8 - Double(index) * 0.1, width: 0.8, height: 0.05))
    })
  }
  private let viewA = ["1. Solve for x in 2x + 3 = 11", "2. Find the slope of the line", "Show all of your work clearly"]
  private let viewB = ["3. Factor x squared minus nine", "4. Graph y equals two x plus one", "Use the grid provided below"]
  /// The lower part of the sheet: no question number in view.
  private let rest = ["through the points (1, 2) and (3, 8)", "then write its equation in slope form", "Label both of the axes"]
  private let viewC = ["4. Compute the integral of cosine", "5. Find the area of the circle", "Express each answer exactly"]
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
  var buttonsAvailable = true
  let data: Data
  var captures = 0, resumes = 0, starts = 0, shutters = 0, stops = 0
  /// Runs while the model is in `.capturing`, e.g. to send a command mid-capture.
  var captureHook: (() -> Void)?
  init(data: Data) { self.data = data }
  func start() async throws { starts += 1 }
  func resumePreview() async throws { resumes += 1 }
  func capture() async throws -> Data { captures += 1; shutters += 1; onShutter?(); captureHook?(); return data }
  func stop() { stops += 1 }
}
private actor FakePageAnalyzer: PageAnalyzing {
  var sample: PageSample
  var rejectFirstStill: Bool
  var text = FrameText()
  private(set) var reads = 0
  func setText(_ value: FrameText) { text = value }
  func readText(_ image: CGImage) async throws -> FrameText { reads += 1; return text }
  init(sample: PageSample, rejectFirstStill: Bool = false) { self.sample = sample; self.rejectFirstStill = rejectFirstStill }
  func setGesture(_ gesture: HandGesture?) { sample.gesture = gesture }
  /// Text this many pixels tall: a closer look than `frameSample()`'s 30 px.
  func setLinePixels(_ value: Double) { sample.linePixels = value }
  func rejectNextStill() { rejectFirstStill = true }
  /// Different writing in view: a new page for the page-turn gate.
  func setContent(_ value: Double) {
    sample.contentFingerprint = Array(repeating: value, count: 256); sample.fingerprint = Array(repeating: value, count: 256)
  }
  func analyze(_ image: CGImage, still: Bool) async throws -> PageSample { sample }
  /// Hand commands in button photos, by photo id (`FakePhotoSource` photos hold "jpeg-<id>").
  private var photoGestures: [String: HandGesture] = [:]
  func setPhotoGesture(_ gesture: HandGesture, for id: String) { photoGestures["jpeg-" + id] = gesture }
  func photoGesture(_ jpeg: Data) async -> HandGesture? { photoGestures[String(decoding: jpeg, as: UTF8.self)] }
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
  let orphanOnPage: Int?
  let unreadableOnceOnPage: Int?
  private(set) var calls = 0
  private(set) var jobs: [PageJob] = []
  private var failedOnce = false
  init(delay: Bool = false, failure: (any Error)? = nil, failFirstAttemptOfPage: Int? = nil, orphanOnPage: Int? = nil,
       unreadableOnceOnPage: Int? = nil) {
    self.delay = delay; self.failure = failure; self.failFirstAttemptOfPage = failFirstAttemptOfPage; self.orphanOnPage = orphanOnPage
    self.unreadableOnceOnPage = unreadableOnceOnPage
  }
  func solve(_ job: PageJob, configuration: SolverConfiguration,
             progress: @escaping @Sendable (String) -> Void) async throws -> PageResult {
    calls += 1; jobs.append(job)
    if delay { try? await Task.sleep(for: .milliseconds(500)) }
    if let failure { throw failure }
    if job.number == failFirstAttemptOfPage && !failedOnce {
      failedOnce = true; throw SolverError.message("Page \(job.number): service unavailable.")
    }
    if job.number == unreadableOnceOnPage && !failedOnce {
      failedOnce = true; throw AIResultError.unreadable("Page \(job.number): the bottom line is cut off.")
    }
    let item = PageSolutionItem(label: "1(a) p\(job.number)", problem: "2x + 3 = 11 on page \(job.number)",
      steps: ["Subtract 3.", "Divide by 2."], answer: "x = 4", check: "2 × 4 + 3 = 11", status: "solved",
      reviewNote: "", sourcePages: [job.number])
    if job.number == orphanOnPage {
      // The page wrongly skips 5(b) as belonging to the previous page, unless it is told to solve it.
      let claimed = PageSolutionItem(label: "5(b)", problem: "Speed after 3 m", steps: ["Use energy."], answer: "v = 5 m/s",
        check: "Units m/s", status: "solved", reviewNote: "", sourcePages: [job.number - 1, job.number])
      return job.mustSolve.isEmpty
        ? PageResult(readable: true, retake: "", title: "Linear equation", checklist: [item.label, "5(b)"], solutions: [item],
            skipped: [SkippedItem(label: "5(b)", reason: "question 5 began on the previous page")])
        : PageResult(readable: true, retake: "", title: "Linear equation", checklist: [item.label, "5(b)"], solutions: [item, claimed], skipped: [])
    }
    return PageResult(readable: true, retake: "", title: "Linear equation", checklist: [item.label], solutions: [item], skipped: [])
  }
  func forget(keeping urls: Set<URL>) {}
}
/// Answers checks in order from `verdicts`, then says every page is clear.
private actor FakePageChecker: PageChecking {
  private var verdicts: [Result<PageVerdict, any Error>]
  private(set) var photoCounts: [Int] = []
  /// Whether each check got an earlier photo of the page being retaken, and a photo of the page before.
  private(set) var references: [Bool] = []
  private(set) var earlier: [Bool] = []
  private let delay: Duration?
  init(_ verdicts: [Result<PageVerdict, any Error>] = [], delay: Duration? = nil) { self.verdicts = verdicts; self.delay = delay }
  func check(_ photos: [Data], page: Int, context: PageCheckContext, configuration: SolverConfiguration) async throws -> PageVerdict {
    photoCounts.append(photos.count); references.append(context.reference != nil); earlier.append(context.earlier != nil)
    if let delay { try await Task.sleep(for: delay) }
    return verdicts.isEmpty ? .clear : try verdicts.removeFirst().get()
  }
}
private extension PageVerdict {
  static let clear = PageVerdict(clear: true, say: "", dropped: [])
  static func unclear(_ say: String) -> PageVerdict { PageVerdict(clear: false, say: say, dropped: []) }
}

/// The photo library as the glasses' photos reach it: `take` delivers a new photo now.
@MainActor
private final class FakePhotoSource: PhotoSource {
  private var onPhoto: (@MainActor (IncomingPhoto) -> Void)?
  var error: (any Error)?
  private(set) var since: Date?
  private(set) var starts = 0, stops = 0
  private var count = 0
  func start(since: Date, onPhoto: @escaping @MainActor (IncomingPhoto) -> Void) async throws {
    starts += 1
    if let error { throw error }
    self.since = since; self.onPhoto = onPhoto
  }
  func stop() { stops += 1; onPhoto = nil }
  func catchUp() {}
  func take(_ name: String? = nil) {
    count += 1
    let id = name ?? "photo-\(count)"
    onPhoto?(IncomingPhoto(id: id, jpeg: Data("jpeg-\(id)".utf8), taken: Date(), arrived: Date()))
  }
}

@MainActor
private final class FakeSolutionSaver: SolutionSaving {
  var saves = 0
  var sourceCount = 0
  var lastPage: SolvedPage?
  var frameCounts: [Int] = []
  var names: [String] = []
  func save(page: SolvedPage, sources: [[URL]], names: [String]) async throws -> SavedSolution {
    saves += 1; sourceCount = sources.count; frameCounts = sources.map(\.count); lastPage = page; self.names = names
    return SavedSolution(id: UUID(), title: page.title, date: Date(), pdf: URL(fileURLWithPath: "/tmp/test.pdf"), source: URL(fileURLWithPath: "/tmp/test.jpg"))
  }
}

@MainActor
private final class FakeScanVoice: ScanSpeaking {
  var onCommand: ((ScanCommand) -> Void)?
  var onStatus: ((String) -> Void)?
  var privateOnly = true
  var routeIsPrivate = true
  var startHook: (() async -> Void)?
  var startReturned = false
  var messages: [String] = []
  func prepareOutput() {}
  func startCommands() async { await startHook?(); startReturned = true }
  func stopCommands() {}
  func say(_ message: String, volume: Float) { messages.append(message) }
  func stopSpeaking() {}
}
