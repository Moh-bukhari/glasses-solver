import Foundation
import UIKit
import ImageIO

struct CapturedPage: Identifiable {
  let id: UUID
  let url: URL
  /// Decodes from disk; cache the result rather than calling this from a view body.
  func loadThumbnail() -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 360, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
  }
}

/// Atomic manifest swaps keep the old draft valid if an interrupted write fails.
@MainActor
struct ScanDraftStore {
  let directory: URL
  init(directory: URL? = nil) {
    self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ScanDraft", isDirectory: true)
  }
  private var manifest: URL { directory.appendingPathComponent("pages.json") }
  private var solvedMarker: URL { directory.appendingPathComponent("solved") }
  /// Readable after the first unlock, so solving and the PDF can finish if the phone locks meanwhile.
  static let protection: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication
  /// The draft is the source of a finished PDF until the next packet starts or a page is edited.
  var isSolved: Bool { FileManager.default.fileExists(atPath: solvedMarker.path) }
  func markSolved() throws { try Data().write(to: solvedMarker, options: [.atomic, Self.protection]) }
  func load() -> [CapturedPage] {
    guard let data = try? Data(contentsOf: manifest), let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
    let pages = ids.map { CapturedPage(id: $0, url: directory.appendingPathComponent("\($0).jpg")) }
      .filter { FileManager.default.fileExists(atPath: $0.url.path) }
    // Drafts saved by 1.x used complete protection, which is unreadable while the phone is locked.
    for url in pages.map(\.url) + [manifest] {
      try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
    return pages
  }
  func add(_ jpeg: Data, to pages: [CapturedPage], replacing index: Int?) throws -> [CapturedPage] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = UUID(), url = directory.appendingPathComponent("\(id).jpg")
    try jpeg.write(to: url, options: [.atomic, Self.protection])
    try? FileManager.default.removeItem(at: solvedMarker)
    var updated = pages
    if let index, updated.indices.contains(index) { updated[index] = CapturedPage(id: id, url: url) }
    else { updated.append(CapturedPage(id: id, url: url)) }
    do { try save(updated) }
    catch { try? FileManager.default.removeItem(at: url); throw error }
    if let index, pages.indices.contains(index) { try? FileManager.default.removeItem(at: pages[index].url) }
    return updated
  }
  func remove(at index: Int, from pages: [CapturedPage]) throws -> [CapturedPage] {
    guard pages.indices.contains(index) else { return pages }
    var updated = pages; let old = updated.remove(at: index)
    try? FileManager.default.removeItem(at: solvedMarker)
    try save(updated); try? FileManager.default.removeItem(at: old.url); return updated
  }
  func clear() throws {
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
  }
  private func save(_ pages: [CapturedPage]) throws {
    try JSONEncoder().encode(pages.map(\.id)).write(to: manifest, options: [.atomic, Self.protection])
  }
}
