import Foundation
import UIKit
import ImageIO

struct CapturedPage: Identifiable {
  let id: UUID
  /// Every photo of the page in capture order: one still, or several close-up frames of its parts.
  let frames: [URL]
  /// The first photo: the page's thumbnail.
  var url: URL { frames[0] }
  init(id: UUID, frames: [URL]) { self.id = id; self.frames = frames }
  init(id: UUID, url: URL) { self.init(id: id, frames: [url]) }
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
    // Application Support, not Documents: pages in progress stay out of the Files app, which shows only finished folders.
    self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ScanDraft", isDirectory: true)
  }
  private var manifest: URL { directory.appendingPathComponent("pages.json") }
  private var solvedMarker: URL { directory.appendingPathComponent("solved") }
  /// Readable after the first unlock, so solving and the PDF can finish if the phone locks meanwhile.
  static let protection: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication
  /// The draft is the source of a finished PDF until the next packet starts or a page is edited.
  var isSolved: Bool { FileManager.default.fileExists(atPath: solvedMarker.path) }
  func markSolved() throws { try Data().write(to: solvedMarker, options: [.atomic, Self.protection]) }
  /// Frame 1 is `<id>.jpg` (the only file of a single-photo page, as in 1.x/2.0 drafts); later frames are `<id>-2.jpg`, `<id>-3.jpg`, …
  private func frameURL(_ id: UUID, _ index: Int) -> URL {
    directory.appendingPathComponent(index == 0 ? "\(id).jpg" : "\(id)-\(index + 1).jpg")
  }
  func load() -> [CapturedPage] {
    guard let data = try? Data(contentsOf: manifest), let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
    let pages: [CapturedPage] = ids.compactMap { id in
      var frames: [URL] = []
      while true {
        let url = frameURL(id, frames.count)
        guard FileManager.default.fileExists(atPath: url.path) else { break }
        frames.append(url)
      }
      return frames.isEmpty ? nil : CapturedPage(id: id, frames: frames)
    }
    // Drafts saved by 1.x used complete protection, which is unreadable while the phone is locked.
    for url in pages.flatMap(\.frames) + [manifest] {
      try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
    return pages
  }
  func add(_ jpeg: Data, to pages: [CapturedPage], replacing index: Int?) throws -> [CapturedPage] {
    try add(frames: [jpeg], to: pages, replacing: index)
  }
  /// Saves one page made of one or more photos. A replacement is written before the old photos are deleted.
  func add(frames jpegs: [Data], to pages: [CapturedPage], replacing index: Int?) throws -> [CapturedPage] {
    guard !jpegs.isEmpty else { throw SolverError.message("No photo to save for this page.") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = UUID(), urls = jpegs.indices.map { frameURL(id, $0) }
    do { for (jpeg, url) in zip(jpegs, urls) { try jpeg.write(to: url, options: [.atomic, Self.protection]) } }
    catch { urls.forEach { try? FileManager.default.removeItem(at: $0) }; throw error }
    try? FileManager.default.removeItem(at: solvedMarker)
    var updated = pages
    let page = CapturedPage(id: id, frames: urls)
    if let index, updated.indices.contains(index) { updated[index] = page } else { updated.append(page) }
    do { try save(updated) }
    catch { urls.forEach { try? FileManager.default.removeItem(at: $0) }; throw error }
    if let index, pages.indices.contains(index) { pages[index].frames.forEach { try? FileManager.default.removeItem(at: $0) } }
    return updated
  }
  func remove(at index: Int, from pages: [CapturedPage]) throws -> [CapturedPage] {
    guard pages.indices.contains(index) else { return pages }
    var updated = pages; let old = updated.remove(at: index)
    try? FileManager.default.removeItem(at: solvedMarker)
    try save(updated); old.frames.forEach { try? FileManager.default.removeItem(at: $0) }; return updated
  }
  func clear() throws {
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
  }
  private func save(_ pages: [CapturedPage]) throws {
    try JSONEncoder().encode(pages.map(\.id)).write(to: manifest, options: [.atomic, Self.protection])
  }
}
