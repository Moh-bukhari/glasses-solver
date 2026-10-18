@testable import CameraAccess
import XCTest
import UIKit
import PDFKit
import CoreImage

@MainActor
final class AutoScanTests: XCTestCase {
  func goodSample(shift: Double = 0) -> PageSample {
    PageSample(corners: [PagePoint(x: 0.2 + shift, y: 0.8), PagePoint(x: 0.8 + shift, y: 0.8),
      PagePoint(x: 0.8 + shift, y: 0.2), PagePoint(x: 0.2 + shift, y: 0.2)],
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
    XCTAssertEqual(gate.observe(goodSample(shift: 0.04), at: 0.8), 0)
    XCTAssertEqual(gate.observe(PageSample(issue: "blur"), at: 1.1), 0)
    XCTAssertEqual(gate.observe(goodSample(), at: 1.4), 0)
    XCTAssertEqual(gate.observe(goodSample(), at: 3.4), 0)
    XCTAssertFalse(gate.latched)
  }
  func testSlowCumulativeDriftCannotTrigger() {
    var gate = StabilityGate()
    for n in 0..<20 { XCTAssertLessThan(gate.observe(goodSample(shift: Double(n) * 0.008), at: Double(n) * 0.3), 1) }
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
    let problem = SolvedProblem(problem: "Solve 2x + 3 = 11", steps: (1...180).map { "Step \($0): subtract three and divide by two. Check the equation carefully. This line must survive pagination." }, answer: "FINAL_SENTINEL x = 4", check: "2 × 4 + 3 = 11")
    let page = SolvedPage(readable: true, retakeReason: "", title: "Pagination test", problems: [problem])
    let data = try SolutionPDF.render(page: page, source: paperImage())
    let pdf = try XCTUnwrap(PDFDocument(data: data))
    XCTAssertGreaterThan(pdf.pageCount, 3)
    XCTAssertTrue(pdf.string?.contains("FINAL_SENTINEL") == true)
    XCTAssertTrue(pdf.string?.contains("Source photograph") == true)
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
  private func sendStableFrames(_ camera: FakeScanCamera, model: AutoScanModel) async throws {
    let image = paperImage().cgImage!
    for _ in 0..<8 {
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
