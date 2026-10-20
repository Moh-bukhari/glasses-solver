import Foundation

/// Solutions laid out as fx-CG50 pictures: one subquestion per picture, only its short working and its answer, in
/// lines that fit the 384x192 screen without zooming. Pure layout; `CalculatorPictures` measures and draws the text and
/// `G3P` writes the files.
enum CalculatorLayout {
  enum Style: Sendable, Equatable { case answer, body, note }
  struct Line: Sendable, Equatable {
    let text: String
    let style: Style
  }
  /// One picture: which question it is, its page within that question ("page 1/3", nil when it is the only one), lines.
  struct Screen: Sendable, Equatable {
    let title: String
    let page: String?
    let lines: [Line]
  }
  /// How much fits: `width` measures a line of text in pixels for a style; `maxWidth` is the text column.
  struct Metrics {
    var linesPerScreen: Int
    var maxWidth: Double
    var width: (String, Style) -> Double
  }

  /// The pictures of one subquestion: the short working, then the answer. A flagged answer says to check the PDF.
  static func screens(label: String, brief: [String], answer: String, unsure: Bool, metrics: Metrics) -> [Screen] {
    var lines: [Line] = []
    for step in brief where !step.trimmingCharacters(in: .whitespaces).isEmpty {
      lines += wrap(step, style: .body, metrics: metrics, indent: "  ").map { Line(text: $0, style: .body) }
    }
    lines += wrap("Ans: " + answer, style: .answer, metrics: metrics, indent: "  ").map { Line(text: $0, style: .answer) }
    if unsure { lines.append(Line(text: "Unsure: check the PDF", style: .note)) }
    return paginate(lines, title: title(for: label), metrics: metrics)
  }

  /// "3(b)" is shown as "Q3(b)"; labels that already say what they are ("Q4", "Problem 2", "Figure 1") stay as printed.
  static func title(for label: String) -> String {
    let trimmed = label.trimmingCharacters(in: .whitespaces)
    return trimmed.first?.isNumber == true ? "Q" + trimmed : trimmed
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
      if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
    }
    return lines
  }

  /// Splits lines into pictures of `linesPerScreen` lines; several pictures of one question are numbered "page 1/3".
  static func paginate(_ lines: [Line], title: String, metrics: Metrics) -> [Screen] {
    let size = max(1, metrics.linesPerScreen)
    let chunks = stride(from: 0, to: max(lines.count, 1), by: size).map { Array(lines[$0..<min($0 + size, lines.count)]) }
    return chunks.enumerated().map { index, chunk in
      Screen(title: title, page: chunks.count == 1 ? nil : "page \(index + 1)/\(chunks.count)", lines: chunk)
    }
  }

  /// File names the calculator shows in full (8.3) and lists in packet order: "Q01_01", "Q01_02", "Q02_01", ...
  /// (question number in the packet, then the page of that question). `digits` is 3 for packets of 100+ subquestions,
  /// so "Q100" never sorts before "Q11".
  static func fileName(question: Int, page: Int, digits: Int = 2) -> String {
    func padded(_ n: Int, _ width: Int) -> String { String(repeating: "0", count: max(0, width - String(n).count)) + String(n) }
    return "Q" + padded(question, digits) + "_" + padded(page, 2) + ".g3p"
  }
  /// The calculator folder for a packet, at most 8 characters and never one issued before (`taken`): "SOL" + month and
  /// day + a letter (e.g. "SOL1020A"), then "S" + month and day + a number once a day's 26 letters are used.
  static func folderName(date: Date, taken: Set<String>, timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.month, .day], from: date)
    let day = String(format: "%02d%02d", parts.month ?? 1, parts.day ?? 1)
    for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" where !taken.contains("SOL" + day + String(letter)) { return "SOL" + day + String(letter) }
    for number in 0..<1000 where !taken.contains("S" + day + String(format: "%03d", number)) { return "S" + day + String(format: "%03d", number) }
    return "S" + day + "999"
  }
  /// The calculator lists at most 200 files per folder. Questions (with all their pages) are grouped into parts of at
  /// most `limit` files, in order; a question is never split between parts.
  static func parts(_ pageCounts: [Int], limit: Int = 200) -> [[Int]] {
    var parts: [[Int]] = [], current: [Int] = [], files = 0
    for (question, count) in pageCounts.enumerated() {
      if files + count > limit, !current.isEmpty { parts.append(current); current = []; files = 0 }
      current.append(question); files += count
    }
    if !current.isEmpty { parts.append(current) }
    return parts
  }
}
