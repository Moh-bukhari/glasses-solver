@testable import CameraAccess
import XCTest
import UIKit
import zlib

@MainActor
final class CalculatorExportTests: XCTestCase {
  func testG3PIsAFullNativeContainerWithIndependentlyInflatablePixels() throws {
    let pixels = Data((0..<384 * 192 * 2).map { UInt8(truncatingIfNeeded: $0 * 17 + $0 / 31) })
    let data = try G3PCodec.encode(rgb565: pixels)
    XCTAssertEqual(Array(data.prefix(8)), [0xAA, 0xAC, 0xBD, 0xAF, 0x90, 0x88, 0x9A, 0x8D])
    XCTAssertEqual(data[8], 0x82)
    XCTAssertEqual(~readBE(data, 0x10, 4), UInt32(data.count))
    XCTAssertEqual(readBE(data, 0x30, 4), UInt32(data.count - 0x20))
    XCTAssertEqual(readBE(data, 0x38, 4), UInt32(data.count - 0xB8))
    XCTAssertEqual(readBE(data, 0xBC, 4), UInt32(data.count - 0xCC))
    XCTAssertEqual(readBE(data, 0xC0, 4), 384)
    XCTAssertEqual(readBE(data, 0xC4, 2), 192)
    XCTAssertEqual(readBE(data, 0xC6, 2), 16)
    XCTAssertEqual(readBE(data, 0xCC, 4), UInt32(data.count - 0xD0))
    XCTAssertEqual(Array(data[0xD0..<0xD2]), [0x3C, 0x1B])
    // CP variant markers corroborated against TI-Planet and an on-device fixture.
    XCTAssertEqual(data[0x1C], UInt8(truncatingIfNeeded: (data.count >> 8) + data.count + 0xAB))
    XCTAssertEqual(data[0x1D], UInt8(truncatingIfNeeded: data.count + 0x98))
    // Decode through zlib's wrapped-stream API, which checks its own Adler-32.
    XCTAssertEqual(try inflatedPixels(data), pixels)
    var corrupt = data
    corrupt[corrupt.count - 1] ^= 0x08
    XCTAssertThrowsError(try inflatedPixels(corrupt))
    XCTAssertThrowsError(try G3PCodec.encode(rgb565: Data(repeating: 0, count: 100)))
  }

  func testRGB565KeepsTopBottomAndColorChannels() throws {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
    let image = UIGraphicsImageRenderer(size: CGSize(width: 384, height: 192), format: format).image { renderer in
      UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 384, height: 192))
      UIColor.red.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
      UIColor.blue.setFill(); renderer.fill(CGRect(x: 372, y: 180, width: 12, height: 12))
    }
    let pixels = try CalculatorExport.rgb565(image: XCTUnwrap(image.cgImage))
    XCTAssertEqual(readBE(pixels, 0, 2), 0xF800)
    XCTAssertEqual(readBE(pixels, (384 * 191 + 383) * 2, 2), 0x001F)
    XCTAssertEqual(readBE(pixels, (384 * 90 + 100) * 2, 2), 0xFFFF)
  }

  func testLongEquationsPaginateWithoutShrinkingOrLosingContent() throws {
    let longEquation = (1...35).map { "\($0)x^\($0)" }.joined(separator: "+") + "=123456789"
    let problem = SolvedProblem(problem: "Do not include the question transcription.",
      steps: [longEquation, "x = (12 + 4)/8", "x = 2"], answer: "x = 2 kg", check: "Do not print verification prose.",
      label: "Question 12(b)(iii)")
    let layout = try CalculatorExport.layout(problem: problem, number: 1)
    let content = layout.pages.flatMap { $0 }.map(\.text).joined()
    XCTAssertTrue(content.contains(longEquation))
    XCTAssertTrue(content.contains("x = 2 kg"))
    XCTAssertFalse(content.contains("transcription"))
    XCTAssertFalse(content.contains("verification"))
    XCTAssertGreaterThan(layout.pages.count, 1)
    XCTAssertEqual(CalculatorExport.bodyFontSize, 19)
    for lines in layout.pages {
      XCTAssertLessThanOrEqual(layout.bodyTop + CGFloat(lines.count) * layout.lineHeight, 168)
    }
    let pages = try CalculatorExport.render(page: SolvedPage(readable: true, retakeReason: "", title: "Math", problems: [problem]))
    XCTAssertEqual(pages.count, layout.pages.count)
    XCTAssertEqual(pages.map(\.pageNumber), Array(1...pages.count))
    for page in pages {
      XCTAssertEqual(page.label, "Question 12(b)(iii)")
      XCTAssertEqual(page.pageCount, pages.count)
      XCTAssertLessThanOrEqual(URL(fileURLWithPath: page.filename).deletingPathExtension().lastPathComponent.count, 8)
      let image = try XCTUnwrap(UIImage(data: page.previewPNG)?.cgImage)
      XCTAssertEqual(image.width, 384); XCTAssertEqual(image.height, 192)
      XCTAssertEqual(try inflatedPixels(page.g3p), try CalculatorExport.rgb565(image: image))
    }
  }

  func testEachSubquestionStartsANewImageAndResetsPageNumbers() throws {
    let problems = ["Q1(a)", "Q1(b)"].map {
      SolvedProblem(problem: "", steps: [], answer: "42", check: "", label: $0)
    }
    let pages = try CalculatorExport.render(page: SolvedPage(readable: true, retakeReason: "", title: "Quiz", problems: problems))
    XCTAssertEqual(pages.map(\.filename), ["Q001P001.g3p", "Q002P001.g3p"])
    XCTAssertEqual(pages.map(\.label), ["Q1(a)", "Q1(b)"])
    XCTAssertEqual(pages.map(\.pageNumber), [1, 1])
    XCTAssertEqual(pages.map(\.pageCount), [1, 1])
  }

  func testLongQuestionLabelAndUnresolvedStatusAreKept() throws {
    let label = "Question 16 part (b) continuation from the second diagram"
    let problem = SolvedProblem(problem: "", steps: [], answer: "Cannot determine x.", check: "", label: label,
      reviewNote: "NEEDS REVIEW: the angle value is unreadable in all photos.")
    let layout = try CalculatorExport.layout(problem: problem, number: 1)
    XCTAssertEqual(layout.headerLines.joined(separator: " "), label)
    XCTAssertGreaterThan(layout.headerLines.count, 1)
    let content = layout.pages.flatMap { $0 }.map(\.text).joined(separator: " ")
    XCTAssertTrue(content.contains("NEEDS REVIEW"))
    XCTAssertTrue(content.contains("unreadable in all photos"))
  }

  func testUnicodeAndLongIdentifiersWrapWithinActualGlyphBounds() throws {
    let text = "θ = 30°; √(a²+b²) ≤ 10; ∫ x dx = x²/2 + C; " + String(repeating: "αβγδ", count: 40)
    let lines = try CalculatorExport.wrap(text, font: UIFont.systemFont(ofSize: 19))
    XCTAssertEqual(lines.joined().filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace })
    XCTAssertGreaterThan(lines.count, 1)
  }

  func testArchiveContainsAllNativePagesAndLabelIndex() throws {
    let problem = SolvedProblem(problem: "", steps: [], answer: "7", check: "", label: "Question 2(a)")
    let pages = try CalculatorExport.render(page: SolvedPage(readable: true, retakeReason: "", title: "Test", problems: [problem]))
    let archive = try CalculatorExport.archive(pages: pages)
    let entries = try storedZIPEntries(archive)
    XCTAssertEqual(Set(entries.keys), ["Q001P001.g3p", "INDEX.TXT"])
    XCTAssertEqual(entries["Q001P001.g3p"], pages[0].g3p)
    let index = String(decoding: try XCTUnwrap(entries["INDEX.TXT"]), as: UTF8.self)
    XCTAssertTrue(index.contains("Q001P001.g3p\tQuestion 2(a)\t1/1"))
    XCTAssertThrowsError(try CalculatorZIP.archive(entries: [.init(name: "../a.g3p", data: Data())]))
    XCTAssertThrowsError(try CalculatorZIP.archive(entries: [.init(name: "a", data: Data()), .init(name: "a", data: Data())]))
  }

  private func readBE(_ data: Data, _ start: Int, _ count: Int) -> UInt32 {
    data[start..<(start + count)].reduce(0) { ($0 << 8) | UInt32($1) }
  }
  private func readLE(_ data: Data, _ start: Int, _ count: Int) -> UInt32 {
    data[start..<(start + count)].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
  }
  private func inflatedPixels(_ file: Data) throws -> Data {
    let stream = Data(file.dropFirst(0xD0).map { ~(($0 >> 3) | ($0 << 5)) })
    var pixels = Data(count: 384 * 192 * 2), length = uLongf(384 * 192 * 2)
    let status = stream.withUnsafeBytes { source in
      pixels.withUnsafeMutableBytes { destination in
        uncompress(destination.bindMemory(to: Bytef.self).baseAddress, &length,
          source.bindMemory(to: Bytef.self).baseAddress, uLong(source.count))
      }
    }
    guard status == Z_OK, length == pixels.count else { throw CalculatorExportError.message("Invalid G3P stream/checksum") }
    return pixels
  }
  private func storedZIPEntries(_ archive: Data) throws -> [String: Data] {
    var offset = 0, entries: [String: Data] = [:]
    while offset + 30 <= archive.count && readLE(archive, offset, 4) == 0x04034B50 {
      XCTAssertEqual(readLE(archive, offset + 8, 2), 0)
      let size = Int(readLE(archive, offset + 18, 4)), nameSize = Int(readLE(archive, offset + 26, 2))
      let extraSize = Int(readLE(archive, offset + 28, 2)), start = offset + 30 + nameSize + extraSize
      guard start + size <= archive.count else { throw CalculatorExportError.message("Truncated ZIP") }
      let name = String(decoding: archive[(offset + 30)..<(offset + 30 + nameSize)], as: UTF8.self)
      entries[name] = Data(archive[start..<(start + size)])
      offset = start + size
    }
    XCTAssertEqual(readLE(archive, offset, 4), 0x02014B50)
    XCTAssertEqual(readLE(archive, archive.count - 22, 4), 0x06054B50)
    XCTAssertEqual(Int(readLE(archive, archive.count - 12, 2)), entries.count)
    return entries
  }
}
