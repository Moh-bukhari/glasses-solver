@testable import CameraAccess
import XCTest
import UIKit
import PDFKit
import CoreImage
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
  }
  func testHTTPIncompleteRefusalAndInvalidResultDoNotProduceSolutions() throws {
    XCTAssertThrowsError(try SolverClient.decode(data: Data(), status: 401))
    let incomplete = Data(#"{"status":"incomplete","output":[]}"#.utf8)
    XCTAssertThrowsError(try SolverClient.decode(data: incomplete, status: 200))
    let refusal = Data(#"{"status":"completed","output":[{"content":[{"type":"refusal","refusal":"no"}]}]}"#.utf8)
    XCTAssertThrowsError(try SolverClient.decode(data: refusal, status: 200))
    let malformed = Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":"broken"}]}]}"#.utf8)
    XCTAssertThrowsError(try SolverClient.decode(data: malformed, status: 200))
  }
  func testStructuredSolutionAndReadabilityAreDecoded() throws {
    let page = solvedPage()
    let result = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["content": [["type": "output_text", "text": String(decoding: try JSONEncoder().encode(page), as: UTF8.self)]]]]])
    let decoded = try SolverClient.decode(data: result, status: 200)
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
    XCTAssertFalse(bad.acceptable)
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
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(model.phase, .finished, model.guide)
    XCTAssertEqual(camera.captures, 1); XCTAssertEqual(saver.saves, 1)
    XCTAssertTrue(model.showPDF); model.stop()
  }
  func testBadStillIsRetakenWithoutSendingToAI() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let analyzer = FakePageAnalyzer(sample: goodSample(), rejectFirstStill: true)
    let solver = FakePageSolver(page: solvedPage())
    let saver = FakeSolutionSaver()
    let model = makeModel(camera, analyzer, solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { camera.resumes == 1 && model.phase == .seeking }
    let calls = await solver.calls
    XCTAssertEqual(calls, 0)
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .finished }
    XCTAssertEqual(camera.captures, 2)
    XCTAssertEqual(saver.saves, 1)
    model.stop()
  }
  func testAIUnreadablePageStopsAfterTwoRequestsWithoutPDF() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let page = SolvedPage(readable: false, retakeReason: "The exponent is unclear.", title: "", problems: [])
    let solver = FakePageSolver(page: page)
    let saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    model.start(); await waitUntil { model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { camera.resumes == 1 && model.phase == .seeking }
    try await sendStableFrames(camera, model: model)
    await waitUntil { model.phase == .failed }
    let calls = await solver.calls
    XCTAssertEqual(calls, 2)
    XCTAssertEqual(saver.saves, 0)
    XCTAssertFalse(model.showPDF)
    XCTAssertEqual(model.phase, .failed)
    model.stop()
  }
  func testGlassesDisconnectAfterPhotoDoesNotDiscardSolution() async throws {
    let camera = FakeScanCamera(data: paperImage().jpegData(compressionQuality: 0.9)!)
    let solver = FakePageSolver(page: solvedPage(), delay: true)
    let saver = FakeSolutionSaver()
    let model = makeModel(camera, FakePageAnalyzer(sample: goodSample()), solver, saver)
    model.importPhoto(camera.data)
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
      await waitUntil { receivedFrame }
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
  func testMissingKeyDoesNotConnectOrUpload() {
    let camera = FakeScanCamera(data: Data())
    let model = AutoScanModel(camera: camera, keyProvider: { "" })
    model.voiceGuidance = false; model.start()
    XCTAssertTrue(model.needsKey); XCTAssertEqual(camera.starts, 0)
  }

  private func makeModel(_ camera: FakeScanCamera, _ analyzer: FakePageAnalyzer, _ solver: FakePageSolver, _ saver: FakeSolutionSaver) -> AutoScanModel {
    let model = AutoScanModel(camera: camera, analyzer: analyzer, solver: solver, saver: saver,
      keyProvider: { "test-key-never-sent" }, modelProvider: { "gpt-4.1" })
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
  private func waitUntil(_ predicate: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
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
private actor FakePageSolver: PageSolving {
  let page: SolvedPage
  let delay: Bool
  private(set) var calls = 0
  init(page: SolvedPage, delay: Bool = false) { self.page = page; self.delay = delay }
  func solve(jpeg: Data, key: String, model: String) async throws -> SolvedPage {
    calls += 1
    if delay { try? await Task.sleep(for: .milliseconds(500)) }
    return page
  }
}
@MainActor
private final class FakeSolutionSaver: SolutionSaving {
  var saves = 0
  func save(page: SolvedPage, jpeg: Data) throws -> SavedSolution {
    saves += 1
    return SavedSolution(id: UUID(), title: page.title, date: Date(), pdf: URL(fileURLWithPath: "/tmp/test.pdf"), source: URL(fileURLWithPath: "/tmp/test.jpg"))
  }
}
