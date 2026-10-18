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

struct PageSample: Sendable {
  var corners: [PagePoint] = [] // TL, TR, BR, BL; Vision normalized coordinates
  var luminance: Double = 0
  var contrast: Double = 0
  var sharpness: Double = 0
  var fingerprint: [Double] = []
  var issue: String? = nil
  var acceptable: Bool { issue == nil && corners.count == 4 }
}

struct StabilityGate: Sendable {
  private var anchor: PageSample?
  private var previous: PageSample?
  private var since: TimeInterval?
  private var lastTime: TimeInterval?
  private var samples = 0
  private(set) var latched = false
  let duration: TimeInterval
  init(duration: TimeInterval = 1.5) { self.duration = duration }

  mutating func reset() { self = Self(duration: duration) }

  mutating func observe(_ sample: PageSample, at time: TimeInterval) -> Double {
    guard !latched else { return 1 }
    guard sample.acceptable else { reset(); return 0 }
    let gap = lastTime.map { time - $0 > 0.85 || time <= $0 } ?? false
    let moved = previous.map { Self.movement($0, sample) > 0.012 } ?? false
    let drifted = anchor.map { Self.movement($0, sample) > 0.022 } ?? false
    let changed = previous.map { Self.imageDifference($0, sample) > 0.055 } ?? false
    if since == nil || gap || moved || drifted || changed {
      anchor = sample; since = time; samples = 0
    }
    previous = sample; lastTime = time; samples += 1
    let progress = min(1, (time - (since ?? time)) / duration)
    if progress >= 1 && samples >= 5 { latched = true; return 1 }
    return min(progress, 0.98)
  }

  static func movement(_ a: PageSample, _ b: PageSample) -> Double {
    guard a.corners.count == 4, b.corners.count == 4 else { return 1 }
    return zip(a.corners, b.corners).map { $0.distance(to: $1) }.max() ?? 1
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

struct PreparedPhoto: Sendable {
  let jpeg: Data
  let sample: PageSample
  let width: Int
  let height: Int
}

actor PageAnalyzer: PageAnalyzing {
  func analyze(_ image: CGImage, still: Bool = false) throws -> PageSample {
    let request = VNDetectRectanglesRequest()
    request.minimumConfidence = 0.7
    request.maximumObservations = 5
    request.minimumAspectRatio = 0.30
    request.maximumAspectRatio = 1.0
    request.minimumSize = 0.25
    request.quadratureTolerance = 25
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    guard let page = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else {
      return PageSample(issue: "Show the whole page against a contrasting background.")
    }
    let points = [page.topLeft, page.topRight, page.bottomRight, page.bottomLeft]
    var sample = PageSample(corners: points.map { PagePoint(x: $0.x, y: $0.y) })
    let box = page.boundingBox
    if points.contains(where: { $0.x < 0.025 || $0.x > 0.975 || $0.y < 0.025 || $0.y > 0.975 }) {
      sample.issue = "Move back slightly so all four page corners are visible."; return sample
    }
    if box.width * box.height < 0.22 {
      sample.issue = "Move closer. Let the page fill more of the view."; return sample
    }
    let pixels = points.map { CGPoint(x: $0.x * Double(image.width), y: $0.y * Double(image.height)) }
    for i in 0..<4 {
      let p = pixels[i], a = pixels[(i + 3) % 4], b = pixels[(i + 1) % 4]
      let ax = a.x - p.x, ay = a.y - p.y, bx = b.x - p.x, by = b.y - p.y
      let cosine = (ax * bx + ay * by) / max(1, hypot(ax, ay) * hypot(bx, by))
      if abs(cosine) > 0.34 {
        sample.issue = "Face the page more directly. Reduce the angle."; return sample
      }
    }
    // Analyze the interior only: page borders must not make blurry text look sharp.
    let inner = box.insetBy(dx: box.width * 0.09, dy: box.height * 0.09)
    let region = CGRect(x: inner.minX * Double(image.width), y: (1 - inner.maxY) * Double(image.height),
      width: inner.width * Double(image.width), height: inner.height * Double(image.height)).integral
    guard let crop = image.cropping(to: region) else { throw SolverError.message("Could not inspect the paper photo.") }
    let metrics = Self.measure(crop)
    sample.luminance = metrics.mean; sample.contrast = metrics.contrast
    sample.sharpness = metrics.sharpness; sample.fingerprint = metrics.fingerprint
    if metrics.mean < 0.20 { sample.issue = "Add more light to the page." }
    else if metrics.mean > 0.96 && metrics.contrast < 0.06 { sample.issue = "Tilt away from glare or reduce the light." }
    else if metrics.contrast < 0.045 { sample.issue = "The page detail is faint. Improve the light and move closer." }
    else if metrics.sharpness < (still ? 0.00055 : 0.00030) { sample.issue = "Hold still. The writing looks blurred." }
    else if still && min(image.width, image.height) < 800 { sample.issue = "The capture is too small for reliable page reading." }
    return sample
  }

  func prepare(_ data: Data) throws -> PreparedPhoto {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width * height <= 60_000_000 else { throw SolverError.message("Could not decode this photo, or it exceeds 60 megapixels.") }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw SolverError.message("Could not decode this photo.")
    }
    let sample = try analyze(image, still: true)
    // Preserve full dimensions. Normalize orientation/format only; no crop, enhancement or OCR.
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw SolverError.message("Could not prepare the photo.")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    guard CGImageDestinationFinalize(destination), output.length < 20_000_000 else {
      throw SolverError.message("The photo exceeds the 20 MB upload limit.")
    }
    return PreparedPhoto(jpeg: output as Data, sample: sample, width: image.width, height: image.height)
  }

  struct Metrics { let mean: Double; let contrast: Double; let sharpness: Double; let fingerprint: [Double] }
  static func measure(_ image: CGImage) -> Metrics {
    let w = 384, h = max(32, Int(Double(w) * Double(image.height) / Double(image.width)))
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
    for gy in 0..<16 { for gx in 0..<16 {
      var sum = 0.0, count = 0.0
      for y in (gy * h / 16)..<((gy + 1) * h / 16) {
        for x in (gx * w / 16)..<((gx + 1) * w / 16) { sum += values[y * w + x]; count += 1 }
      }
      fingerprint.append(sum / max(1, count) - mean)
    } }
    return Metrics(mean: mean, contrast: sqrt(variance), sharpness: energy / Double((w - 2) * (h - 2)), fingerprint: fingerprint)
  }
}
