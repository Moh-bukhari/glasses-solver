import Foundation
import UIKit
import CoreText
import PDFKit
import ImageIO

struct SolvedProblem: Codable, Sendable {
  let problem: String
  let steps: [String]
  let answer: String
  let check: String
  var label: String? = nil
  var sourcePages: [Int]? = nil
  var reviewNote: String? = nil
}
struct SolvedPage: Codable, Sendable {
  let readable: Bool
  let retakeReason: String
  let title: String
  let problems: [SolvedProblem]
  var coverage: String? = nil
  var providers: String? = nil
}

struct SavedSolution: Identifiable {
  let id: UUID
  let title: String
  let date: Date
  let pdf: URL
  let source: URL
}

@MainActor
protocol SolutionSaving {
  /// `sources` holds each packet page's photos in order; a page may have several close-up photos.
  /// `names` are the pages' names as the wearer heard them ("Question 3"), used to title the source photos.
  func save(page: SolvedPage, sources: [[URL]], names: [String]) async throws -> SavedSolution
}

/// What the app remembers about a saved packet, kept hidden in its folder.
private struct StoredSolution: Codable {
  let id: UUID
  let date: Date
  let firstPhoto: String
  let solution: SolvedPage
}

/// One folder per packet in Files › On My iPhone › Glasses Solver › Solutions, named by date and title, holding
/// Solutions.pdf and every page photo ("Page 1.jpg", "Page 2 (1).jpg", …).
@MainActor
struct SolutionStore: SolutionSaving {
  static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
  static var directory: URL { documents.appendingPathComponent("Solutions", isDirectory: true) }
  static let record = ".solution.json"

  /// 2.6 starts over, as the wearer asked: earlier PDFs move to "Old solutions" (still in Files, no longer listed in the
  /// app) and the old in-progress pages are cleared. Runs once.
  static func startFresh() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: "startedFresh26") else { return }
    defaults.set(true, forKey: "startedFresh26")
    let files = FileManager.default
    if let old = try? files.contentsOfDirectory(atPath: directory.path), !old.isEmpty {
      let archive = documents.appendingPathComponent("Old solutions", isDirectory: true)
      if files.fileExists(atPath: archive.path) {
        for name in old { try? files.moveItem(at: directory.appendingPathComponent(name), to: archive.appendingPathComponent(name)) }
      } else {
        try? files.moveItem(at: directory, to: archive)
      }
    }
    // Drafts now live out of sight in Application Support; the old one in Documents showed up in Files.
    try? files.removeItem(at: documents.appendingPathComponent("ScanDraft", isDirectory: true))
  }

  func save(page: SolvedPage, sources pages: [[URL]], names pageNames: [String]) async throws -> SavedSolution {
    Self.startFresh()
    let id = UUID(), date = Date()
    try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? [])
    let folderName = SolutionFolder.unique(SolutionFolder.name(title: MathText.readable(page.title), date: date), existing: existing)
    let folder = Self.directory.appendingPathComponent(folderName, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let pdf = folder.appendingPathComponent(SolutionFolder.pdfName)
    // Flattened in page order; each photo is titled with its packet page so "source page N" can be found in the PDF.
    let sources = pages.flatMap { $0 }
    let titles = pages.enumerated().flatMap { page, frames in
      let name = pageNames.indices.contains(page) && pageNames[page] != "Page \(page + 1)" ? " (\(pageNames[page]))" : ""
      return frames.indices.map { "page \(page + 1)\(name)" + (frames.count == 1 ? "" : ", part \($0 + 1) of \(frames.count)") }
    }
    let names = pages.enumerated().flatMap { page, frames in
      frames.indices.map { SolutionFolder.photoName(page: page + 1, photo: $0 + 1, of: frames.count) }
    }
    do {
      guard !sources.isEmpty else { throw SolverError.message("No source photos were saved.") }
      // Decoding full-size photos is the slow part: do it off the main actor, all pages concurrently.
      let previews = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
        for (index, url) in sources.enumerated() {
          group.addTask { (index, try SolutionPDF.previewJPEG(try Data(contentsOf: url))) }
        }
        var ordered = [Data?](repeating: nil, count: sources.count)
        for try await (index, data) in group { ordered[index] = data }
        return ordered.compactMap { $0 }
      }
      let images = try previews.map { data -> UIImage in
        guard let image = UIImage(data: data) else { throw SolverError.message("A source photo is unreadable.") }
        return image
      }
      let data = try await Task.detached(priority: .userInitiated) {
        try SolutionPDF.render(page: page, sources: images, titles: titles)
      }.value
      try data.write(to: pdf, options: .atomic)
      for (original, name) in zip(sources, names) {
        try FileManager.default.copyItem(at: original, to: folder.appendingPathComponent(name))
      }
      let stored = StoredSolution(id: id, date: date, firstPhoto: names[0], solution: page)
      try JSONEncoder().encode(stored).write(to: folder.appendingPathComponent(Self.record), options: .atomic)
      return SavedSolution(id: id, title: page.title, date: date, pdf: pdf, source: folder.appendingPathComponent(names[0]))
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
  }
  static func history() -> [SavedSolution] {
    startFresh()
    let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return folders.compactMap { folder in
      guard let data = try? Data(contentsOf: folder.appendingPathComponent(record)),
        let stored = try? JSONDecoder().decode(StoredSolution.self, from: data) else { return nil }
      let pdf = folder.appendingPathComponent(SolutionFolder.pdfName)
      guard FileManager.default.fileExists(atPath: pdf.path) else { return nil }
      return SavedSolution(id: stored.id, title: stored.solution.title, date: stored.date, pdf: pdf,
        source: folder.appendingPathComponent(stored.firstPhoto))
    }.sorted { $0.date > $1.date }
  }
}

@MainActor
enum SolutionPDF {
  /// A small JPEG-backed preview: the PDF embeds compressed data instead of a decoded bitmap.
  nonisolated static func previewJPEG(_ original: Data) throws -> Data {
    guard let source = CGImageSourceCreateWithData(original as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary)
      else { throw SolverError.message("A source photo is unreadable.") }
    return try PageAnalyzer.encodeJPEG(image, quality: 0.82)
  }
  nonisolated static func render(page: SolvedPage, source: UIImage?) throws -> Data {
    try render(page: page, sources: source.map { [$0] } ?? [])
  }
  /// Thread-safe UIKit/CoreText drawing; run off the main actor so the UI stays responsive.
  /// `titles` names each source photo, e.g. "page 2, part 1 of 3"; the PDF prints "Source photograph N · <title>".
  /// Problem text, steps, answers, checks and review notes may hold LaTeX (`$...$`, `$$...$$`), which is typeset; titles,
  /// labels and the coverage list stay plain text.
  nonisolated static func render(page: SolvedPage, sources: [UIImage], titles: [String] = []) throws -> Data {
    let body = NSMutableAttributedString(string: "")
    var keepWithNext: [NSRange] = []
    let textWidth: CGFloat = 524, textHeight: CGFloat = 670
    func append(_ text: String, size: CGFloat = 12, bold: Bool = false, color: UIColor = .black, keep: Bool = false, math: Bool = false) {
      let start = body.length
      let style = NSMutableParagraphStyle(); style.lineSpacing = 4; style.paragraphSpacing = 6
      let attributes: [NSAttributedString.Key: Any] = [
        .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
        .foregroundColor: color, .paragraphStyle: style]
      if math {
        // A formula never exceeds the text column, so a page always fits at least one line (see the overflow guard below).
        body.append(MathTypesetter.paragraphs(text, attributes: attributes, fontSize: size, maxWidth: textWidth - 4, maxHeight: textHeight - 110))
      } else {
        body.append(NSAttributedString(string: text + "\n", attributes: attributes))
      }
      if bold || keep { keepWithNext.append(NSRange(location: start, length: body.length - start)) }
    }
    append(MathText.readable(page.title), size: 23, bold: true)
    append("Worked solution • \(Date().formatted(date: .abbreviated, time: .shortened))", size: 10, color: .darkGray)
    if let providers = page.providers { append(providers, size: 10, color: .darkGray) }
    if let coverage = page.coverage {
      append("Coverage checklist", size: 16, bold: true)
      append(coverage)
      for (index, item) in page.problems.enumerated() {
        let pages = (item.sourcePages ?? []).map(String.init).joined(separator: ", ")
        let flag = item.reviewNote?.hasPrefix("NEEDS REVIEW:") == true ? " — NEEDS REVIEW" : ""
        append("\(index + 1). \(MathText.readable(item.label ?? "Problem")) · source page(s) \(pages)\(flag)", size: 10)
      }
    }
    for (index, problem) in page.problems.enumerated() {
      append(MathText.readable(problem.label ?? "Problem \(index + 1)"), size: 16, bold: true)
      if let pages = problem.sourcePages {
        append("Source page(s): " + pages.map(String.init).joined(separator: ", "), size: 10, color: .darkGray, keep: true)
      }
      if let note = problem.reviewNote, !note.trimmed.isEmpty {
        append(note, bold: note.hasPrefix("NEEDS REVIEW:"), color: .darkGray, math: true)
      }
      append(problem.problem, math: true)
      for (step, text) in problem.steps.enumerated() { append("\(step + 1). \(text)", math: true) }
      append("Answer", bold: true); append(problem.answer, math: true)
      append("Verification", bold: true); append(problem.check, math: true)
      append("", size: 6)
    }
    let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let framesetter = CTFramesetterCreateWithAttributedString(body)
    var offset = 0, pageNumber = 0, overflow = false
    let format = UIGraphicsPDFRendererFormat()
    format.documentInfo = [kCGPDFContextTitle as String: MathText.readable(page.title), kCGPDFContextCreator as String: "Glasses Solver"]
    let data = UIGraphicsPDFRenderer(bounds: bounds, format: format).pdfData { renderer in
      func chrome() {
        pageNumber += 1
        ("GLASSES SOLVER" as NSString).draw(at: CGPoint(x: 44, y: 24), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 9), .foregroundColor: UIColor.darkGray])
        ("AI-generated • Check the problem transcription and result.     \(pageNumber)" as NSString)
          .draw(at: CGPoint(x: 44, y: 758), withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.darkGray])
      }
      while offset < body.length && pageNumber < 300 {
        renderer.beginPage(); chrome()
        let context = renderer.cgContext
        context.saveGState(); context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: CGRect(x: 44, y: 64, width: textWidth, height: textHeight), transform: nil)
        var frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
        var count = CTFrameGetVisibleStringRange(frame).length
        let lines = CTFrameGetLines(frame) as! [CTLine]
        if let last = lines.last {
          let lineStart = CTLineGetStringRange(last).location
          if let heading = keepWithNext.last(where: { NSLocationInRange(lineStart, $0) }) {
            var cut = heading.location
            // Move a trailing heading/source-reference chain together with its first content line.
            while let previous = keepWithNext.last(where: { NSMaxRange($0) == cut }) { cut = previous.location }
            if cut > offset {
              frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: cut - offset), path, nil)
              count = CTFrameGetVisibleStringRange(frame).length
            }
          }
        }
        CTFrameDraw(frame, context)
        MathTypesetter.drawFormulas(in: frame, context: context)
        context.restoreGState()
        if count == 0 { overflow = true; break }
        offset += count
      }
      if offset < body.length { overflow = true }
      for (sourceIndex, source) in sources.enumerated() {
        renderer.beginPage(); chrome()
        let title = titles.indices.contains(sourceIndex) ? " · \(titles[sourceIndex])" : ""
        ("Source photograph \(sourceIndex + 1)\(title)" as NSString).draw(at: CGPoint(x: 44, y: 56), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 18)])
        let scale = min(524 / source.size.width, 636 / source.size.height)
        let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        source.draw(in: CGRect(x: (612 - size.width) / 2, y: 94, width: size.width, height: size.height))
      }
    }
    guard !overflow, PDFDocument(data: data)?.pageCount ?? 0 > 0 else {
      throw SolverError.message("The solution could not fit in a complete PDF. No partial PDF was saved.")
    }
    return data
  }
}
