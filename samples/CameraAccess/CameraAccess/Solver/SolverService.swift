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
  func save(page: SolvedPage, jpegs: [Data]) throws -> SavedSolution
}

@MainActor
struct SolutionStore: SolutionSaving {
  static var directory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Solutions", isDirectory: true)
  }
  func save(page: SolvedPage, jpegs: [Data]) throws -> SavedSolution {
    let id = UUID(), date = Date()
    let folder = Self.directory.appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let pdf = folder.appendingPathComponent("Solution.pdf"), source = folder.appendingPathComponent("Paper.jpg")
    do {
      guard !jpegs.isEmpty else { throw SolverError.message("No source photos were saved.") }
      let images = try jpegs.map { bytes -> UIImage in
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary)
          else { throw SolverError.message("A source photo is unreadable.") }
        return UIImage(cgImage: image)
      }
      let data = try SolutionPDF.render(page: page, sources: images)
      try data.write(to: pdf, options: .atomic)
      for (index, jpeg) in jpegs.enumerated() {
        let path = index == 0 ? source : folder.appendingPathComponent("Paper-\(index + 1).jpg")
        try jpeg.write(to: path, options: .atomic)
      }
      try JSONEncoder().encode(page).write(to: folder.appendingPathComponent("Solution.json"), options: .atomic)
      return SavedSolution(id: id, title: page.title, date: date, pdf: pdf, source: source)
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
  }
  static func history() -> [SavedSolution] {
    let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
    return folders.compactMap { folder in
      guard let id = UUID(uuidString: folder.lastPathComponent),
        let data = try? Data(contentsOf: folder.appendingPathComponent("Solution.json")),
        let page = try? JSONDecoder().decode(SolvedPage.self, from: data),
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("Solution.pdf").path) else { return nil }
      let date = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
      return SavedSolution(id: id, title: page.title, date: date, pdf: folder.appendingPathComponent("Solution.pdf"), source: folder.appendingPathComponent("Paper.jpg"))
    }.sorted { $0.date > $1.date }
  }
}

@MainActor
enum SolutionPDF {
  static func render(page: SolvedPage, source: UIImage?) throws -> Data {
    try render(page: page, sources: source.map { [$0] } ?? [])
  }
  static func render(page: SolvedPage, sources: [UIImage]) throws -> Data {
    let body = NSMutableAttributedString(string: "")
    var keepWithNext: [NSRange] = []
    func append(_ text: String, size: CGFloat = 12, bold: Bool = false, color: UIColor = .black, keep: Bool = false) {
      let start = body.length
      let style = NSMutableParagraphStyle(); style.lineSpacing = 4; style.paragraphSpacing = 6
      body.append(NSAttributedString(string: text + "\n", attributes: [
        .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
        .foregroundColor: color, .paragraphStyle: style]))
      if bold || keep { keepWithNext.append(NSRange(location: start, length: body.length - start)) }
    }
    append(page.title, size: 23, bold: true)
    append("Worked solution • \(Date().formatted(date: .abbreviated, time: .shortened))", size: 10, color: .darkGray)
    if let providers = page.providers { append(providers, size: 10, color: .darkGray) }
    if let coverage = page.coverage {
      append("Coverage checklist", size: 16, bold: true)
      append(coverage)
      for (index, item) in page.problems.enumerated() {
        let pages = (item.sourcePages ?? []).map(String.init).joined(separator: ", ")
        let flag = item.reviewNote?.hasPrefix("NEEDS REVIEW:") == true ? " — NEEDS REVIEW" : ""
        append("\(index + 1). \(item.label ?? "Problem") · source page(s) \(pages)\(flag)", size: 10)
      }
    }
    for (index, problem) in page.problems.enumerated() {
      append(problem.label ?? "Problem \(index + 1)", size: 16, bold: true)
      if let pages = problem.sourcePages {
        append("Source page(s): " + pages.map(String.init).joined(separator: ", "), size: 10, color: .darkGray, keep: true)
      }
      if let note = problem.reviewNote, !note.trimmed.isEmpty {
        append(note, bold: note.hasPrefix("NEEDS REVIEW:"), color: .darkGray)
      }
      append(problem.problem)
      for (step, text) in problem.steps.enumerated() { append("\(step + 1). \(text)") }
      append("Answer", bold: true); append(problem.answer)
      append("Verification", bold: true); append(problem.check)
      append("", size: 6)
    }
    let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let framesetter = CTFramesetterCreateWithAttributedString(body)
    var offset = 0, pageNumber = 0, overflow = false
    let format = UIGraphicsPDFRendererFormat()
    format.documentInfo = [kCGPDFContextTitle as String: page.title, kCGPDFContextCreator as String: "Glasses Solver"]
    let data = UIGraphicsPDFRenderer(bounds: bounds, format: format).pdfData { renderer in
      func chrome() {
        pageNumber += 1
        ("GLASSES SOLVER" as NSString).draw(at: CGPoint(x: 44, y: 24), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 9), .foregroundColor: UIColor.darkGray])
        ("AI-generated • Check the problem transcription and result.     \(pageNumber)" as NSString)
          .draw(at: CGPoint(x: 44, y: 758), withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.darkGray])
      }
      while offset < body.length && pageNumber < 100 {
        renderer.beginPage(); chrome()
        let context = renderer.cgContext
        context.saveGState(); context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: CGRect(x: 44, y: 64, width: 524, height: 670), transform: nil)
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
        context.restoreGState()
        if count == 0 { overflow = true; break }
        offset += count
      }
      if offset < body.length { overflow = true }
      for (sourceIndex, source) in sources.enumerated() {
        renderer.beginPage(); chrome()
        ("Source photograph \(sourceIndex + 1)" as NSString).draw(at: CGPoint(x: 44, y: 56), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 18)])
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
