import Foundation
import CoreGraphics
import CoreText
import UIKit

/// Solutions as fx-CG50 pictures: one subquestion per 384x192 picture with only its short working and answer, in text
/// large enough to read on the calculator without zooming. Written into one folder that is copied to the calculator.
enum CalculatorPictures {
  /// Body text at 16 px (cap height about 11.5 px at 0.183 mm per pixel) with a 19 px line pitch: 8 lines under a 22 px
  /// header. The left and right margins keep text clear of the Memory app's preview arrows.
  static let bodySize: CGFloat = 16
  static let headerSize: CGFloat = 15
  static let headerHeight = 22
  static let lineHeight = 19
  static let linesPerScreen = 8
  static let left: CGFloat = 22, right: CGFloat = 30
  static var metrics: CalculatorLayout.Metrics {
    CalculatorLayout.Metrics(linesPerScreen: linesPerScreen, maxWidth: Double(CGFloat(G3P.width) - left - right),
      width: { text, style in Double(CalculatorPictures.width(text, font: CalculatorPictures.font(for: style))) })
  }

  /// Writes every picture of `page` into `folder` (created), in the order they page on the calculator. A packet with
  /// more than 200 pictures (the calculator lists at most 200 files per folder) is split into PART1, PART2, ... inside it.
  static func write(_ page: SolvedPage, into folder: URL) throws -> [URL] {
    let metrics = self.metrics
    let screens = page.problems.enumerated().map { number, problem -> [CalculatorLayout.Screen] in
      let unsure = problem.reviewNote?.hasPrefix("NEEDS REVIEW") == true
      // Answers saved before 2.7 have no short working: their steps stand in.
      let brief = (problem.brief?.isEmpty == false ? problem.brief ?? [] : problem.steps).map(clean)
      return CalculatorLayout.screens(label: clean(problem.label ?? "Problem \(number + 1)"), brief: brief,
        answer: clean(problem.answer), unsure: unsure, metrics: metrics)
    }
    let digits = screens.count > 99 ? 3 : 2
    let parts = CalculatorLayout.parts(screens.map(\.count))
    var files: [URL] = []
    for (index, questions) in parts.enumerated() {
      let target = parts.count == 1 ? folder : folder.appendingPathComponent("PART\(index + 1)", isDirectory: true)
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      for question in questions {
        for (page, screen) in screens[question].enumerated() {
          let url = target.appendingPathComponent(CalculatorLayout.fileName(question: question + 1, page: page + 1, digits: digits))
          try G3P.encode(rgb565: render(screen)).write(to: url, options: .atomic)
          files.append(url)
        }
      }
    }
    return files
  }

  /// Any LaTeX as readable Unicode: a calculator user reads linear math.
  static func clean(_ text: String) -> String {
    MathText.readable(text).replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// One picture as 384x192 RGB565 pixels: a dark header bar naming the question (and "page 1/3" on the right), then the
  /// lines in black, the answer in bold dark blue.
  static func render(_ screen: CalculatorLayout.Screen) -> [UInt16] {
    let w = G3P.width, h = G3P.height
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    rgba.withUnsafeMutableBytes { buffer in
      guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
      // Core Graphics measures y from the bottom of the picture.
      context.setFillColor(CGColor(red: 0.07, green: 0.16, blue: 0.40, alpha: 1))
      context.fill(CGRect(x: 0, y: h - headerHeight, width: w, height: headerHeight))
      let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1), headerFont = font(headerSize, bold: true)
      let headerBaseline = CGFloat(h - 16)
      draw(screen.title, in: context, x: 8, baseline: headerBaseline, font: headerFont, color: white)
      if let page = screen.page {
        draw(page, in: context, x: CGFloat(w) - 8 - width(page, font: headerFont), baseline: headerBaseline, font: headerFont, color: white)
      }
      for (index, line) in screen.lines.enumerated() {
        let baseline = CGFloat(h - (headerHeight + 4 + index * lineHeight + 15))
        draw(line.text, in: context, x: left, baseline: baseline, font: font(for: line.style), color: color(for: line.style))
      }
    }
    return (0..<w * h).map { index in
      let r = UInt16(rgba[4 * index]), g = UInt16(rgba[4 * index + 1]), b = UInt16(rgba[4 * index + 2])
      return (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)
    }
  }

  static func width(_ text: String, font: CTFont) -> CGFloat {
    let line = CTLineCreateWithAttributedString(attributed(text, font: font, color: CGColor(red: 0, green: 0, blue: 0, alpha: 1)))
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  }

  private static func draw(_ text: String, in context: CGContext, x: CGFloat, baseline: CGFloat, font: CTFont, color: CGColor) {
    let line = CTLineCreateWithAttributedString(attributed(text, font: font, color: color))
    context.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(line, context)
  }
  private static func attributed(_ text: String, font: CTFont, color: CGColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
  }
  private static func font(_ size: CGFloat, bold: Bool) -> CTFont {
    UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular) as CTFont
  }
  private static func font(for style: CalculatorLayout.Style) -> CTFont {
    font(bodySize, bold: style == .answer)
  }
  /// Black working, the answer in one dark accent, a review note in dark red. Nothing light on white.
  private static func color(for style: CalculatorLayout.Style) -> CGColor {
    switch style {
    case .answer: return CGColor(red: 0.0, green: 0.15, blue: 0.55, alpha: 1)
    case .body: return CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    case .note: return CGColor(red: 0.55, green: 0.0, blue: 0.0, alpha: 1)
    }
  }
}
