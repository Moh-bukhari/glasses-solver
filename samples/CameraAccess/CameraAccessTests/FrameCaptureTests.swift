@testable import CameraAccess
import XCTest
import CoreGraphics

/// Live multi-frame capture: question labels, gap detection, and which preview frames a page keeps.
final class FrameCaptureTests: XCTestCase {
  private func sample(content: Double = 0.05, linePixels: Double = 30, sharpness: Double = 0.02) -> PageSample {
    PageSample(contentBounds: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), luminance: 0.8, contrast: 0.2,
      sharpness: sharpness, fingerprint: Array(repeating: content, count: 256), linePixels: linePixels, frameHeight: 1280)
  }
  private func text(_ lines: [String]) -> FrameText {
    FrameText(lines: lines.enumerated().map { index, line in
      ReadLine(text: line, confidence: 1, box: CGRect(x: 0.1, y: 0.8 - Double(index) * 0.1, width: 0.8, height: 0.05))
    })
  }

  func testQuestionLabelsAreReadFromLineStartsButNotFromMath() {
    let labels = ["1. Solve 2x + 3 = 11", "2) Find x", "(3) Graph it", "Q4 Simplify", "Question 5: Expand", "Problem 6. Factor",
      "Exercise 7", "#8 Prove", "Ex. 9 Show", "10: Evaluate"]
    XCTAssertEqual(labels.map(QuestionLabels.number(in:)), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    let notLabels = ["3x + 2 = 5", "2.5 cm", "10/19/2026", "1,000 people", "3:00 pm", "Name: ____", "x = 4", "a) first part", "200 points", "Page 2"]
    XCTAssertEqual(notLabels.compactMap(QuestionLabels.number(in:)), [], "Math, times, dates and sub-parts are not question numbers.")
    XCTAssertEqual(QuestionLabels.numbers(in: ["2. b", "Some text here", "2. again", "3. c"]), [2, 3], "Distinct, in reading order.")
  }

  func testProgressAnnouncesNewQuestionsAndEachShortGapOnce() {
    var progress = QuestionProgress()
    var found = progress.observe([1, 2])
    XCTAssertEqual(found.new, [1, 2]); XCTAssertEqual(found.missing, [])
    found = progress.observe([2, 4])
    XCTAssertEqual(found.new, [4]); XCTAssertEqual(found.missing, [3])
    found = progress.observe([5])
    XCTAssertEqual(found.missing, [], "A gap is reported once.")
    found = progress.observe([3])
    XCTAssertEqual(found.new, [3]); XCTAssertEqual(progress.missing, [])
    found = progress.observe([1, 20])
    XCTAssertEqual(found.missing, [], "A long jump is new numbering (another section), not missed questions.")
  }

  func testOnlySteadyCloseFramesWithoutAHandAreWorthReading() {
    var frames = PageFrames()
    XCTAssertFalse(frames.gate(sample())); XCTAssertFalse(frames.gate(sample()))
    XCTAssertTrue(frames.gate(sample()), "Three steady frames, about 0.4 s at 7 fps.")
    XCTAssertFalse(frames.gate(sample(content: 0.4)), "Head motion restarts the count.")
    var small = PageFrames()
    for _ in 0..<5 { XCTAssertFalse(small.gate(sample(linePixels: 12))) }
    XCTAssertFalse(small.isBigEnough(sample(linePixels: 12)), "12 px lines are too small to read reliably.")
    var hand = PageFrames(), raised = sample(); raised.gesture = .thumbsUp
    for _ in 0..<5 { XCTAssertFalse(hand.gate(raised)) }
    var figure = PageFrames(), noText = sample(); noText.contentBounds = nil
    let gated = (0..<6).map { _ in figure.gate(noText) }
    XCTAssertEqual(gated, [false, false, false, false, false, true], "A view without text (a figure) needs twice as long.")
  }

  func testEachViewKeepsItsClearestFrameAndNeverLosesAQuestion() {
    var frames = PageFrames()
    let top = text(["1. Solve for x in 2x + 3 = 11", "2. Find the slope of the line", "Show all of your work clearly"])
    let bottom = text(["3. Factor x squared minus nine", "4. Graph y equals two x plus one", "Use the grid provided below"])
    XCTAssertEqual(frames.offer(sample(sharpness: 0.002), text: top, id: 1, at: 0), .added(1))
    XCTAssertEqual(frames.offer(sample(sharpness: 0.0021), text: top, id: 2, at: 0.5), .duplicate, "Not clearly sharper.")
    XCTAssertEqual(frames.offer(sample(sharpness: 0.01), text: top, id: 3, at: 1), .replaced(old: 1, new: 3))
    XCTAssertEqual(frames.offer(sample(content: 0.4), text: bottom, id: 4, at: 1.5), .added(4))
    XCTAssertEqual(frames.labels, [1, 2, 3, 4]); XCTAssertEqual(frames.frameIDs, [3, 4])
    // A sharper frame of the top view that cut off question 1 must not replace the one that shows it.
    let cut = text(["2. Find the slope of the line", "Show all of your work clearly", "3. Factor x squared minus nine"])
    XCTAssertNotEqual(frames.offer(sample(sharpness: 0.05), text: cut, id: 5, at: 2), .replaced(old: 3, new: 5))
    XCTAssertTrue(frames.labels.isSuperset(of: [1, 2, 3, 4]))
  }

  func testACloserFrameNeverDropsTheTextOfTheViewItWouldReplace() {
    var frames = PageFrames()
    let full = text(["1. Solve the system of equations", "2. Find the slope of the line", "through the points one two and three",
      "A) three  B) four  C) five  D) six", "Show all of your work clearly"])
    let closer = text(["1. Solve the system of equations", "2. Find the slope of the line", "Show all of your work clearly"])
    XCTAssertEqual(frames.offer(sample(sharpness: 0.002), text: full, id: 1, at: 0), .added(1))
    XCTAssertEqual(frames.offer(sample(sharpness: 0.05), text: closer, id: 2, at: 1), .duplicate,
      "Sharper, but it cuts off question 2's data and choices.")
    XCTAssertEqual(frames.frameIDs, [1])
  }
  func testAReplacedViewKeepsItsPlaceInThePage() {
    var frames = PageFrames()
    let top = text(["1. Solve for x in 2x + 3 = 11", "2. Find the slope of the line", "Show all of your work clearly"])
    let bottom = text(["3. Factor x squared minus nine", "4. Graph y equals two x plus one", "Use the grid provided below"])
    _ = frames.offer(sample(sharpness: 0.002), text: top, id: 1, at: 0)
    _ = frames.offer(sample(content: 0.4), text: bottom, id: 2, at: 1)
    XCTAssertEqual(frames.offer(sample(sharpness: 0.05), text: top, id: 3, at: 2), .replaced(old: 1, new: 3))
    XCTAssertEqual(frames.frameIDs, [3, 2], "The sharper top view stays first: reading order, thumbnail and neighbor context.")
  }
  func testWithoutReadableLinesViewsAreToldApartByImage() {
    var frames = PageFrames()
    XCTAssertEqual(frames.offer(sample(content: 0.05), text: FrameText(), id: 1, at: 0), .added(1))
    XCTAssertEqual(frames.offer(sample(content: 0.06), text: FrameText(), id: 2, at: 1), .duplicate)
    XCTAssertEqual(frames.offer(sample(content: 0.5), text: FrameText(), id: 3, at: 2), .added(3))
  }

  func testAPageIsCoveredWhenNothingNewAppearsButWaitsLongerForAMissingQuestion() {
    var frames = PageFrames()
    XCTAssertFalse(frames.isComplete(at: 100), "Nothing kept yet.")
    _ = frames.offer(sample(), text: text(["1. Solve for x in 2x + 3 = 11", "Show all of your work clearly", "Write the answer in a box"]), id: 1, at: 10)
    XCTAssertFalse(frames.isComplete(at: 12)); XCTAssertTrue(frames.isComplete(at: 12.5))
    _ = frames.offer(sample(content: 0.5), text: text(["3. Factor x squared minus nine", "Use the grid provided below", "Label both of the axes"]), id: 2, at: 13)
    XCTAssertEqual(frames.missing, [2])
    XCTAssertFalse(frames.isComplete(at: 16), "Question 2 is missing: keep looking a little longer.")
    XCTAssertTrue(frames.isComplete(at: 20.5), "But never wait forever on an unclear page.")
  }

  func testAPageHoldsAtMostSixViews() {
    var frames = PageFrames()
    for index in 0..<6 {
      XCTAssertEqual(frames.offer(sample(content: Double(index) * 0.3), text: FrameText(), id: index, at: Double(index)), .added(index))
    }
    XCTAssertEqual(frames.offer(sample(content: 3), text: FrameText(), id: 9, at: 9), .full)
  }

  func testQuestionListsAreSpokenNaturally() {
    XCTAssertEqual(QuestionLabels.spoken([3]), "Question 3")
    XCTAssertEqual(QuestionLabels.spoken([4, 3]), "Questions 3 and 4")
    XCTAssertEqual(QuestionLabels.spoken([1, 2, 3, 4]), "Questions 1 to 4")
    XCTAssertEqual(QuestionLabels.spoken([1, 3, 5]), "Questions 1, 3 and 5")
  }
}
