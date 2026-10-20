import Foundation

/// Worked solutions laid out as fx-CG50 screens: fixed-size pages of wrapped lines that are read without zooming.
/// Pure layout; `CalculatorPictures` measures and draws the text and `G3P` writes the files.
enum CalculatorLayout {
  enum Style: Sendable, Equatable { case heading, answer, body, label }
  struct Line: Sendable, Equatable {
    let text: String
    let style: Style
  }
  /// One calculator screen of one question (or of the answers summary).
  struct Screen: Sendable, Equatable {
    /// Shown at the top of the screen, e.g. "3(b)  2/4".
    let header: String
    let lines: [Line]
  }
  /// How much fits: `width` measures a line of text in pixels for a style; `maxWidth` is the text column.
  struct Metrics {
    var linesPerScreen: Int
    var maxWidth: Double
    var width: (String, Style) -> Double
  }

  /// Greedy word wrap. A word wider than the line is broken between characters, so nothing is ever cut off.
  static func wrap(_ text: String, style: Style, metrics: Metrics, indent: String = "") -> [String] {
    var lines: [String] = []
    for paragraph in text.components(separatedBy: "\n") {
      var line = ""
      func fits(_ candidate: String) -> Bool { metrics.width(candidate, style) <= metrics.maxWidth }
      for word in paragraph.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
        let candidate = line.isEmpty ? word : line + " " + word
        if fits(candidate) { line = candidate; continue }
        if !line.isEmpty { lines.append(line); line = indent }
        var rest = word
        while !fits(line + rest) && rest.count > 1 {
          // Break the longest prefix that fits (at least one character, so this always ends).
          var cut = rest.count - 1
          while cut > 1 && !fits(line + String(rest.prefix(cut))) { cut -= 1 }
          lines.append(line + String(rest.prefix(cut))); line = indent; rest = String(rest.dropFirst(cut))
        }
        line += rest
      }
      if !line.trimmingCharacters(in: .whitespaces).isEmpty || lines.isEmpty { lines.append(line) }
    }
    return lines
  }

  /// The screens of one solved question: the answer first (what is looked up), then the problem, the steps and the check.
  /// Every screen repeats the question's label and its position, e.g. "3(b)  2/4".
  static func screens(label: String, problem: String, steps: [String], answer: String, check: String, note: String?,
                      metrics: Metrics) -> [Screen] {
    var lines: [Line] = []
    func add(_ text: String, _ style: Style, indent: String = "") {
      lines += wrap(text, style: style, metrics: metrics, indent: indent).map { Line(text: $0, style: style) }
    }
    add("Answer: " + answer, .answer)
    if let note, !note.trimmingCharacters(in: .whitespaces).isEmpty { add(note, .label) }
    add(problem, .body)
    for (index, step) in steps.enumerated() { add("\(index + 1). " + step, .body, indent: "   ") }
    if !check.trimmingCharacters(in: .whitespaces).isEmpty && check != "—" { add("Check: " + check, .label) }
    return paginate(lines, title: label, metrics: metrics)
  }

  /// Every question's final answer, a few per screen, for looking answers up quickly.
  static func summary(_ answers: [(label: String, answer: String)], metrics: Metrics) -> [Screen] {
    var lines: [Line] = []
    for item in answers {
      lines += wrap(item.label + ": " + item.answer, style: .body, metrics: metrics, indent: "   ").map { Line(text: $0, style: .body) }
    }
    return paginate(lines, title: "Answers", metrics: metrics)
  }

  /// Splits lines into screens; a screen never starts with a blank continuation and always has at least one line.
  static func paginate(_ lines: [Line], title: String, metrics: Metrics) -> [Screen] {
    let size = max(1, metrics.linesPerScreen)
    let chunks = stride(from: 0, to: max(lines.count, 1), by: size).map { Array(lines[$0..<min($0 + size, lines.count)]) }
    return chunks.enumerated().map { index, chunk in
      Screen(header: chunks.count == 1 ? title : "\(title)  \(index + 1)/\(chunks.count)", lines: chunk)
    }
  }
}
