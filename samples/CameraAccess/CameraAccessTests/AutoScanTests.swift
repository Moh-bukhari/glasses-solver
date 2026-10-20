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
  func testHTTPIncompleteRefusalAndInvalidResultDoNotProduceSolutions() throws {
    XCTAssertThrowsError(try SolverClient.payload(data: Data(), status: 401, provider: .openAI))
    let incomplete = Data(#"{"status":"incomplete","output":[]}"#.utf8)
    XCTAssertThrowsError(try SolverClient.payload(data: incomplete, status: 200, provider: .openAI))
    let refusal = Data(#"{"status":"completed","output":[{"content":[{"type":"refusal","refusal":"no"}]}]}"#.utf8)
    XCTAssertThrowsError(try SolverClient.payload(data: refusal, status: 200, provider: .openAI))
    let malformed = Data(#"{"status":"completed","output":[]}"#.utf8)
    XCTAssertThrowsError(try SolverClient.payload(data: malformed, status: 200, provider: .openAI))
  }
  func testStructuredSolutionAndReadabilityAreDecoded() throws {
    let page = solvedPage()
    let result = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["content": [["type": "output_text", "text": String(decoding: try JSONEncoder().encode(page), as: UTF8.self)]]]]])
    let decoded = try JSONDecoder().decode(SolvedPage.self, from: SolverClient.payload(data: result, status: 200, provider: .openAI))
    XCTAssertTrue(decoded.readable)
    XCTAssertEqual(decoded.problems.first?.answer, "x = 4")
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
    let solver = FakePageSolver(page: solvedPage())
    let saver = FakeSolutionSaver()
    let model = makeModel(camera, analyzer, solver, saver)
    model.start()
    await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    model.finishScanning()
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(model.phase, .finished, model.guide)
    XCTAssertTrue(model.showPDF)
    XCTAssertEqual(camera.captures, 1)
    XCTAssertEqual(saver.saves, 1)
    let count = await solver.calls
    XCTAssertEqual(count, 1)
    for _ in 0..<20 { camera.onFrame?(paperImage().cgImage!) }
    XCTAssertEqual(camera.captures, 1)
    model.stop()
  }
  func testNoDetectedTextOutlineStillCompletesHandsFree() async throws {
    let camera = FakeScanCamera(data: problemImage().jpegData(compressionQuality: 0.95)!)
    var sample = goodSample(); sample.contentBounds = nil; sample.cue = .findProblem
    let solver = FakePageSolver(page: solvedPage()), saver = FakeSolutionSaver()
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
  func testPoorStillIsKeptAndWaitsForFinish() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: goodSample(), rejectFirstStill: true)
    let solver = FakePageSolver(page: solvedPage()), saver = FakeSolutionSaver()
    let model = makeModel(camera, analyzer, solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    let calls = await solver.calls
    XCTAssertEqual(calls, 0); XCTAssertEqual(model.pages.count, 1)
    model.finishScanning(); await waitUntil { model.phase == .finished }
    XCTAssertEqual(camera.captures, 1); XCTAssertEqual(saver.saves, 1)
    model.stop()
  }
  func testMixedImportKeepsPoorPhotosAndContinuesAfterAnInvalidFile() async {
    let bytes = paperImage().jpegData(compressionQuality: 0.9)!
    let camera = FakeScanCamera(data: bytes), solver = FakePageSolver(page: solvedPage()), saver = FakeSolutionSaver()
    var poor = goodSample(); poor.issue = "blur"; poor.closeEnough = false
    let model = makeModel(camera, FakePageAnalyzer(sample: poor), solver, saver)
    model.importPhotos(count: 3) { index in
      if index == 1 { throw SolverError.message("Unavailable library file") }
      return bytes
    }
    await waitUntil { model.phase == .idle && model.pages.count == 2 }
    XCTAssertEqual(model.pages.count, 2); XCTAssertTrue(model.guide.contains("2"))
    let before = await solver.calls; XCTAssertEqual(before, 0)
    model.finishScanning(); await waitUntil { model.phase == .finished }
    XCTAssertEqual(saver.sourceCount, 2); XCTAssertEqual(saver.saves, 1)
    model.stop()
  }
  func testManualCaptureBypassesFramingAndKeepsUnreadableView() async {
    let bytes = paperImage().jpegData(compressionQuality: 0.9)!
    let camera = FakeScanCamera(data: bytes), solver = FakePageSolver(page: solvedPage()), saver = FakeSolutionSaver()
    var poor = goodSample(); poor.issue = "Too far away"; poor.closeEnough = false
    let model = makeModel(camera, FakePageAnalyzer(sample: poor), solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    model.captureNow(); await waitUntil { model.phase == .awaitingNext }
    XCTAssertEqual(camera.captures, 1); XCTAssertEqual(model.pages.count, 1)
    model.stop()
  }
  func testCancellingAnImportPreventsLatePhotoSaving() async {
    let bytes = paperImage().jpegData(compressionQuality: 0.9)!
    let camera = FakeScanCamera(data: bytes), solver = FakePageSolver(page: solvedPage()), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    var loaded: CheckedContinuation<Data, Never>?
    model.importPhotos(count: 1) { _ in await withCheckedContinuation { loaded = $0 } }
    await waitUntil { loaded != nil }
    model.stop(); loaded?.resume(returning: bytes)
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(model.pages.isEmpty); XCTAssertEqual(model.phase, .idle)
  }
  func testReviewResultsCanBeSavedWithoutGlobalReadableFlag() async {
    let bytes = paperImage().jpegData(compressionQuality: 0.9)!
    let camera = FakeScanCamera(data: bytes), saver = FakeSolutionSaver()
    let page = SolvedPage(readable: false, retakeReason: "", title: "Packet", problems: [
      SolvedProblem(problem: "Unknown coefficient", steps: [], answer: "Insufficient information", check: "Unresolved",
        label: "2(b)", reviewNote: "NEEDS REVIEW: coefficient unreadable")])
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), FakePageSolver(page: page), saver)
    model.importPhoto(bytes); await waitUntil { model.pages.count == 1 }
    model.finishScanning(); await waitUntil { model.phase == .finished }
    XCTAssertEqual(saver.saves, 1); XCTAssertTrue(model.showPDF)
    model.stop()
  }
  func testEmptySolverResponseKeepsAllPhotosWithoutExport() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let page = SolvedPage(readable: false, retakeReason: "Page 1: exponent unclear.", title: "", problems: [])
    let solver = FakePageSolver(page: page), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    model.importPhoto(camera.data); await waitUntil { model.pages.count == 1 }
    model.finishScanning(); await waitUntil { model.phase == .failed }
    let calls = await solver.calls
    XCTAssertEqual(calls, 1); XCTAssertEqual(model.pages.count, 1)
    XCTAssertEqual(saver.saves, 0); XCTAssertFalse(model.showPDF)
    model.stop()
  }
  func testGlassesDisconnectAfterPhotoDoesNotDiscardSolution() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(page: solvedPage(), delay: true)
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
    let solver = FakePageSolver(page: solvedPage(), delay: true)
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
    camera.onFrame = { _ in receivedFrame = true }
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
    let solver = FakePageSolver(page: solvedPage())
    let model = AutoScanModel(camera: camera, analyzer: FakePageAnalyzer(sample: goodSample()), solver: solver,
      draft: temporaryDraft(), voice: FakeScanVoice(), configurationProvider: { SolverConfiguration() })
    model.voiceGuidance = false; model.importPhoto(camera.data)
    await waitUntil { model.pages.count == 1 }
    model.finishScanning()
    XCTAssertTrue(model.needsKey); XCTAssertEqual(camera.starts, 0)
    let calls = await solver.calls; XCTAssertEqual(calls, 0)
    model.stop()
  }

  func testStableDistantAndBlurryViewsCanStillBeCollected() {
    for issue in [String?.none, "Blurred"] {
      var gate = StabilityGate(), sample = goodSample()
      sample.closeEnough = false; sample.cue = .closer; sample.issue = issue
      for n in 0...10 { _ = gate.observe(sample, at: Double(n) * 0.35) }
      XCTAssertTrue(gate.latched, "Quality is advice; overlapping views may recover the details.")
    }
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
      solver: FakePageSolver(page: solvedPage()), saver: FakeSolutionSaver(), draft: temporaryDraft(), voice: voice)
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
      solver: FakePageSolver(page: solvedPage()), saver: FakeSolutionSaver(), draft: temporaryDraft(), voice: voice)
    model.start(); await waitUntil { ready != nil }
    model.stop(); ready?.resume()
    await waitUntil { voice.startReturned }
    XCTAssertEqual(model.phase, .idle); XCTAssertEqual(camera.starts, 0)
    XCTAssertTrue(voice.messages.isEmpty)
  }
  func testTwoPagesWaitForFinishAndDuplicateFramesDoNotUpload() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(page: solvedPage()), saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .awaitingNext }
    for _ in 0..<12 { camera.onFrame?(paperImage().cgImage!) }
    var calls = await solver.calls
    XCTAssertEqual(calls, 0); XCTAssertEqual(model.pages.count, 1); XCTAssertEqual(camera.captures, 1)
    model.handle(.next)
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.pages.count == 2 && model.phase == .awaitingNext }
    calls = await solver.calls; XCTAssertEqual(calls, 0)
    model.handle(.finish); await waitUntil { model.phase == .finished }
    calls = await solver.calls
    XCTAssertEqual(calls, 1); XCTAssertEqual(saver.saves, 1); XCTAssertEqual(saver.sourceCount, 2)
    XCTAssertTrue(model.showPDF); model.stop()
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
  func testProviderRequestsUseSeparateCredentialsAndCorrectImageFormats() throws {
    let photo = AIPhoto(number: 2, jpeg: Data([1, 2, 3]))
    for provider in AIProvider.allCases {
      let credential = AICredential(provider: provider, key: provider == .claude ? "claude-secret-fixture" : "openai-secret-fixture", model: "test-model")
      let request = try SolverClient.request(AIRequest(credential: credential, photos: [photo], prompt: "Solve", shape: .answers, tokenLimit: 16000))
      let data = try XCTUnwrap(request.httpBody), body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let text = String(decoding: data, as: UTF8.self)
      XCTAssertFalse(text.contains("secret-fixture"))
      if provider == .claude {
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), credential.key)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNotNil(body["output_config"]); XCTAssertTrue(text.contains("media_type"))
      } else {
        XCTAssertEqual(request.url?.host, "api.openai.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + credential.key)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(body["store"] as? Bool, false); XCTAssertNotNil(body["text"])
        XCTAssertTrue(text.contains("input_image"))
      }
    }
  }
  func testClaudeEnvelopeRejectsTruncationRefusalAndEmptyText() throws {
    let result = Data(#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"not a solution"},{"type":"text","text":"{\"answers\":[]}"}]}"#.utf8)
    XCTAssertEqual(String(decoding: try SolverClient.payload(data: result, status: 200, provider: .claude), as: UTF8.self), #"{"answers":[]}"#)
    for reason in ["max_tokens", "refusal"] {
      let data = try JSONSerialization.data(withJSONObject: ["stop_reason": reason, "content": []])
      XCTAssertThrowsError(try SolverClient.payload(data: data, status: 200, provider: .claude))
    }
    XCTAssertThrowsError(try SolverClient.payload(data: Data(#"{"stop_reason":"end_turn","content":[]}"#.utf8), status: 200, provider: .claude))
  }
  func testInventoryRejectsOmittedPagesAndAnswerCoverageRejectsMissingParts() throws {
    let item = InventoriedQuestion(id: "q1", label: "1(a)", sourcePages: [1], problem: "Solve x")
    let inventory = QuestionInventory(title: "Test", pages: [PageReading(page: 1, readable: true, issue: "")], questions: [item])
    XCTAssertThrowsError(try inventory.validate(pageCount: 2))
    let answer = WorkedAnswer(id: "q1", steps: ["Work"], answer: "1", check: "Checked", status: "solved", reviewNote: "")
    XCTAssertThrowsError(try AnswerSet(answers: [answer]).validate(ids: ["q1", "q2"]))
    XCTAssertThrowsError(try AnswerSet(answers: [answer, answer]).validate(ids: ["q1", "q2"]))
    let empty = WorkedAnswer(id: "q1", steps: [" "], answer: " ", check: " ", status: "solved", reviewNote: "")
    XCTAssertThrowsError(try AnswerSet(answers: [empty]).validate(ids: ["q1"]))
  }
  func testLegacyBothModeUsesClaudeAndRepairsOneMissingAnswer() async throws {
    let transport = FixtureAITransport(behavior: .missingOnce)
    let solver = BatchSolver(transport: transport), photo = paperImage().jpegData(compressionQuality: 0.9)!
    let config = SolverConfiguration(mode: .both, openAIKey: "fixture-openai", claudeKey: "fixture-claude")
    let result = try await solver.solve(pages: [photo, photo], configuration: config, progress: { _ in })
    XCTAssertEqual(result.problems.count, 2)
    XCTAssertEqual(result.problems.last?.label, "1(b)")
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 3, "One inventory, one concise solve, one structural repair")
    XCTAssertTrue(requests.allSatisfy { $0.credential.provider == .claude })
    XCTAssertTrue(requests.contains { $0.prompt.contains("REPAIR REQUIRED:") })
    XCTAssertTrue(requests.allSatisfy { $0.photos.count == 2 })
  }
  func testIncompleteResultsHaveOneRepairAndNetworkErrorsHaveNone() async throws {
    let photo = paperImage().jpegData(compressionQuality: 0.9)!
    for behavior in [FixtureAITransport.Behavior.emptyAlways, .networkFailure] {
      let transport = FixtureAITransport(behavior: behavior)
      do {
        _ = try await BatchSolver(transport: transport).solve(pages: [photo], configuration: SolverConfiguration(claudeKey: "fixture"), progress: { _ in })
        XCTFail("An incomplete/error result must not become a solution")
      } catch {}
      let requests = await transport.requests
      XCTAssertEqual(requests.count, behavior == .emptyAlways ? 3 : 1)
    }
  }
  func testClaudeOnlyDoesNotUseOpenAIKey() async throws {
    let transport = FixtureAITransport(behavior: .valid)
    let result = try await BatchSolver(transport: transport).solve(pages: [paperImage().jpegData(compressionQuality: 0.9)!],
      configuration: SolverConfiguration(mode: .claude, openAIKey: "must-not-send", claudeKey: "claude-only"), progress: { _ in })
    XCTAssertEqual(result.problems.count, 2)
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests.allSatisfy { $0.credential.provider == .claude && $0.credential.key == "claude-only" })
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

  func testReferencePDFLoadsOnePhotoAtATimeAndPropagatesDecodeFailure() throws {
    var loaded: [Int] = []
    weak var previous: UIImage?
    let data = try SolutionPDF.render(page: solvedPage(), sourceCount: 3) { index in
      XCTAssertNil(previous, "Release the previous source UIImage before decoding the next.")
      loaded.append(index)
      let image = self.paperImage(); previous = image
      return image
    }
    XCTAssertEqual(loaded, [0, 1, 2]); XCTAssertNil(previous)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(PDFDocument(data: data)).pageCount, 4)
    XCTAssertThrowsError(try SolutionPDF.render(page: solvedPage(), sourceCount: 1) { _ in
      throw SolverError.message("File cannot be decoded")
    })
  }

  func testSavedCalculatorPackAndPreviewsRestoreFromHistory() throws {
    let bytes = paperImage().jpegData(compressionQuality: 0.9)!
    let page = SolvedPage(readable: true, retakeReason: "", title: "Saved calculator pack", problems: [
      SolvedProblem(problem: "Solve 2x = 8", steps: ["2x = 8", "x = 8/2"], answer: "x = 4", check: "2(4) = 8", label: "1(a)"),
      SolvedProblem(problem: "Missing value", steps: [], answer: "Insufficient information", check: "Not inferred", label: "1(b)",
        reviewNote: "NEEDS REVIEW: coefficient missing")])
    let saved = try SolutionStore().save(page: page, jpegs: [bytes])
    defer { try? FileManager.default.removeItem(at: saved.pdf.deletingLastPathComponent()) }
    let archive = try XCTUnwrap(saved.calculatorArchive)
    XCTAssertEqual(try Data(contentsOf: archive).prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
    XCTAssertGreaterThanOrEqual(saved.calculatorImages.count, 2)
    for preview in saved.calculatorImages {
      let image = try XCTUnwrap(UIImage(contentsOfFile: preview.path)?.cgImage)
      XCTAssertEqual(image.width, 384); XCTAssertEqual(image.height, 192)
      XCTAssertTrue(FileManager.default.fileExists(atPath: preview.deletingPathExtension().appendingPathExtension("g3p").path))
    }
    let restored = try XCTUnwrap(SolutionStore.history().first { $0.id == saved.id })
    XCTAssertEqual(restored.calculatorArchive, archive)
    XCTAssertEqual(restored.calculatorImages, saved.calculatorImages)
    XCTAssertNotNil(PDFDocument(url: saved.pdf))
  }

  private func temporaryDraft() -> ScanDraftStore {
    ScanDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID())"))
  }
  private func makeModel(_ camera: FakeScanCamera, _ analyzer: FakePageAnalyzer, _ solver: FakePageSolver, _ saver: FakeSolutionSaver) -> AutoScanModel {
    let model = AutoScanModel(camera: camera, analyzer: analyzer, solver: solver, saver: saver,
      draft: temporaryDraft(), voice: FakeScanVoice(),
      configurationProvider: { SolverConfiguration(claudeKey: "test-key-never-sent") })
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
  let data: Data
  var captures = 0, resumes = 0, starts = 0
  init(data: Data) { self.data = data }
  func start() async throws { starts += 1 }
  func resumePreview() async throws { resumes += 1 }
  func capture() async throws -> Data { captures += 1; return data }
  func stop() {}
}
private actor FakePageAnalyzer: PageAnalyzing {
  let sample: PageSample
  var rejectFirstStill: Bool
  init(sample: PageSample, rejectFirstStill: Bool = false) { self.sample = sample; self.rejectFirstStill = rejectFirstStill }
  func analyze(_ image: CGImage, still: Bool) async throws -> PageSample { sample }
  func prepare(_ data: Data) async throws -> PreparedPhoto {
    var value = sample
    if rejectFirstStill { value.issue = "Hold still; blurry photo."; rejectFirstStill = false }
    return PreparedPhoto(jpeg: data, sample: value, width: 1200, height: 1600)
  }
}
private actor FakePageSolver: BatchSolving {
  let page: SolvedPage
  let delay: Bool
  private(set) var calls = 0
  init(page: SolvedPage, delay: Bool = false) { self.page = page; self.delay = delay }
  func solve(pages: [Data], configuration: SolverConfiguration, progress: @escaping @Sendable (String) -> Void) async throws -> SolvedPage {
    calls += 1
    if delay { try? await Task.sleep(for: .milliseconds(500)) }
    return page
  }
}
@MainActor
private final class FakeSolutionSaver: SolutionSaving {
  var saves = 0
  var sourceCount = 0
  func save(page: SolvedPage, jpegs: [Data]) throws -> SavedSolution {
    saves += 1; sourceCount = jpegs.count
    return SavedSolution(id: UUID(), title: page.title, date: Date(), pdf: URL(fileURLWithPath: "/tmp/test.pdf"), source: URL(fileURLWithPath: "/tmp/test.jpg"))
  }
}

@MainActor
private final class FakeScanVoice: ScanSpeaking {
  var onCommand: ((ScanCommand) -> Void)?
  var onStatus: ((String) -> Void)?
  var startHook: (() async -> Void)?
  var startReturned = false
  var messages: [String] = []
  func startCommands() async { await startHook?(); startReturned = true }
  func stopCommands() {}
  func say(_ message: String, volume: Float) { messages.append(message) }
  func stopSpeaking() {}
}

private actor FixtureAITransport: AITransport {
  enum Behavior: Sendable { case valid, missingOnce, emptyAlways, networkFailure }
  let behavior: Behavior
  private(set) var requests: [AIRequest] = []
  private var missed = false
  init(behavior: Behavior) { self.behavior = behavior }
  func send(_ input: AIRequest) async throws -> Data {
    requests.append(input)
    if behavior == .networkFailure { throw URLError(.timedOut) }
    if case .inventory = input.shape {
      let inventory = QuestionInventory(title: "Fixture packet", pages: input.photos.map { PageReading(page: $0.number, readable: true, issue: "") }, questions: [
        InventoriedQuestion(id: "q1", label: "1(a)", sourcePages: [1], problem: "Solve 2x = 8"),
        InventoriedQuestion(id: "q2", label: "1(b)", sourcePages: [input.photos.count], problem: "Solve 3y = 9")])
      return try JSONEncoder().encode(inventory)
    }
    if behavior == .emptyAlways { return Data(#"{"answers":[]}"#.utf8) }
    var answers = [
      WorkedAnswer(id: "q1", steps: ["Divide by 2"], answer: "x = 4", check: "2 × 4 = 8", status: "solved", reviewNote: ""),
      WorkedAnswer(id: "q2", steps: ["Divide by 3"], answer: "y = 3", check: "3 × 3 = 9", status: "solved", reviewNote: "")]
    if behavior == .missingOnce && !missed && input.credential.provider == .claude {
      answers.removeLast(); missed = true
    }
    return try JSONEncoder().encode(AnswerSet(answers: answers))
  }
}
