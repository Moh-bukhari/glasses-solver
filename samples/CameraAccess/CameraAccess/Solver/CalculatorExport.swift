import Foundation
import UIKit
import CoreText

struct CalculatorImagePage: Sendable {
  let filename: String
  let label: String
  let pageNumber: Int
  let pageCount: Int
  let previewPNG: Data
  let g3p: Data
}

/// Render at the calculator's native resolution. Text is wrapped and paginated,
/// never shrunk to cram a long solution onto one screen.
@MainActor
enum CalculatorExport {
  static let width = G3PCodec.width
  static let height = G3PCodec.height
  static let bodyFontSize: CGFloat = 19
  static let margin: CGFloat = 8
  static let maximumPages = 512

  struct Line {
    let text: String
    let bold: Bool
  }
  struct Layout {
    let label: String
    let headerLines: [String]
    let bodyTop: CGFloat
    let lineHeight: CGFloat
    let pages: [[Line]]
  }

  static func render(page: SolvedPage) throws -> [CalculatorImagePage] {
    guard !page.problems.isEmpty, page.problems.count <= 999 else {
      throw CalculatorExportError.message("There are no question results to export, or the packet is too large.")
    }
    var result: [CalculatorImagePage] = []
    for (index, problem) in page.problems.enumerated() {
      try Task.checkCancellation()
      let layout = try layout(problem: problem, number: index + 1)
      guard result.count + layout.pages.count <= maximumPages else {
        throw CalculatorExportError.message("This solution exceeds 512 calculator screens. Split it into smaller packets; no text was cut off.")
      }
      for (pageIndex, lines) in layout.pages.enumerated() {
        try Task.checkCancellation()
        let rendered: CalculatorImagePage = try autoreleasepool {
          let image = draw(layout: layout, lines: lines, pageNumber: pageIndex + 1)
          guard let preview = image.pngData(), let cgImage = image.cgImage else {
            throw CalculatorExportError.message("A calculator image could not be rendered.")
          }
          let pixels = try rgb565(image: cgImage)
          return CalculatorImagePage(filename: String(format: "Q%03dP%03d.g3p", index + 1, pageIndex + 1),
            label: layout.label, pageNumber: pageIndex + 1, pageCount: layout.pages.count,
            previewPNG: preview, g3p: try G3PCodec.encode(rgb565: pixels))
        }
        result.append(rendered)
      }
    }
    return result
  }

  static func archive(pages: [CalculatorImagePage]) throws -> Data {
    guard !pages.isEmpty else { throw CalculatorExportError.message("No calculator images were produced.") }
    let index = """
    GLASSES SOLVER — CASIO fx-CG50 PICTURES

    Unzip this archive on your computer. Copy the .g3p files to the calculator's
    storage memory over USB. Each file is one native 384 x 192 pixel picture.
    The full question label and Page n/m are also printed inside every image.
    Keep all pages for a question together. Q001 etc. are export sequence numbers;
    the original question/subquestion label is shown below and inside the picture.

    Filename\tQuestion / subquestion\tPage
    """ + "\n" + pages.map {
      "\($0.filename)\t\(oneLine($0.label))\t\($0.pageNumber)/\($0.pageCount)"
    }.joined(separator: "\n") + "\n"
    return try CalculatorZIP.archive(entries: pages.map { CalculatorArchiveEntry(name: $0.filename, data: $0.g3p) }
      + [CalculatorArchiveEntry(name: "INDEX.TXT", data: Data(index.utf8))])
  }

  static func layout(problem: SolvedProblem, number: Int) throws -> Layout {
    let label = oneLine(problem.label?.trimmed.isEmpty == false ? problem.label! : "Question \(number)")
    let headerFont = UIFont.systemFont(ofSize: 17, weight: .bold)
    let headerLines = try wrap(label, font: headerFont)
    let headerHeight = ceil(headerFont.lineHeight)
    let bodyTop = margin + CGFloat(headerLines.count) * headerHeight + 7
    let lineHeight = ceil(UIFont.systemFont(ofSize: bodyFontSize, weight: .semibold).lineHeight) + 1
    // Footer sits in its own band. At least one full-size body line must fit.
    let available = CGFloat(height) - 24 - bodyTop
    let linesPerPage = Int(floor(available / lineHeight))
    guard linesPerPage >= 1 else {
      throw CalculatorExportError.message("The question label is too long for a calculator screen: \(label). Use a shorter question label.")
    }
    var lines: [Line] = []
    func append(_ text: String, bold: Bool) throws {
      for line in try wrap(text, font: UIFont.systemFont(ofSize: bodyFontSize, weight: bold ? .semibold : .regular)) {
        lines.append(Line(text: line, bold: bold))
      }
    }
    if let note = problem.reviewNote, !note.trimmed.isEmpty {
      // Never make an unresolved answer look like a confidently solved result.
      try append(note, bold: true)
    }
    for step in problem.steps where !step.trimmed.isEmpty { try append(step, bold: false) }
    if !problem.answer.trimmed.isEmpty { try append(problem.answer, bold: true) }
    if lines.isEmpty { try append("No readable answer available.", bold: true) }
    let pages = stride(from: 0, to: lines.count, by: linesPerPage).map {
      Array(lines[$0..<min($0 + linesPerPage, lines.count)])
    }
    guard pages.count <= 999 else {
      throw CalculatorExportError.message("\(label) needs more than 999 calculator pictures. Shorten its answer before exporting.")
    }
    return Layout(label: label, headerLines: headerLines, bodyTop: bodyTop, lineHeight: lineHeight, pages: pages)
  }

  /// CoreText measures the actual glyphs. Cluster fallback also handles a long
  /// unbroken equation, instead of letting it run off the right edge.
  static func wrap(_ text: String, font: UIFont) throws -> [String] {
    let maxWidth = CGFloat(width) - 2 * margin - 2
    var lines: [String] = []
    for paragraph in text.components(separatedBy: .newlines) {
      let content = paragraph.trimmingCharacters(in: .whitespaces)
      guard !content.isEmpty else { continue }
      let attributed = NSAttributedString(string: content, attributes: [.font: font])
      let typesetter = CTTypesetterCreateWithAttributedString(attributed)
      let string = content as NSString
      var position = 0
      while position < string.length {
        var count = CTTypesetterSuggestLineBreak(typesetter, position, Double(maxWidth))
        if count <= 0 { count = CTTypesetterSuggestClusterBreak(typesetter, position, Double(maxWidth)) }
        guard count > 0 else { throw CalculatorExportError.message("A symbol cannot fit on the calculator screen.") }
        var line = CTTypesetterCreateLine(typesetter, CFRange(location: position, length: count))
        // Include italic/symbol overhangs as well as advances when checking fit.
        var bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        if bounds.width > maxWidth {
          count = CTTypesetterSuggestClusterBreak(typesetter, position, Double(maxWidth - 3))
          guard count > 0 else { throw CalculatorExportError.message("A symbol cannot fit on the calculator screen.") }
          line = CTTypesetterCreateLine(typesetter, CFRange(location: position, length: count))
          bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        }
        guard bounds.width <= maxWidth else { throw CalculatorExportError.message("A formula could not wrap within the calculator screen.") }
        let piece = string.substring(with: NSRange(location: position, length: count)).trimmingCharacters(in: .whitespaces)
        if !piece.isEmpty { lines.append(piece) }
        position += count
      }
    }
    return lines
  }

  private static func draw(layout: Layout, lines: [Line], pageNumber: Int) -> UIImage {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
    let size = CGSize(width: width, height: height)
    return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
      UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
      let context = renderer.cgContext
      context.setShouldAntialias(true)
      let headerFont = UIFont.systemFont(ofSize: 17, weight: .bold)
      for (index, line) in layout.headerLines.enumerated() {
        drawText(line, font: headerFont, top: margin + CGFloat(index) * ceil(headerFont.lineHeight), in: context)
      }
      context.setStrokeColor(UIColor.black.cgColor); context.setLineWidth(1)
      context.move(to: CGPoint(x: margin, y: layout.bodyTop - 4.5))
      context.addLine(to: CGPoint(x: CGFloat(width) - margin, y: layout.bodyTop - 4.5)); context.strokePath()
      for (index, line) in lines.enumerated() {
        drawText(line.text, font: UIFont.systemFont(ofSize: bodyFontSize, weight: line.bold ? .semibold : .regular),
          top: layout.bodyTop + CGFloat(index) * layout.lineHeight, in: context)
      }
      let footer = "Page \(pageNumber)/\(layout.pages.count)"
      drawText(footer, font: UIFont.systemFont(ofSize: 14, weight: .semibold), top: CGFloat(height) - 21, in: context)
    }
  }

  private static func drawText(_ text: String, font: UIFont, top: CGFloat, in context: CGContext) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
      attributes: [.font: font, .foregroundColor: UIColor.black]))
    let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    context.saveGState()
    context.textMatrix = .identity
    context.translateBy(x: margin - min(bounds.minX, 0), y: top + font.ascender)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
  }

  static func rgb565(image: CGImage) throws -> Data {
    guard image.width == width, image.height == height else {
      throw CalculatorExportError.message("Calculator pictures must be rendered at their native 384 × 192 size.")
    }
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let valid = rgba.withUnsafeMutableBytes { bytes -> Bool in
      guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
      // CGImage drawing preserves its top-to-bottom byte order in this bitmap.
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard valid else { throw CalculatorExportError.message("Calculator pixels could not be converted.") }
    var pixels = Data(capacity: G3PCodec.pixelByteCount)
    for offset in stride(from: 0, to: rgba.count, by: 4) {
      let value = (UInt16(rgba[offset] & 0xF8) << 8) | (UInt16(rgba[offset + 1] & 0xFC) << 3) | UInt16(rgba[offset + 2] >> 3)
      pixels.append(UInt8(value >> 8)); pixels.append(UInt8(value & 0xFF))
    }
    return pixels
  }

  private static func oneLine(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}
