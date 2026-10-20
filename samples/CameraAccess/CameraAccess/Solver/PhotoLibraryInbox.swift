import Foundation
import Photos
import ImageIO

/// Watches the photo library for the glasses' photos while a scan runs. With Auto-import on, the Meta AI app saves each
/// capture-button photo to Photos; every new photo (screenshots aside) taken since the scan started is handed over once,
/// oldest first, as an upright JPEG re-encoded without location or camera metadata. Needs Full Access: with limited
/// access, photos another app adds stay hidden.
@MainActor
final class PhotoLibraryInbox: PhotoSource {
  private var observer: LibraryObserver?
  private var onPhoto: (@MainActor (IncomingPhoto) -> Void)?
  private var since = Date.distantFuture
  /// Library identifiers handed over since the last start, and photos whose data could not be read yet (retried a few times).
  private var delivered: Set<String> = []
  private var failures: [String: Int] = [:]
  private var scan: Task<Void, Never>?
  private var again = false
  /// Bumped by every start and stop, so a lookup that outlives its scan delivers nothing.
  private var session = 0
  var isDelivering: Bool { scan != nil }
  var onIdle: (@MainActor () -> Void)?

  func start(since: Date, onPhoto: @escaping @MainActor (IncomingPhoto) -> Void) async throws {
    stop()
    // Every start hands over everything since `since` again: photos a stopped scan never used must come back, and
    // the scan skips the ones it already used.
    delivered = []; failures = [:]
    let session = self.session
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    guard self.session == session else { throw CancellationError() }
    switch status {
    case .authorized: break
    case .limited: throw PhotoSourceError.limitedAccess
    default: throw PhotoSourceError.noAccess
    }
    self.since = since; self.onPhoto = onPhoto
    let observer = LibraryObserver { [weak self] in Task { @MainActor in self?.catchUp() } }
    PHPhotoLibrary.shared().register(observer); self.observer = observer
    catchUp()
  }

  func stop() {
    session += 1
    if let observer { PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
    observer = nil; onPhoto = nil; scan?.cancel(); scan = nil; again = false
  }

  func catchUp() {
    guard onPhoto != nil else { return }
    guard scan == nil else { again = true; return }
    let session = self.session
    scan = Task { [weak self] in await self?.deliverNew(session: session) }
  }

  /// Hands over new photos one at a time; a change while this runs triggers one more pass, and a photo whose data was
  /// not ready (still importing or downloading) is tried again shortly.
  private func deliverNew(session: Int) async {
    var retry = false
    repeat {
      again = false
      for asset in newAssets() {
        guard self.session == session, !Task.isCancelled else { return }
        let id = asset.localIdentifier
        guard let jpeg = await Self.pagePhoto(asset) else {
          failures[id, default: 0] += 1
          if failures[id, default: 0] >= 3 { delivered.insert(id) } else { retry = true } // unreadable: stop trying
          continue
        }
        guard self.session == session else { return }
        delivered.insert(id)
        onPhoto?(IncomingPhoto(id: id, jpeg: jpeg, taken: asset.creationDate ?? Date(), arrived: Date()))
      }
    } while again && self.session == session
    guard self.session == session else { return }
    scan = nil
    onIdle?()
    if retry {
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(2))
        guard let self, self.session == session else { return }
        self.catchUp()
      }
    }
  }

  private func newAssets() -> [PHAsset] {
    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@", PHAssetMediaType.image.rawValue, since as NSDate)
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    options.includeAssetSourceTypes = [.typeUserLibrary]
    let result = PHAsset.fetchAssets(with: options)
    return (0..<result.count).map { result.object(at: $0) }
      .filter { !$0.mediaSubtypes.contains(.photoScreenshot) && !delivered.contains($0.localIdentifier) }
  }

  /// The current version of the photo (with any edits), downloaded from iCloud if needed, scaled to
  /// `ButtonPhotos.maxPixel` and re-encoded.
  private static func pagePhoto(_ asset: PHAsset) async -> Data? {
    let options = PHImageRequestOptions()
    options.version = .current; options.deliveryMode = .highQualityFormat; options.isNetworkAccessAllowed = true
    let original: Data? = await withCheckedContinuation { continuation in
      PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { @Sendable data, _, _, _ in
        continuation.resume(returning: data)
      }
    }
    guard let original else { return nil }
    return await Task.detached(priority: .userInitiated) { scaled(original) }.value
  }

  nonisolated private static func scaled(_ data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: ButtonPhotos.maxPixel] as CFDictionary)
    else { return nil }
    return try? PageAnalyzer.encodeJPEG(image, quality: 0.9)
  }
}

/// PhotoKit calls this on a background queue whenever the library changes.
private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
  private let changed: @Sendable () -> Void
  init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }
  func photoLibraryDidChange(_ changeInstance: PHChange) { changed() }
}
