import Foundation

// Live multi-frame page capture: instead of one slow full-resolution still per page, the clearest preview frames of
// each part of a page are kept as the page's photos, and question numbers read on the phone track what is covered.
// Pure Foundation (Sendable value types); the Vision text reader lives in ScanQuality.swift.

/// Top-level question numbers read from the start of recognized text lines.
enum QuestionLabels {
  /// "3." "3)" "(3)" "3:" "Q3" "Q.3" "#3" "Question 3" "Problem 3" "Exercise 3" "Ex. 3" "No. 3", optionally followed by text.
  /// Lines that merely start with a number in math ("3x + 2 = 5", "2.5", "10/19", "1,000") are not labels.
  static func number(in line: String) -> Int? { label(in: line)?.number }
  /// `heading` is true for a worded label ("Question 3", "Problem 3", "Q3"): a sheet's question number. A bare "3." may
  /// also be a numbered list inside a question.
  static func label(in line: String) -> (number: Int, heading: Bool)? {
    let text = line.trimmingCharacters(in: .whitespaces)
    let words = #"^(?:question|problem|exercise|prob\.?|ex\.?|no\.?|q\.?|#)\s*(\d{1,3})(?!\d|[.,:/]\d)"#
    let bare = #"^\(?(\d{1,3})(?:\)|[.:](?!\d))"#
    for (pattern, heading) in [(words, true), (bare, false)] {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
        let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
        let range = Range(match.range(at: 1), in: text), let value = Int(text[range]), (1...200).contains(value) else { continue }
      return (value, heading)
    }
    return nil
  }
  /// Distinct worded question numbers in reading order.
  static func headings(in lines: [String]) -> [Int] {
    var seen: Set<Int> = [], ordered: [Int] = []
    for line in lines { if let label = label(in: line), label.heading, seen.insert(label.number).inserted { ordered.append(label.number) } }
    return ordered
  }
  /// "Question 3", "Questions 3 and 4", "Questions 1 to 5".
  static func spoken(_ numbers: [Int]) -> String {
    let sorted = Array(Set(numbers)).sorted()
    guard let first = sorted.first, let last = sorted.last else { return "" }
    if sorted.count == 1 { return "Question \(first)" }
    if sorted.count == last - first + 1 && sorted.count > 2 { return "Questions \(first) to \(last)" }
    return "Questions " + sorted.dropLast().map(String.init).joined(separator: ", ") + " and \(last)"
  }
  /// Distinct numbers in reading order.
  static func numbers(in lines: [String]) -> [Int] {
    var seen: Set<Int> = [], ordered: [Int] = []
    for line in lines { if let value = number(in: line), seen.insert(value).inserted { ordered.append(value) } }
    return ordered
  }
}

/// Question numbers captured so far in the packet, to announce new ones and notice a skipped number.
/// Numbering may restart (a new section or worksheet); only a short forward jump counts as a gap.
struct QuestionProgress: Sendable, Equatable {
  private(set) var captured: [Int] = []
  /// Gaps already reported, so each is spoken once.
  private(set) var reported: Set<Int> = []
  static let maxGap = 3

  mutating func reset() { self = Self() }

  /// Records numbers seen in a kept frame; returns the newly captured ones and newly noticed missing ones.
  mutating func observe(_ numbers: [Int]) -> (new: [Int], missing: [Int]) {
    var new: [Int] = []
    for number in numbers where !captured.contains(number) { captured.append(number); new.append(number) }
    return (new, takeMissing())
  }

  /// A number between captured neighbors (at most `maxGap` apart) that has not been captured itself.
  var missing: [Int] { Self.gaps(in: Set(captured)) }
  static func gaps(in numbers: Set<Int>) -> [Int] {
    let sorted = numbers.sorted()
    var gaps: [Int] = []
    for (low, high) in zip(sorted, sorted.dropFirst()) where high - low > 1 && high - low <= maxGap {
      gaps += Array((low + 1)..<high)
    }
    return gaps
  }

  private mutating func takeMissing() -> [Int] {
    let fresh = missing.filter { !reported.contains($0) }
    reported.formUnion(fresh)
    return fresh
  }
}

/// One line of text read on the phone from a preview frame (Vision coordinates: normalized, lower-left origin).
struct ReadLine: Sendable, Equatable {
  var text: String
  var confidence: Double
  var box: CGRect
}

/// What on-device text reading found in one frame.
struct FrameText: Sendable, Equatable {
  var lines: [ReadLine] = []
  /// Question numbers at the start of lines, top to bottom.
  var labels: [Int] { QuestionLabels.numbers(in: readingOrder) }
  /// Worded question numbers ("Question 3") only.
  var headings: [Int] { QuestionLabels.headings(in: readingOrder) }
  private var readingOrder: [String] { lines.sorted { $0.box.maxY > $1.box.maxY }.map(\.text) }
  /// Height of the smaller printed lines (lower quartile of lines with 8+ characters), as a fraction of the frame height;
  /// nil with fewer than 3 such lines. Large handwriting must not make small printed questions look readable.
  var smallLineHeight: Double? {
    let heights = lines.filter { $0.text.count >= 8 }.map { Double($0.box.height) }.sorted()
    return heights.count >= 3 ? heights[heights.count / 4] : nil
  }
  /// Words long enough to identify a view of the page (lowercase letters and digits). Words, not whole lines, so a line
  /// cut off at the frame edge and read slightly differently from frame to frame still matches.
  var signature: Set<String> { Self.words(lines.map(\.text)) }
  static func words(_ texts: [String]) -> Set<String> {
    Set(texts.flatMap { $0.lowercased().split { !$0.isLetter && !$0.isNumber } }.map(String.init).filter { $0.count >= 4 })
  }
  var meanConfidence: Double { lines.isEmpty ? 0 : lines.map(\.confidence).reduce(0, +) / Double(lines.count) }
}

/// The clearest frame of each distinct view of the page being scanned, and when the page counts as covered.
/// Starting values follow published practice: text at least ~20 px tall (Tesseract: below a 10 px x-height accuracy
/// collapses), a few steady frames before keeping one (WeScan's capture funnel), a view kept again only when it is
/// clearly sharper, and stopping once nothing new appears for a moment (stopping rules for video-stream text reading).
struct PageFrames: Sendable {
  struct Configuration: Sendable, Equatable {
    /// Median text-line height, as a fraction of the frame height (20 px of 1280).
    var minLineHeight = 20.0 / 1280
    /// The smaller read lines must be at least this tall (18 px of 1280), or the frame is not kept and the wearer moves closer.
    var minReadLineHeight = 18.0 / 1280
    /// Consecutive analyzed frames with little image change before a frame may be kept.
    var steadyFrames = 3
    var steadyDifference = 0.08
    /// Share of a new frame's words already in a kept frame for both to count as the same view.
    var sameView = 0.6
    /// Without enough readable words, views are compared by image fingerprint instead.
    var sameViewImage = 0.12
    var minWordsToCompare = 5
    /// A same-view frame replaces the kept one only when clearly better.
    var betterBy = 0.10
    var maxFrames = 6
    /// Nothing new for this long, with no missing question number, covers the page.
    var quietTime: TimeInterval = 2.5
    /// With a missing question number, wait this much longer (after saying so) before saving anyway.
    var missingGrace: TimeInterval = 5
  }
  struct Kept: Sendable, Equatable {
    let id: Int
    var time: TimeInterval
    var quality: Double
    var signature: Set<String>
    var labels: Set<Int>
    var headings: Set<Int> = []
    var fingerprint: [Double]
  }
  enum Decision: Sendable, Equatable {
    case added(Int)
    case replaced(old: Int, new: Int)
    case duplicate
    /// The page already holds `maxFrames` distinct views; save it and start the next page with this frame.
    case full
  }

  let configuration: Configuration
  /// The packet names questions with words ("Question 3"): bare numbers are lists inside a question, not new questions.
  var headingsOnly = false
  private(set) var kept: [Kept] = []
  private(set) var lastNew: TimeInterval = 0
  private var previous: PageSample?
  private var steadyCount = 0
  init(configuration: Configuration = Configuration()) { self.configuration = configuration }

  var isEmpty: Bool { kept.isEmpty }
  var labels: Set<Int> { kept.reduce(into: Set<Int>()) { $0.formUnion($1.labels) } }
  var headings: Set<Int> { kept.reduce(into: Set<Int>()) { $0.formUnion($1.headings) } }
  /// The question numbers that name this page: worded headings when the packet uses them, otherwise any numbers.
  func questions(headingsOnly: Bool) -> Set<Int> { headingsOnly ? headings : labels }
  /// The printed text is big enough to keep the frame (see `FrameText.smallLineHeight`).
  func isLegible(_ text: FrameText) -> Bool {
    guard let height = text.smallLineHeight else { return true }
    return height >= configuration.minReadLineHeight
  }
  /// Numbers missing between the numbers seen on this page (at most `QuestionProgress.maxGap` apart).
  var missing: [Int] { QuestionProgress.gaps(in: questions(headingsOnly: headingsOnly)) }

  /// Every analyzed frame: is it steady, readable and big enough to be worth reading and keeping?
  /// A view with no text found (a figure, faint handwriting) needs twice as long to be kept.
  mutating func gate(_ sample: PageSample) -> Bool {
    defer { previous = sample }
    guard sample.acceptable, sample.gesture == nil, sample.contentBounds == nil || isBigEnough(sample) else {
      steadyCount = 0; return false
    }
    if let previous, StabilityGate.imageDifference(previous, sample) <= configuration.steadyDifference,
      StabilityGate.movement(previous, sample) <= 0.045 { steadyCount += 1 } else { steadyCount = 1 }
    return steadyCount >= configuration.steadyFrames * (sample.contentBounds == nil ? 2 : 1)
  }
  /// Text was found but is too small to read reliably: the wearer should move closer.
  func isBigEnough(_ sample: PageSample) -> Bool {
    sample.linePixels >= configuration.minLineHeight * Self.referenceHeight(sample)
  }

  /// A gated frame and the text read from it: keep it as a new view, let it replace a weaker frame of the same view, or drop it.
  mutating func offer(_ sample: PageSample, text: FrameText, id: Int, at time: TimeInterval) -> Decision {
    let quality = Self.quality(sample, text: text)
    let signature = text.signature, labels = Set(text.labels)
    let candidate = Kept(id: id, time: time, quality: quality, signature: signature, labels: labels,
      headings: Set(text.headings), fingerprint: sample.fingerprint)
    let newLabels = labels.subtracting(self.labels)
    let sameViews = kept.indices.filter { isSameView(kept[$0], candidate) }
    if let index = sameViews.max(by: { closeness(kept[$0], candidate) < closeness(kept[$1], candidate) }) {
      // Same view: keep the clearer frame, but never lose a question number or most of the text only the old frame shows
      // (a closer, sharper frame may cut off a question's data). The page keeps its capture order.
      let old = kept[index]
      let keepsText = old.signature.isEmpty
        || Double(old.signature.intersection(signature).count) >= 0.9 * Double(old.signature.count)
      guard quality >= old.quality + configuration.betterBy, old.labels.subtracting(labels).isEmpty, keepsText else {
        if newLabels.isEmpty { return .duplicate }
        return append(candidate, at: time)
      }
      var replacement = candidate
      replacement.time = old.time
      kept[index] = replacement
      if !newLabels.isEmpty { lastNew = time }
      return .replaced(old: old.id, new: id)
    }
    return append(candidate, at: time)
  }

  /// Covered: something kept, no question number missing between the ones seen, and nothing new for `quietTime`.
  /// A missing number only delays saving by `missingGrace`; an unclear page never ends the scan.
  func isComplete(at time: TimeInterval) -> Bool {
    guard !kept.isEmpty else { return false }
    let wait = configuration.quietTime + (missing.isEmpty ? 0 : configuration.missingGrace)
    return time - lastNew >= wait
  }

  /// Frames in the order they were first taken.
  var frameIDs: [Int] { kept.sorted { $0.time < $1.time }.map(\.id) }
  /// Every word read on this page, to recognize the same sheet after it was saved.
  var words: Set<String> { kept.reduce(into: Set<String>()) { $0.formUnion($1.signature) } }
  /// Share of `words` already in `known`: how much of a view was seen before.
  static func overlap(_ words: Set<String>, with known: Set<String>) -> Double {
    words.isEmpty ? 0 : Double(words.intersection(known).count) / Double(words.count)
  }

  private mutating func append(_ candidate: Kept, at time: TimeInterval) -> Decision {
    guard kept.count < configuration.maxFrames else { return .full }
    kept.append(candidate); lastNew = time
    return .added(candidate.id)
  }

  private func isSameView(_ a: Kept, _ b: Kept) -> Bool {
    if comparesText(a, b) { return similarity(a, b) >= configuration.sameView }
    guard !a.fingerprint.isEmpty, a.fingerprint.count == b.fingerprint.count else { return false }
    // Little readable text: the same question number in a similar image is the same view (hands and small head motion vary).
    let limit = !a.labels.isEmpty && a.labels == b.labels ? configuration.sameViewImage * 2 : configuration.sameViewImage
    return Self.difference(a.fingerprint, b.fingerprint) <= limit
  }
  /// Enough readable words on both frames to compare views by text rather than by image.
  private func comparesText(_ a: Kept, _ b: Kept) -> Bool {
    min(a.signature.count, b.signature.count) >= configuration.minWordsToCompare
  }
  /// Higher is more alike, on the same measure `isSameView` used.
  private func closeness(_ a: Kept, _ b: Kept) -> Double {
    comparesText(a, b) ? similarity(a, b) : 1 - Self.difference(a.fingerprint, b.fingerprint)
  }
  /// Share of the candidate's words already in `a`.
  private func similarity(_ a: Kept, _ b: Kept) -> Double {
    guard !b.signature.isEmpty else { return 0 }
    return Double(a.signature.intersection(b.signature).count) / Double(b.signature.count)
  }

  /// 0...1: sharpness relative to contrast (lighting-independent), text size, and reading confidence.
  static func quality(_ sample: PageSample, text: FrameText) -> Double {
    let sharp = sample.contrast > 0 ? min(1, sample.sharpness / (sample.contrast * sample.contrast) / 0.25) : 0
    let size = min(1, max(0, (sample.linePixels / referenceHeight(sample) * 1280 - 20) / 15))
    return 0.5 * sharp + 0.35 * size + 0.15 * text.meanConfidence
  }
  /// Frame height in pixels the sample's line height refers to (720x1280 portrait unless the stream drops resolution).
  static func referenceHeight(_ sample: PageSample) -> Double { sample.frameHeight > 0 ? Double(sample.frameHeight) : 1280 }
  private static func difference(_ a: [Double], _ b: [Double]) -> Double {
    zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(max(1, a.count))
  }
}
