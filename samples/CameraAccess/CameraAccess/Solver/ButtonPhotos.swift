import Foundation

/// A photo the wearer took with the glasses' capture button, as it reached the iPhone's photo library (the Meta AI app
/// imports it there with Auto-import on). A photo taken with the phone's camera arrives the same way.
struct IncomingPhoto: Sendable, Equatable {
  /// The photo library's identifier: each photo is used once per packet.
  let id: String
  /// Upright JPEG, at most `ButtonPhotos.maxPixel` on its long side, without location or camera metadata.
  let jpeg: Data
  /// When the photo was taken, and when it reached the app: the difference is Meta AI's import delay.
  let taken: Date
  let arrived: Date
}

enum ButtonPhotos {
  /// Long side of a page photo as kept and sent: sharp enough for small print (12 MP originals are 3024 x 4032).
  static let maxPixel = 2576
  /// Photos taken this long before Start still count, for a small clock difference between the glasses and phone.
  static let lookback: TimeInterval = 30
}

enum PhotoSourceError: LocalizedError, Equatable {
  case noAccess, limitedAccess
  var errorDescription: String? {
    switch self {
    case .noAccess:
      return "Glasses Solver can't see your photos. Allow Full Access in Settings › Privacy & Security › Photos › Glasses Solver."
    case .limitedAccess:
      return "Photos access is limited, so new photos from your glasses stay hidden. Choose Full Access in Settings › Privacy & Security › Photos › Glasses Solver."
    }
  }
}

/// New photos from the glasses, oldest first, while a scan runs.
@MainActor
protocol PhotoSource: AnyObject {
  /// Delivers each photo taken at or after `since` once per start, oldest first, until `stop()`; the caller skips photos
  /// it already used. Throws when new photos cannot be seen (Photos access is missing or limited).
  func start(since: Date, onPhoto: @escaping @MainActor (IncomingPhoto) -> Void) async throws
  func stop()
  /// Looks again for photos that arrived while the app was in the background.
  func catchUp()
}

/// Names in the Solutions folder: one folder per packet, readable and sorted by date in the Files app.
enum SolutionFolder {
  static let pdfName = "Solutions.pdf"
  /// "2026-10-19 14.05 Algebra Homework 3". The title is the AI's name for the packet, made safe for a file name.
  static func name(title: String, date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH.mm"
    let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
    let cleaned = title.unicodeScalars.map { banned.contains($0) ? " " : String($0) }.joined()
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
      .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    let short = cleaned.count > 60 ? String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces) : cleaned
    let stamp = formatter.string(from: date)
    return short.isEmpty ? stamp : "\(stamp) \(short)"
  }
  /// `name`, or "name 2", "name 3", … when a folder of that name exists.
  static func unique(_ name: String, existing: Set<String>) -> String {
    guard existing.contains(name) else { return name }
    var number = 2
    while existing.contains("\(name) \(number)") { number += 1 }
    return "\(name) \(number)"
  }
  /// "Page 2.jpg" for a page's only photo; "Page 2 (1).jpg", "Page 2 (2).jpg" when it has several.
  static func photoName(page: Int, photo: Int, of count: Int) -> String {
    count <= 1 ? "Page \(page).jpg" : "Page \(page) (\(photo)).jpg"
  }
}
