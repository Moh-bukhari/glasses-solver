import Foundation
import zlib

// G3P header/obfuscation layout adapted from CasPCE's g3p_converter/g3p.py:
// https://github.com/mdanishharoon/CasPCE
// Copyright (c) 2026 mdanishharoon
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

enum CalculatorExportError: LocalizedError {
  case message(String)
  var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// Native fx-CG picture area: 384×192 pixels (the LCD's other 24 rows belong to OS chrome).
/// RGB565 big-endian, 3C1B picture variant, raw DEFLATE followed by Adler-32.
/// This is a real G3P container, not a renamed PNG/JPEG.
enum G3PCodec {
  static let width = 384
  static let height = 192
  static let pixelByteCount = width * height * 2

  static func encode(rgb565: Data) throws -> Data {
    guard rgb565.count == pixelByteCount else {
      throw CalculatorExportError.message("A calculator image must be 384 × 192 RGB565 pixels.")
    }
    var stream = try deflateRaw(rgb565)
    stream.appendBE(adler32(of: rgb565))
    let payload = Data([0x3C, 0x1B]) + Data(stream.map { byte in
      let inverted = ~byte
      return (inverted << 3) | (inverted >> 5)
    })
    let fileSize = UInt32(0xD0 + payload.count)
    let invertedSize = ~fileSize
    let low = UInt8(truncatingIfNeeded: invertedSize)
    var file = Data(repeating: 0, count: 0xD0)
    file.replaceSubrange(0..<8, with: [0xAA, 0xAC, 0xBD, 0xAF, 0x90, 0x88, 0x9A, 0x8D])
    file[8] = 0x82
    file.replaceSubrange(9..<14, with: [0xFF, 0xEF, 0xFF, 0xEF, 0xFF])
    file[0x0E] = low &+ 0xBF
    file[0x0F] = 0xFE
    file.putBE(invertedSize, at: 0x10)
    file[0x14] = low &+ 0x48
    // CP (obfuscated) variant markers use the non-inverted size bytes.
    // Corroborated against TI-Planet/img2calc's documented CP.g3p format.
    file[0x1C] = UInt8(truncatingIfNeeded: fileSize >> 8) &+ UInt8(truncatingIfNeeded: fileSize) &+ 0xAB
    file[0x1D] = UInt8(truncatingIfNeeded: fileSize) &+ 0x98
    file.replaceSubrange(0x20..<0x26, with: [0x43, 0x50, 0, 1, 0, 0])
    file.putBE(fileSize - 0x20, at: 0x30)
    file.putBE(1, at: 0x34)
    file.putBE(fileSize - 0xB8, at: 0x38)
    file.replaceSubrange(0xB8..<0xBC, with: [0, 1, 0, 0])
    file.putBE(fileSize - 0xCC, at: 0xBC)
    // 16-bit values at C2/C4/C6 are width, height, bits per pixel.
    file[0xC2] = 1; file[0xC3] = 0x80
    file[0xC4] = 0; file[0xC5] = 0xC0
    file[0xC6] = 0; file[0xC7] = 16
    file[0xC8] = 1
    file.putBE(UInt32(payload.count), at: 0xCC)
    file.append(payload)
    return file
  }

  private static func deflateRaw(_ input: Data) throws -> Data {
    var stream = z_stream()
    let initialized = deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
      Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard initialized == Z_OK else { throw CalculatorExportError.message("Calculator image compression could not start.") }
    defer { deflateEnd(&stream) }
    var output = Data(count: Int(deflateBound(&stream, uLong(input.count))))
    let status = input.withUnsafeBytes { inputBytes in
      output.withUnsafeMutableBytes { outputBytes in
        stream.next_in = UnsafeMutablePointer(mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress!)
        stream.avail_in = uInt(inputBytes.count)
        stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress!
        stream.avail_out = uInt(outputBytes.count)
        return deflate(&stream, Z_FINISH)
      }
    }
    guard status == Z_STREAM_END else { throw CalculatorExportError.message("Calculator image compression failed.") }
    output.count = Int(stream.total_out)
    return output
  }

  private static func adler32(of bytes: Data) -> UInt32 {
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in bytes { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
    return (b << 16) | a
  }
}

struct CalculatorArchiveEntry: Sendable {
  let name: String
  let data: Data
}

/// Portable ZIP with stored entries. G3P payloads are already compressed.
/// Fixed DOS date (1980-01-01), UTF-8 names, CRC-32 and central-directory offsets.
enum CalculatorZIP {
  static func archive(entries: [CalculatorArchiveEntry]) throws -> Data {
    guard entries.count < Int(UInt16.max), Set(entries.map(\.name)).count == entries.count else {
      throw CalculatorExportError.message("The calculator archive has duplicate names or too many files.")
    }
    var file = Data(), central = Data()
    for entry in entries {
      let name = Data(entry.name.utf8)
      guard !entry.name.isEmpty, !entry.name.contains("/"), !entry.name.contains("\\"),
        name.count < Int(UInt16.max), entry.data.count < Int(UInt32.max), file.count < Int(UInt32.max) else {
        throw CalculatorExportError.message("The calculator archive contains an invalid file entry.")
      }
      let offset = UInt32(file.count), size = UInt32(entry.data.count)
      let checksum = entry.data.withUnsafeBytes { bytes in
        UInt32(crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
      }
      file.appendLE(UInt32(0x04034B50)); file.appendLE(UInt16(20)); file.appendLE(UInt16(0x0800))
      file.appendLE(UInt16(0)); file.appendLE(UInt16(0)); file.appendLE(UInt16(0x0021))
      file.appendLE(checksum); file.appendLE(size); file.appendLE(size)
      file.appendLE(UInt16(name.count)); file.appendLE(UInt16(0)); file.append(name); file.append(entry.data)
      central.appendLE(UInt32(0x02014B50)); central.appendLE(UInt16(20)); central.appendLE(UInt16(20))
      central.appendLE(UInt16(0x0800)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
      central.appendLE(UInt16(0x0021)); central.appendLE(checksum); central.appendLE(size); central.appendLE(size)
      central.appendLE(UInt16(name.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
      central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0))
      central.appendLE(offset); central.append(name)
    }
    guard file.count + central.count + 22 < Int(UInt32.max) else {
      throw CalculatorExportError.message("The calculator archive is too large.")
    }
    let offset = UInt32(file.count)
    file.append(central)
    file.appendLE(UInt32(0x06054B50)); file.appendLE(UInt16(0)); file.appendLE(UInt16(0))
    file.appendLE(UInt16(entries.count)); file.appendLE(UInt16(entries.count))
    file.appendLE(UInt32(central.count)); file.appendLE(offset); file.appendLE(UInt16(0))
    return file
  }
}

private extension Data {
  mutating func appendBE(_ value: UInt32) {
    append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
  }
  mutating func putBE(_ value: UInt32, at offset: Int) {
    var bytes = Data(); bytes.appendBE(value); replaceSubrange(offset..<(offset + 4), with: bytes)
  }
  mutating func appendLE(_ value: UInt16) {
    append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
  }
  mutating func appendLE(_ value: UInt32) {
    append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
      UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
  }
}
