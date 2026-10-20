import XCTest
import Foundation
@testable import CameraAccess
#if canImport(UIKit)
import UIKit
import CoreGraphics
#endif

/// fx-CG50 pictures: the file layout (checked against Casio's own file), the layout of short solutions into pictures,
/// and, on iOS, the rendered pixels.
final class CalculatorPictureTests: XCTestCase {
  /// Casio's own all-white picture, `_Blank.g3p` from the calculator's sample folder (374 bytes).
  static let casioBlank =
    "aaacbdaf90889a8d82ffefffefff48fefffffe89d100000000000000220e000043500001000000000000000000000000" +
    "0000015600000001000000be000000000000000000000000000000000000000000000000000000000000000000000000" +
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
    "0000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000aa" +
    "0000018000c0001001000000000000a63c1b90f176f7ffffffe9fa08b2c49787faffffffffffffffffffffffffffffff" +
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" +
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" +
    "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffb47e77c25f05b"

  private func bytes(_ hex: String) -> Data {
    var data = Data(), index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      data.append(UInt8(hex[index..<next], radix: 16)!); index = next
    }
    return data
  }

  func testTheFileLayoutMatchesCasiosOwnPictureByteForByte() {
    let casio = bytes(Self.casioBlank)
    XCTAssertEqual(casio.count, 374)
    let stream = Data(casio[0xD0...].map(G3P.deobfuscate))
    XCTAssertEqual(Array(stream.prefix(2)), [0x78, 0x9C], "A zlib stream after undoing Casio's obfuscation.")
    XCTAssertEqual(G3P.file(zlibStream: stream), casio, "Header, size fields, control bytes and section table as Casio writes them.")
    let white = Data(repeating: 0xFF, count: 384 * 192 * 2), adler = G3P.adler32(white)
    XCTAssertEqual(Array(stream.suffix(4)), [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
  }
  func testObfuscationIsCasiosByteMapAndRoundTrips() {
    XCTAssertEqual(G3P.obfuscate(0x78), 0x3C); XCTAssertEqual(G3P.obfuscate(0x9C), 0x1B)
    XCTAssertEqual(G3P.obfuscate(0x38), 0x3E); XCTAssertEqual(G3P.obfuscate(0x8D), 0x93)
    for byte in 0...255 { XCTAssertEqual(G3P.deobfuscate(G3P.obfuscate(UInt8(byte))), UInt8(byte)) }
  }
  func testPicturesDecodeBackToTheirPixels() throws {
    let pixels = (0..<G3P.width * G3P.height).map { index -> UInt16 in
      let x = index % G3P.width, y = index / G3P.width
      return x < 8 && y < 8 ? 0xF800 : (x + y) % 37 == 0 ? 0x0000 : 0xFFFF
    }
    let file = G3P.encode(rgb565: pixels)
    XCTAssertEqual(try XCTUnwrap(G3P.decode(file)), pixels, "Red top-left corner, diagonal lines, white elsewhere.")
    let size = file.count, stored = Data(file.prefix(0x20).map { ~$0 })
    XCTAssertEqual(stored.prefix(8), Data("USBPower".utf8))
    XCTAssertEqual(Int(stored[0x10]) << 24 | Int(stored[0x11]) << 16 | Int(stored[0x12]) << 8 | Int(stored[0x13]), size)
    XCTAssertEqual(Array(file[0xC2...0xC7]), [0x01, 0x80, 0x00, 0xC0, 0x00, 0x10], "384 x 192, 16-bit")
  }
  func testStoredBlocksHoldAnyLength() {
    let raw = Data((0..<70_000).map { UInt8($0 % 251) }), blocks = G3P.stored(raw)
    XCTAssertEqual(blocks.count, raw.count + 2 * 5, "Two stored blocks of at most 65535 bytes.")
    XCTAssertEqual(blocks[0], 0); XCTAssertEqual(blocks[65_535 + 5], 1, "Only the last block is final.")
  }

  // MARK: Layout

  /// 8 px per character, 10 characters per line, 3 lines per picture.
  private let metrics = CalculatorLayout.Metrics(linesPerScreen: 3, maxWidth: 80, width: { text, _ in Double(text.count * 8) })
  func testEachSubquestionGetsItsOwnPicturesNamedAndNumbered() {
    let short = CalculatorLayout.screens(label: "3(b)", brief: ["F = ma"], answer: "9 N", unsure: false, metrics: metrics)
    XCTAssertEqual(short, [CalculatorLayout.Screen(title: "Q3(b)", page: nil,
      lines: [.init(text: "F = ma", style: .body), .init(text: "Ans: 9 N", style: .answer)])])
    let long = CalculatorLayout.screens(label: "Q4", brief: ["v = u + at", "= 2 + 3·4", "= 14"], answer: "14 m/s", unsure: true,
      metrics: metrics)
    XCTAssertEqual(long.map(\.title), ["Q4", "Q4"], "Every picture says which question it is.")
    XCTAssertEqual(long.map(\.page), ["page 1/2", "page 2/2"])
    XCTAssertEqual(long.flatMap(\.lines).map(\.text), ["v = u + at", "= 2 + 3·4", "= 14", "Ans: 14", "  m/s", "Unsure: check the PDF"],
      "A long answer wraps onto the next line instead of running off the screen.")
    XCTAssertEqual(CalculatorLayout.title(for: "Problem 2"), "Problem 2")
  }
  func testWrappingNeverDropsText() {
    let lines = CalculatorLayout.wrap("a = 123456789012345 + b", style: .body, metrics: metrics, indent: "  ")
    XCTAssertTrue(lines.allSatisfy { $0.count <= 10 }, "\(lines)")
    XCTAssertEqual(lines.joined().filter { !$0.isWhitespace }, "a=123456789012345+b")
  }
  func testFileAndFolderNamesFitTheCalculatorAndSortInOrder() {
    let names = [(1, 1), (1, 2), (2, 1), (10, 1), (10, 12)].map { CalculatorLayout.fileName(question: $0.0, page: $0.1) }
    XCTAssertEqual(names, ["Q01_01.g3p", "Q01_02.g3p", "Q02_01.g3p", "Q10_01.g3p", "Q10_12.g3p"])
    XCTAssertEqual(names, names.sorted(), "The calculator lists files alphabetically.")
    XCTAssertTrue(names.allSatisfy { $0.split(separator: ".")[0].count <= 8 }, "8.3 names show in full.")
    let date = Date(timeIntervalSince1970: 1_792_000_000), utc = TimeZone(identifier: "UTC")!
    XCTAssertEqual(CalculatorLayout.folderName(date: date, taken: [], timeZone: utc), "SOL1014A")
    XCTAssertEqual(CalculatorLayout.folderName(date: date, taken: ["SOL1014A"], timeZone: utc), "SOL1014B")
    let allLetters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { "SOL1014" + String($0) })
    XCTAssertEqual(CalculatorLayout.folderName(date: date, taken: allLetters, timeZone: utc), "S1014000",
      "After 26 packets in a day the name is still new and 8 characters.")
    let big = [99, 100, 101].map { CalculatorLayout.fileName(question: $0, page: 1, digits: 3) }
    XCTAssertEqual(big, ["Q099_01.g3p", "Q100_01.g3p", "Q101_01.g3p"]); XCTAssertEqual(big, big.sorted())
  }
  func testHugePacketsAreSplitIntoPartsOfAtMost200Pictures() {
    XCTAssertEqual(CalculatorLayout.parts([1, 2, 3]), [[0, 1, 2]])
    let parts = CalculatorLayout.parts(Array(repeating: 3, count: 100)) // 300 pictures
    XCTAssertEqual(parts.map(\.count), [66, 34], "66 questions x 3 pages = 198; a question is never split.")
    XCTAssertEqual(parts.flatMap { $0 }, Array(0..<100))
  }

  #if canImport(UIKit)
  // MARK: Rendering (iOS)

  private func pixel(_ pixels: [UInt16], _ x: Int, _ y: Int) -> UInt16 { pixels[y * G3P.width + x] }
  private func isDark(_ value: UInt16) -> Bool { (value >> 11) < 16 && ((value >> 5) & 0x3F) < 32 && (value & 0x1F) < 16 }

  func testPicturesKeepEverythingInsideTheScreenAndReadable() throws {
    let screen = CalculatorLayout.Screen(title: "Q3(b)", page: "page 1/2",
      lines: (0..<CalculatorPictures.linesPerScreen).map { .init(text: "x² + 3x − 4 = 0 ⇒ x = 1, x = −4", style: $0 == 7 ? .answer : .body) })
    let pixels = CalculatorPictures.render(screen)
    XCTAssertEqual(pixels.count, G3P.width * G3P.height)
    XCTAssertTrue(isDark(pixel(pixels, 2, 2)), "The header bar is dark")
    let body = (CalculatorPictures.headerHeight + 2)..<G3P.height
    XCTAssertTrue(body.contains { y in (30..<200).contains { x in isDark(pixel(pixels, x, y)) } }, "Text is drawn")
    for y in body {
      for x in Array(0..<16) + Array((G3P.width - 16)..<G3P.width) {
        XCTAssertEqual(pixel(pixels, x, y), 0xFFFF, "Margins stay clear of the Memory preview arrows (\(x), \(y))")
      }
    }
    for x in 0..<G3P.width { XCTAssertEqual(pixel(pixels, x, G3P.height - 1), 0xFFFF, "Nothing touches the bottom edge") }
    let file = G3P.encode(rgb565: pixels)
    XCTAssertLessThan(file.count, 40_000, "Compressed, not stored")
    XCTAssertEqual(try XCTUnwrap(G3P.decode(file)), pixels)
  }
  func testAPacketBecomesOneFolderOfPicturesInPacketOrder() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SOL\(UUID().uuidString.prefix(5))")
    defer { try? FileManager.default.removeItem(at: folder) }
    let long = (1...20).map { "= step \($0) of a long working line" }
    let page = SolvedPage(readable: true, retakeReason: "", title: "Kinematics", problems: [
      SolvedProblem(problem: "Find v", steps: ["Full explanation."], answer: "$v = 7.7\\ \\mathrm{m/s}$", check: "ok",
        label: "1(a)", brief: ["v = √(2gh)", "= √(2·9.81·3)"]),
      SolvedProblem(problem: "Long one", steps: ["Full explanation."], answer: "42", check: "ok", label: "1(b)", brief: long)])
    let files = try CalculatorPictures.write(page, into: folder)
    let names = files.map(\.lastPathComponent)
    XCTAssertEqual(names.first, "Q01_01.g3p")
    XCTAssertTrue(names.dropFirst().allSatisfy { $0.hasPrefix("Q02_") } && names.count >= 4, "\(names)")
    for file in files { XCTAssertNotNil(G3P.decode(try Data(contentsOf: file)), file.lastPathComponent) }
    let attachment = XCTAttachment(data: try Data(contentsOf: files[0]), uniformTypeIdentifier: "public.data")
    attachment.name = "Q01_01.g3p"; attachment.lifetime = .keepAlways; add(attachment)
  }
  #endif
}
