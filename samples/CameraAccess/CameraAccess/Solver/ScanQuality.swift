import Foundation
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct PagePoint: Sendable, Equatable {
  let x: Double
  let y: Double
  func distance(to other: Self) -> Double { hypot(x - other.x, y - other.y) }
}

/// Directions refer to the wearer's head/camera, never to moving the paper.
enum ScanCue: String, Sendable {
  case findProblem, left, right, tiltUp, tiltDown, closer, farther, moreLight, steady, hold

  var message: String {
    switch self {
    case .findProblem: return "Point at the problem. Keep the writing in view."
    case .left: return "Turn your head a little left."
    case .right: return "Turn your head a little right."
    case .tiltUp: return "Tilt your head up a little."
    case .tiltDown: return "Tilt your head down a little."
    case .closer: return "Move a little closer to the writing."
    case .farther: return "Move back a little to fit the problem."
    case .moreLight: return "More light on the writing, please."
    case .steady: return "Hold your head still. The image looks blurred."
    case .hold: return "Hold still for the photo."
    }
  }
}

struct PageSample: Sendable {
  var contentBounds: CGRect? = nil // Text region, not paper edges; Vision bottom-left coordinates.
  var luminance: Double = 0
  var contrast: Double = 0
  var sharpness: Double = 0
  var fingerprint: [Double] = []
  var contentFingerprint: [Double] = []
  var closeEnough = true
  var cue: ScanCue = .hold
  var issue: String? = nil
  /// Median detected text-line height in pixels of the full-resolution image; 0 when no text was located.
  var linePixels: Double = 0
  /// A deliberate command hand (thumbs up/down) in this preview frame. Stills are never classified.
  var gesture: HandGesture? = nil
  var acceptable: Bool { issue == nil && !fingerprint.isEmpty }
  var corners: [PagePoint] {
    guard let b = contentBounds else { return [] }
    return [PagePoint(x: b.minX, y: b.maxY), PagePoint(x: b.maxX, y: b.maxY),
      PagePoint(x: b.maxX, y: b.minY), PagePoint(x: b.minX, y: b.minY)]
  }
}

/// Framing is advice. It never rejects a still or requires a sheet outline.
struct ContentFraming {
  static func cue(bounds: CGRect?, lineHeight: Double, imageHeight: Int) -> ScanCue {
    guard let b = bounds else { return .findProblem }
    let dx = Double(b.midX) - 0.5, dy = Double(b.midY) - 0.5
    // Broad central zone: no need to perfectly center a readable problem.
    if abs(dx) > 0.27 || abs(dy) > 0.30 {
      if abs(dx) / 0.27 >= abs(dy) / 0.30 { return dx < 0 ? .left : .right }
      return dy > 0 ? .tiltUp : .tiltDown
    }
    if b.width > 0.97 || b.height > 0.97 { return .farther }
    if (lineHeight > 0 && lineHeight * Double(imageHeight) < 10)
      || (b.width < 0.18 && b.height < 0.14) { return .closer }
    return .hold
  }

  /// Follow the text group nearest the center; distant background labels need not fit.
  static func primaryGroup(_ boxes: [CGRect]) -> [CGRect] {
    var remaining = Array(boxes.filter { $0.width > 0.008 && $0.height > 0.003 && $0.height < 0.25 }.prefix(200))
    guard let seed = remaining.indices.min(by: { distance(remaining[$0]) < distance(remaining[$1]) }) else { return [] }
    var group = [remaining.remove(at: seed)]
    var expanded = true
    while expanded {
      expanded = false
      for index in remaining.indices.reversed() {
        let box = remaining[index]
        if group.contains(where: { neighbor($0, box) }) {
          group.append(remaining.remove(at: index)); expanded = true
        }
      }
    }
    return group
  }
  private static func distance(_ b: CGRect) -> Double {
    let dx = max(max(b.minX - 0.5, 0.5 - b.maxX), 0)
    let dy = max(max(b.minY - 0.5, 0.5 - b.maxY), 0)
    return hypot(dx, dy)
  }
  private static func neighbor(_ a: CGRect, _ b: CGRect) -> Bool {
    let xGap = max(max(a.minX - b.maxX, b.minX - a.maxX), 0)
    let yGap = max(max(a.minY - b.maxY, b.minY - a.maxY), 0)
    // Same line, or nearby lines with overlapping horizontal spans.
    return (yGap == 0 && xGap < 0.08) || (xGap == 0 && yGap < 0.09)
  }
}

/// Debounce changing directions, interrupt them promptly with "hold", and repeat useful reminders.
struct GuidanceSpeechGate {
  private var candidate: ScanCue?
  private var candidateSince = -Double.infinity
  private var lastCue: ScanCue?
  private var lastTime = -Double.infinity

  mutating func reset() { self = Self() }
  mutating func noteAnnouncement(at time: TimeInterval) {
    candidate = nil; lastCue = nil; lastTime = time
  }
  mutating func shouldSpeak(_ cue: ScanCue, at time: TimeInterval) -> Bool {
    if candidate != cue { candidate = cue; candidateSince = time }
    if cue != .hold && time - candidateSince < 0.3 { return false }
    let interval = cue == lastCue ? 7.0 : (cue == .hold || lastCue == nil ? 0.8 : 2.2)
    guard time - lastTime >= interval else { return false }
    lastCue = cue; lastTime = time; return true
  }
}

struct StabilityGate: Sendable {
  private var anchor: PageSample?
  private var previous: PageSample?
  private var since: TimeInterval?
  private var lastTime: TimeInterval?
  private var samples = 0
  private(set) var latched = false
  let duration: TimeInterval
  let quickDuration: TimeInterval
  init(duration: TimeInterval = 1.5, quickDuration: TimeInterval = 1.0) {
    self.duration = duration; self.quickDuration = quickDuration
  }

  mutating func reset() { self = Self(duration: duration, quickDuration: quickDuration) }

  /// Far above every veto: sharp, contrasty, well-sized writing needs less settling time.
  static func clearlyReadable(_ sample: PageSample) -> Bool {
    sample.cue == .hold && sample.sharpness >= 0.0005 && sample.contrast >= 0.036 && sample.linePixels >= 14
  }

  mutating func observe(_ sample: PageSample, at time: TimeInterval) -> Double {
    guard !latched else { return 1 }
    guard sample.acceptable && sample.closeEnough else { reset(); return 0 }
    let gap = lastTime.map { time - $0 > 1.1 || time <= $0 } ?? false
    let moved = previous.map { Self.movement($0, sample) > 0.045 || Self.imageDifference($0, sample) > 0.10 } ?? false
    let drifted = anchor.map { Self.movement($0, sample) > 0.065 || Self.imageDifference($0, sample) > 0.14 } ?? false
    if since == nil || gap || moved || drifted {
      anchor = sample; since = time; samples = 0
    }
    previous = sample; lastTime = time; samples += 1
    // Give positioning advice time to help, but don't wait forever for ideal framing or text detection.
    let holdTime = Self.clearlyReadable(sample) ? min(duration, quickDuration)
      : (sample.cue == .hold ? duration : max(duration, 3))
    let progress = min(1, (time - (since ?? time)) / holdTime)
    if progress >= 1 && samples >= 5 { latched = true; return 1 }
    return min(progress, 0.98)
  }

  static func movement(_ a: PageSample, _ b: PageSample) -> Double {
    guard let p = a.contentBounds, let q = b.contentBounds else { return 0 }
    // A detector dropping a line must not masquerade as head motion; fixed-frame pixels still check it.
    guard abs(p.width - q.width) < 0.12, abs(p.height - q.height) < 0.12 else { return 0 }
    return hypot(p.midX - q.midX, p.midY - q.midY)
  }
  static func imageDifference(_ a: PageSample, _ b: PageSample) -> Double {
    guard !a.fingerprint.isEmpty, a.fingerprint.count == b.fingerprint.count else { return 1 }
    return zip(a.fingerprint, b.fingerprint).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.fingerprint.count)
  }
}

protocol PageAnalyzing: Sendable {
  func analyze(_ image: CGImage, still: Bool) async throws -> PageSample
  func prepare(_ data: Data) async throws -> PreparedPhoto
}

struct PreparedPhoto: @unchecked Sendable {
  let jpeg: Data
  let sample: PageSample
  let width: Int
  let height: Int
  /// Small orientation-corrected preview for the page queue; CGImage is immutable.
  var thumbnail: CGImage? = nil
}

actor PageAnalyzer: PageAnalyzing {
  private let gestures = HandGestureClassifier()

  func analyze(_ image: CGImage, still: Bool = false) throws -> PageSample {
    try analyze(image, still: still, referenceHeight: nil)
  }

  /// `referenceHeight` is the full-resolution height when `image` is a downscaled copy of a still.
  func analyze(_ image: CGImage, still: Bool, referenceHeight: Int?) throws -> PageSample {
    // Locate visible text only; no character recognition/transcription and no paper detector.
    // If text detection misses handwriting or a diagram, a steady detailed image can still proceed.
    let request = VNDetectTextRectanglesRequest()
    request.reportCharacterBoxes = true
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try? handler.perform([request])
    // Separate perform: a hand-pose failure must never discard the text result.
    var gesture: HandGesture?
    if !still {
      let hands = HandPoseVision.makeRequest()
      if (try? handler.perform([hands])) != nil {
        gesture = gestures.classify(HandPoseVision.poses(from: hands), imageWidth: image.width, imageHeight: image.height)
      }
    }
    let height = Double(referenceHeight ?? image.height)
    // A sheet border can be reported as one giant "character". Use multi-character regions
    // for aiming; this is shape detection, not OCR. Unmatched handwriting/diagrams still
    // use the center-detail fallback and can capture without a text outline.
    let text = (request.results ?? []).filter { ($0.characterBoxes?.count ?? 0) >= 2 }
    let group = ContentFraming.primaryGroup(text.map(\.boundingBox))
    let bounds = group.isEmpty ? nil : group.reduce(CGRect.null) { $0.union($1) }
    let heights = group.map { Double($0.height) }.sorted()
    let lineHeight = heights.isEmpty ? 0 : heights[heights.count / 2]
    // Inspect writing when localized. Otherwise inspect the center, excluding distant background edges.
    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    let inspection = bounds.map { $0.insetBy(dx: -0.025, dy: -0.025).intersection(unit) }
      ?? CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)
    let region = CGRect(x: inspection.minX * Double(image.width), y: (1 - inspection.maxY) * Double(image.height),
      width: inspection.width * Double(image.width), height: inspection.height * Double(image.height)).integral
    guard let crop = image.cropping(to: region) else { throw SolverError.message("Could not inspect this photo.") }
    let metrics = Self.measure(crop)
    // A fixed full-frame fingerprint avoids false motion when detected text bounds change.
    let motion = Self.measure(image, longestSide: 192)
    var sample = PageSample(contentBounds: bounds, luminance: metrics.mean, contrast: metrics.contrast,
      sharpness: metrics.sharpness, fingerprint: motion.fingerprint, contentFingerprint: metrics.fingerprint,
      closeEnough: !(lineHeight > 0 && lineHeight * height < 10)
        && !(bounds.map { $0.width < 0.18 && $0.height < 0.14 } ?? false),
      cue: ContentFraming.cue(bounds: bounds, lineHeight: lineHeight, imageHeight: Int(height)),
      linePixels: lineHeight * height, gesture: gesture)
    // Only obvious darkness, missing detail, or heavy blur can veto a capture. Geometry cannot.
    if metrics.mean < 0.07 {
      sample.cue = .moreLight; sample.issue = sample.cue.message
    } else if metrics.contrast < 0.018 {
      sample.cue = .findProblem; sample.issue = "Point at the writing. I can't see enough detail yet."
    } else if metrics.sharpness < 0.00012 {
      sample.cue = .steady; sample.issue = sample.cue.message
    }
    // No minimum paper size, perspective limit, border requirement, or 800-pixel cutoff.
    // The full still, not the preview, is what the AI assesses for complete readable problems.
    return sample
  }

  func prepare(_ data: Data) throws -> PreparedPhoto {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width * height <= 60_000_000 else {
      throw SolverError.message("Could not decode this photo, or it exceeds 60 megapixels.")
    }
    func decode(_ side: Int) throws -> CGImage {
      let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: side]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw SolverError.message("Could not decode this photo.")
      }
      return image
    }
    let rotated = (5...8).contains((properties[kCGImagePropertyOrientation] as? UInt32) ?? 1)
    let fullWidth = rotated ? height : width, fullHeight = rotated ? width : height
    let longEdge = max(width, height)
    // Large glasses stills: a half-size check is enough only when text is clearly found and well above the
    // close-up limit. Anything else gets the exact full-resolution check, so the detail gate never weakens.
    var sample = PageSample()
    var checked = false
    if longEdge >= 2000 {
      sample = try analyze(try decode(longEdge / 2), still: true, referenceHeight: fullHeight)
      checked = sample.acceptable && sample.closeEnough && sample.linePixels >= 20
    }
    var full: CGImage?
    if !checked {
      let image = try decode(longEdge); full = image
      sample = try analyze(image, still: true)
    }
    // Keep the glasses' original JPEG bytes (every reader applies EXIF orientation); no crop, enhancement or OCR.
    let jpeg: Data
    if (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier { jpeg = data }
    else { jpeg = try Self.encodeJPEG(try full ?? decode(longEdge), quality: 0.95) }
    guard jpeg.count < 20_000_000 else { throw SolverError.message("The photo exceeds the 20 MB upload limit.") }
    return PreparedPhoto(jpeg: jpeg, sample: sample, width: fullWidth, height: fullHeight,
      thumbnail: try? decode(360))
  }

  static func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw SolverError.message("Could not prepare the photo.")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw SolverError.message("Could not prepare the photo.") }
    return output as Data
  }

  struct Metrics { let mean: Double; let contrast: Double; let sharpness: Double; let fingerprint: [Double] }
  static func measure(_ image: CGImage, longestSide: Int = 640) -> Metrics {
    let scale = min(1, Double(longestSide) / Double(max(image.width, image.height)))
    let w = max(32, Int(Double(image.width) * scale)), h = max(32, Int(Double(image.height) * scale))
    var bytes = [UInt8](repeating: 0, count: w * h)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
    }
    guard drawn else { return Metrics(mean: 0, contrast: 0, sharpness: 0, fingerprint: []) }
    let values = bytes.map { Double($0) / 255 }
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
    var energy = 0.0
    for y in 1..<(h - 1) { for x in 1..<(w - 1) {
      let i = y * w + x
      let lap = values[i - 1] + values[i + 1] + values[i - w] + values[i + w] - 4 * values[i]
      energy += lap * lap
    } }
    var fingerprint: [Double] = []
    for gy in 0..<32 { for gx in 0..<32 {
      var sum = 0.0, count = 0.0
      for y in (gy * h / 32)..<((gy + 1) * h / 32) {
        for x in (gx * w / 32)..<((gx + 1) * w / 32) { sum += values[y * w + x]; count += 1 }
      }
      fingerprint.append(sum / max(1, count) - mean)
    } }
    return Metrics(mean: mean, contrast: sqrt(variance), sharpness: energy / Double((w - 2) * (h - 2)), fingerprint: fingerprint)
  }
}

/// A saved sheet stays latched until the writing changes; head movement alone should not rearm it.
/// Similar-looking pages can always be explicitly armed with the spoken "next page" command.
struct PageTurnGate {
  private var saved: PageSample?
  private var savedAt = 0.0
  private var changedFrames = 0
  private var changedSince = 0.0
  mutating func saved(_ sample: PageSample, at time: Double) { saved = sample; savedAt = time; changedFrames = 0 }
  mutating func reset() { self = Self() }
  /// Requires three consecutive changed views spanning at least 0.4 s, so per-frame analysis cannot rush it.
  mutating func observe(_ sample: PageSample, at time: Double) -> Bool {
    guard let saved, time - savedAt >= 2, sample.acceptable, sample.closeEnough, sample.gesture == nil else {
      changedFrames = 0; return false
    }
    let a = saved.contentFingerprint, b = sample.contentFingerprint
    let changed: Bool
    if !a.isEmpty, a.count == b.count {
      let difference = zip(a, b).reduce(0.0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
      changed = difference > 0.065
    } else { changed = StabilityGate.imageDifference(saved, sample) > 0.20 }
    if changed { if changedFrames == 0 { changedSince = time }; changedFrames += 1 } else { changedFrames = 0 }
    return changedFrames >= 3 && time - changedSince >= 0.4
  }
}
