import Foundation
#if canImport(Compression)
import Compression
#endif

/// Casio fx-CG50 picture files (.g3p): Casio's own "CP, no footer, encrypted" layout, the one used by the calculator's
/// sample pictures (`_Blank.g3p`, `Cans.g3p`, ...). The layout was checked byte for byte against 55 real Casio files; see
/// AI-HANDOFF "Calculator pictures (2.7)". Pictures are 384x192 (the area below the calculator's status bar), 16-bit
/// RGB565, big-endian, top row first.
enum G3P {
  static let width = 384
  static let height = 192

  /// A full file for `pixels` (width x height RGB565 values, row by row).
  static func encode(rgb565 pixels: [UInt16]) -> Data {
    precondition(pixels.count == width * height, "A calculator picture is exactly 384x192 pixels.")
    var raw = Data(capacity: pixels.count * 2)
    for pixel in pixels { raw.append(UInt8(pixel >> 8)); raw.append(UInt8(pixel & 0xFF)) }
    return file(zlibStream: zlib(raw))
  }

  /// The file around a zlib stream (header 78 9C, DEFLATE data, Adler-32 of the pixels): standard header (stored
  /// inverted), "CP" picture header with one section, the image section, then the stream with every byte obfuscated.
  static func file(zlibStream: Data) -> Data {
    let streamLength = zlibStream.count, size = 0xD0 + streamLength
    let b2 = UInt8((size >> 8) & 0xFF), b3 = UInt8(size & 0xFF)
    var header = Data("USBPower".utf8)
    header += [0x7D, 0x00, 0x10, 0x00, 0x10, 0x00, b3 &+ 0x41, 0x01]
    header += be32(size)
    header += [b3 &+ 0xB8] + [UInt8](repeating: 0xFF, count: 7)
    header += [0x7D &+ b2 &+ b3 &+ 0xE9, b3 &+ 0x7B, 0xFF, 0xFF]
    var file = Data(header.map { ~$0 })
    file += [0x43, 0x50, 0x00, 0x01] + [UInt8](repeating: 0, count: 12) // "CP\0\x01"
    file += be32(size - 0x20)
    file += be32(1) // section mask: the image section only
    file += be32(0x18 + streamLength) + [UInt8](repeating: 0, count: 31 * 4)
    file += [0x00, 0x01, 0x00, 0x00] + be32(4 + streamLength)
    file += [0x00, 0x00] + be16(width) + be16(height) + be16(16) // 16-bit colour
    file += [0x01, 0x00, 0x00, 0x00] + be32(streamLength)
    file += Data(zlibStream.map(obfuscate))
    return file
  }

  /// Casio's payload "crypt": rotate left by 3, then invert.
  static func obfuscate(_ byte: UInt8) -> UInt8 { ~((byte << 3) | (byte >> 5)) }
  static func deobfuscate(_ byte: UInt8) -> UInt8 { let value = ~byte; return (value >> 3) | (value << 5) }

  /// An RFC 1950 zlib stream: Apple's DEFLATE where available, otherwise stored (uncompressed) blocks, which every
  /// inflater accepts.
  static func zlib(_ raw: Data) -> Data {
    var stream = Data([0x78, 0x9C])
    stream += deflate(raw) ?? stored(raw)
    stream += be32(Int(adler32(raw)))
    return stream
  }

  static func adler32(_ data: Data) -> UInt32 {
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
    return (b << 16) | a
  }

  /// DEFLATE stored blocks of at most 65535 bytes.
  static func stored(_ raw: Data) -> Data {
    var output = Data(), offset = raw.startIndex
    repeat {
      let length = min(65535, raw.endIndex - offset), last = offset + length == raw.endIndex
      output.append(last ? 1 : 0)
      output += [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8((~length >> 8) & 0xFF)]
      output += raw[offset..<offset + length]
      offset += length
    } while offset < raw.endIndex
    return output
  }

  private static func deflate(_ raw: Data) -> Data? {
    #if canImport(Compression)
    guard !raw.isEmpty else { return nil }
    let capacity = raw.count + 4096
    var output = Data(count: capacity)
    let written = output.withUnsafeMutableBytes { destination in
      raw.withUnsafeBytes { source in
        compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
          source.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
      }
    }
    return written > 0 ? output.prefix(written) : nil
    #else
    return nil
    #endif
  }

  /// Reads a picture written in this layout back to pixels (tests and previews). Returns nil for anything else.
  static func decode(_ file: Data) -> [UInt16]? {
    let bytes = [UInt8](file)
    guard bytes.count > 0xD0, Data(bytes[0..<8].map { ~$0 }) == Data("USBPower".utf8),
      read32(bytes, 0x10, inverted: true) == bytes.count, read32(bytes, 0x34) == 1 else { return nil }
    let w = Int(bytes[0xC2]) << 8 | Int(bytes[0xC3]), h = Int(bytes[0xC4]) << 8 | Int(bytes[0xC5])
    let length = read32(bytes, 0xCC)
    guard w == width, h == height, bytes[0xC7] == 16, 0xD0 + length <= bytes.count, length > 6 else { return nil }
    let stream = bytes[0xD0..<0xD0 + length].map(deobfuscate)
    guard stream[0] == 0x78 else { return nil }
    let body = Data(stream[2..<stream.count - 4])
    guard let raw = inflate(body, size: w * h * 2), raw.count == w * h * 2,
      adler32(raw) == UInt32(read32(Array(stream), stream.count - 4)) else { return nil }
    let r = [UInt8](raw)
    return (0..<w * h).map { UInt16(r[2 * $0]) << 8 | UInt16(r[2 * $0 + 1]) }
  }

  private static func inflate(_ body: Data, size: Int) -> Data? {
    #if canImport(Compression)
    var output = Data(count: size)
    let written = output.withUnsafeMutableBytes { destination in
      body.withUnsafeBytes { source in
        compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size,
          source.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
      }
    }
    return output.prefix(written)
    #else
    // Stored blocks only (what this file writes without Apple's compression).
    var output = Data(), index = body.startIndex
    while index + 5 <= body.endIndex {
      let last = body[index] & 1 == 1, length = Int(body[index + 1]) | Int(body[index + 2]) << 8
      guard body[index] & 0x06 == 0, index + 5 + length <= body.endIndex else { return nil }
      output += body[(index + 5)..<(index + 5 + length)]; index += 5 + length
      if last { return output }
    }
    return nil
    #endif
  }

  private static func be32(_ value: Int) -> [UInt8] {
    [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
  }
  private static func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
  private static func read32(_ bytes: [UInt8], _ offset: Int, inverted: Bool = false) -> Int {
    (0..<4).reduce(0) { $0 << 8 | Int(inverted ? ~bytes[offset + $1] : bytes[offset + $1]) }
  }
}
