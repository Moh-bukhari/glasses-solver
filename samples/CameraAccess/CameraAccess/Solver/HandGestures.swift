import Foundation
#if canImport(Vision)
import Vision
import CoreGraphics
import ImageIO
#endif

// Hand-gesture commands seen by the glasses camera.
//
// Pure part (Foundation only, Sendable): HandJoint, HandJointPoint, HandPose, HandGesture,
// HandGestureClassifier, GestureGate. The Vision adapter at the bottom is compiled only where Vision exists.
//
// Coordinates follow Vision: normalized to the processed image, origin at the LOWER-LEFT corner, +y up
// (WWDC20 10653 "Detect Body and Hand Pose with Vision"; VNDetectedObjectObservation.boundingBox docs).
// All geometry is done in isotropic units of the image's short side, so a 720x1280 frame is not distorted.
// The glasses camera faces forward and is assumed unmirrored (like a phone's rear camera), so image right is the
// wearer's right. Verify once on the glasses: a thumb to your right must classify as thumbsRight.

/// The 21 landmarks of VNHumanHandPoseObservation.JointName as an app-owned Sendable enum.
enum HandJoint: String, CaseIterable, Sendable {
  case wrist
  case thumbCMC, thumbMP, thumbIP, thumbTip
  case indexMCP, indexPIP, indexDIP, indexTip
  case middleMCP, middlePIP, middleDIP, middleTip
  case ringMCP, ringPIP, ringDIP, ringTip
  case littleMCP, littlePIP, littleDIP, littleTip
}

struct HandJointPoint: Sendable, Equatable {
  /// Normalized 0...1, lower-left origin (VNRecognizedPoint.location).
  var x: Double
  var y: Double
  /// VNRecognizedPoint.confidence, 0...1.
  var confidence: Double
}

enum HandChirality: String, Sendable { case left, right, unknown }

struct HandPose: Sendable, Equatable {
  var joints: [HandJoint: HandJointPoint]
  var chirality: HandChirality = .unknown
}

/// One gesture family, a fist with a straight thumb, named by where the thumb points in the image. Which command
/// each one triggers is the coordinator's choice: thumbs up = start solving, thumbs right = next page,
/// thumbs left = previous page, thumbs down = previous page (alias).
enum HandGesture: String, CaseIterable, Sendable {
  case thumbsUp     // thumb toward image up
  case thumbsDown   // thumb toward image down
  case thumbsRight  // thumb toward image right = the wearer's right
  case thumbsLeft   // thumb toward image left = the wearer's left
  case openPalm     // opt-in; see HandGestureClassifier.enabled

  /// The four thumb directions; the classifier's default set.
  static let thumbs: Set<HandGesture> = [.thumbsUp, .thumbsDown, .thumbsRight, .thumbsLeft]
}

struct HandGestureEvaluation: Sendable, Equatable {
  enum Rejection: String, Sendable { case missingJoint, lowConfidence, nearEdge, tooSmall, tooLarge, noMatch }
  var gesture: HandGesture?
  var rejection: Rejection?
  /// Palm length (wrist to farthest of index/middle/little MCP) in image short-side units; 0 if not measured.
  var palmSize: Double
}

/// Single-frame, rule-based classifier. Every rule is scale invariant (distances divided by palm length)
/// and rotation invariant except the explicit thumb-direction tests. Thresholds are tuning values, not Apple facts.
struct HandGestureClassifier: Sendable {
  struct Thresholds: Sendable, Equatable {
    /// Wrist, thumb MP/IP/tip, index/middle/little MCP must all reach this confidence.
    var coreConfidence = 0.40
    /// Finger MCP/PIP/tip below this are "unverifiable" (self-occluded in a fist, or hidden behind paper).
    var fingerConfidence = 0.25
    /// Deliberately raised hand: palm >= 15% of the short side (about 108 px on a 720x1280 frame).
    var minPalm = 0.15
    var maxPalm = 0.90
    /// Every confident joint must be inside [margin, 1 - margin]; hands entering from the border are ignored.
    var edgeMargin = 0.03
    /// Curled: |tip - wrist| < 1.05 x |MCP - wrist| and tip nearer the wrist than the PIP.
    var curledTipRatio = 1.05
    /// Extended: |tip - wrist| > 1.45 x |MCP - wrist|, tip >= 0.25 palms beyond the PIP, and straight.
    var extendedTipRatio = 1.45
    var extendedBeyondPIP = 0.25
    var maxFingerBend = 45.0
    /// Thumb MP -> tip at least 0.42 palms long and bent no more than 40 degrees at the IP joint.
    var minThumbLength = 0.42
    var maxThumbBend = 40.0
    /// Thumb MP -> tip within 40 degrees of image up (thumbs up) or image down (thumbs down).
    var thumbAxisTolerance = 40.0
    /// Thumb MP -> tip within 35 degrees of image right (thumbs right) or image left (thumbs left). Keep
    /// thumbAxisTolerance + thumbSideTolerance < 90 so the cones never overlap: with 40 + 35, a thumb 35-50 degrees
    /// from horizontal (every diagonal, including 45) matches no direction.
    var thumbSideTolerance = 35.0
    /// Thumb tip must lead every non-thumb joint along the matched axis (up, down, right or left) by 0.25 palms.
    var thumbLead = 0.25
    /// Thumb tip at least 0.45 palms from index/middle PIP/DIP/tip (rejects pinch and key grips on paper).
    var thumbClearance = 0.45
    /// Open palm: wrist -> middle tip within 35 degrees of up, fingertips spread, thumb abducted, palm facing camera.
    var palmAxisTolerance = 35.0
    var minSpreadRatio = 1.40
    var minThumbAbduction = 0.50
  }

  var thresholds: Thresholds
  /// Open palm depends on Vision's chirality semantics; keep it opt-in until verified on the glasses.
  var enabled: Set<HandGesture>

  init(thresholds: Thresholds = Thresholds(), enabled: Set<HandGesture> = HandGesture.thumbs) {
    self.thresholds = thresholds
    self.enabled = enabled
  }

  /// One gesture per frame. Hands that disagree (e.g. one thumbs right, one thumbs left) yield nil.
  func classify(_ hands: [HandPose], imageWidth: Int, imageHeight: Int) -> HandGesture? {
    let found = Set(hands.compactMap { evaluate($0, imageWidth: imageWidth, imageHeight: imageHeight).gesture })
    return found.count == 1 ? found.first : nil
  }

  func evaluate(_ hand: HandPose, imageWidth: Int, imageHeight: Int) -> HandGestureEvaluation {
    let t = thresholds
    let core: [HandJoint] = [.wrist, .thumbMP, .thumbIP, .thumbTip, .indexMCP, .middleMCP, .littleMCP]
    guard core.allSatisfy({ hand.joints[$0] != nil }) else { return Self.reject(.missingJoint) }
    guard core.allSatisfy({ (hand.joints[$0]?.confidence ?? 0) >= t.coreConfidence }) else {
      return Self.reject(.lowConfidence)
    }
    let edge = t.edgeMargin...(1 - t.edgeMargin)
    for point in hand.joints.values where point.confidence >= t.fingerConfidence {
      guard edge.contains(point.x), edge.contains(point.y) else { return Self.reject(.nearEdge) }
    }

    // Isotropic coordinates in units of the short side, +y up.
    let sized = imageWidth > 0 && imageHeight > 0
    let shortSide = sized ? Double(min(imageWidth, imageHeight)) : 1
    let sx = sized ? Double(imageWidth) / shortSide : 1
    let sy = sized ? Double(imageHeight) / shortSide : 1
    var p: [HandJoint: HandVector] = [:]
    var confidence: [HandJoint: Double] = [:]
    for (joint, point) in hand.joints {
      p[joint] = HandVector(x: point.x * sx, y: point.y * sy)
      confidence[joint] = point.confidence
    }
    guard let wrist = p[.wrist], let indexMCP = p[.indexMCP], let middleMCP = p[.middleMCP],
      let littleMCP = p[.littleMCP] else { return Self.reject(.missingJoint) }
    let palm = max(wrist.distance(to: indexMCP), wrist.distance(to: middleMCP), wrist.distance(to: littleMCP))
    guard palm >= t.minPalm else { return Self.reject(.tooSmall, palm: palm) }
    guard palm <= t.maxPalm else { return Self.reject(.tooLarge, palm: palm) }

    var states: [Finger: FingerState] = [:]
    for finger in Finger.allCases {
      states[finger] = state(of: finger, points: p, confidence: confidence, wrist: wrist, palm: palm)
    }
    var matches: [HandGesture] = []
    if let thumb = thumbGesture(points: p, wrist: wrist, palm: palm, states: states), enabled.contains(thumb) {
      matches.append(thumb)
    }
    if enabled.contains(.openPalm),
      isOpenPalm(points: p, wrist: wrist, palm: palm, states: states, chirality: hand.chirality) {
      matches.append(.openPalm)
    }
    guard matches.count == 1 else { return Self.reject(.noMatch, palm: palm) }
    return HandGestureEvaluation(gesture: matches[0], rejection: nil, palmSize: palm)
  }

  // MARK: Rules

  private func state(of finger: Finger, points p: [HandJoint: HandVector], confidence: [HandJoint: Double],
                     wrist: HandVector, palm: Double) -> FingerState {
    let t = thresholds
    guard [finger.mcp, finger.pip, finger.tip].allSatisfy({ (confidence[$0] ?? 0) >= t.fingerConfidence }),
      let mcp = p[finger.mcp], let pip = p[finger.pip], let tip = p[finger.tip] else { return .unknown }
    let dMCP = wrist.distance(to: mcp), dPIP = wrist.distance(to: pip), dTip = wrist.distance(to: tip)
    if dTip < t.curledTipRatio * dMCP && dTip < dPIP { return .curled }
    if dTip > t.extendedTipRatio * dMCP && dTip > dPIP + t.extendedBeyondPIP * palm
      && HandVector.angle(pip - mcp, tip - pip) <= t.maxFingerBend { return .extended }
    return .unknown
  }

  /// Fist (index + middle curled, ring/little not extended, at least one of them curled) with a straight,
  /// long thumb pointing up, down, right or left, clear of the fingers and beyond every other joint.
  /// The same fist, length, straightness and clearance rules apply to every direction; only the axis differs.
  private func thumbGesture(points p: [HandJoint: HandVector], wrist: HandVector, palm: Double,
                            states: [Finger: FingerState]) -> HandGesture? {
    let t = thresholds
    guard states[.index] == .curled, states[.middle] == .curled,
      states[.ring] != .extended, states[.little] != .extended,
      states[.ring] == .curled || states[.little] == .curled,
      let mp = p[.thumbMP], let ip = p[.thumbIP], let tip = p[.thumbTip] else { return nil }
    let thumb = tip - mp
    guard thumb.length >= t.minThumbLength * palm,
      HandVector.angle(ip - mp, tip - ip) <= t.maxThumbBend else { return nil }
    let neighbors: [HandJoint] = [.indexPIP, .indexDIP, .indexTip, .middlePIP, .middleDIP, .middleTip]
    let clearance = neighbors.compactMap { p[$0] }.map { tip.distance(to: $0) }.min() ?? 0
    guard clearance >= t.thumbClearance * palm else { return nil }
    let others = p.filter { !Self.thumbJoints.contains($0.key) }.map(\.value)
    guard !others.isEmpty else { return nil }
    // Exactly one direction may match. With non-overlapping cones at most one can; if the tolerances are ever
    // tuned to overlap, an ambiguous thumb still yields nil instead of the first cone checked.
    let matches = Self.thumbDirections.filter { direction in
      let tolerance = direction.axis.x == 0 ? t.thumbAxisTolerance : t.thumbSideTolerance
      guard HandVector.angle(thumb, direction.axis) <= tolerance,
        let front = others.map({ $0.dot(direction.axis) }).max() else { return false }
      return tip.dot(direction.axis) - front >= t.thumbLead * palm
    }
    return matches.count == 1 ? matches[0].gesture : nil
  }

  /// Image directions (unit vectors, +y up) a thumb can point, and the gesture each one is.
  private static let thumbDirections: [(gesture: HandGesture, axis: HandVector)] = [
    (.thumbsUp, HandVector(x: 0, y: 1)), (.thumbsDown, HandVector(x: 0, y: -1)),
    (.thumbsRight, HandVector(x: 1, y: 0)), (.thumbsLeft, HandVector(x: -1, y: 0))]

  /// All four fingers extended and spread, pointing up, thumb abducted, palm (not back of hand) toward the camera.
  private func isOpenPalm(points p: [HandJoint: HandVector], wrist: HandVector, palm: Double,
                          states: [Finger: FingerState], chirality: HandChirality) -> Bool {
    let t = thresholds
    guard Finger.allCases.allSatisfy({ states[$0] == .extended }),
      let middleTip = p[.middleTip], let indexTip = p[.indexTip], let littleTip = p[.littleTip],
      let indexMCP = p[.indexMCP], let littleMCP = p[.littleMCP], let middleMCP = p[.middleMCP],
      let thumbTip = p[.thumbTip] else { return false }
    guard HandVector.angle(middleTip - wrist, HandVector(x: 0, y: 1)) <= t.palmAxisTolerance else { return false }
    let knuckleWidth = indexMCP.distance(to: littleMCP)
    guard knuckleWidth > 0, indexTip.distance(to: littleTip) >= t.minSpreadRatio * knuckleWidth else { return false }
    guard thumbTip.distance(to: indexMCP) >= t.minThumbAbduction * palm else { return false }
    // In a non-mirrored camera image, a RIGHT palm seen from the front has its thumb side to the image right of
    // the wrist->middleMCP axis (negative 2D cross product); a LEFT palm the opposite. The back of the hand
    // (e.g. flat on the desk) mirrors this. Unknown chirality is rejected.
    let cross = (middleMCP - wrist).cross(indexMCP - littleMCP)
    switch chirality {
    case .right: return cross < 0
    case .left: return cross > 0
    case .unknown: return false
    }
  }

  private static let thumbJoints: Set<HandJoint> = [.thumbCMC, .thumbMP, .thumbIP, .thumbTip]

  private static func reject(_ reason: HandGestureEvaluation.Rejection, palm: Double = 0) -> HandGestureEvaluation {
    HandGestureEvaluation(gesture: nil, rejection: reason, palmSize: palm)
  }

  private enum FingerState: Sendable { case curled, extended, unknown }

  private enum Finger: CaseIterable, Sendable {
    case index, middle, ring, little
    var mcp: HandJoint {
      switch self { case .index: .indexMCP; case .middle: .middleMCP; case .ring: .ringMCP; case .little: .littleMCP }
    }
    var pip: HandJoint {
      switch self { case .index: .indexPIP; case .middle: .middlePIP; case .ring: .ringPIP; case .little: .littlePIP }
    }
    var tip: HandJoint {
      switch self { case .index: .indexTip; case .middle: .middleTip; case .ring: .ringTip; case .little: .littleTip }
    }
  }
}

private struct HandVector: Sendable, Equatable {
  var x: Double
  var y: Double
  static func - (a: HandVector, b: HandVector) -> HandVector { HandVector(x: a.x - b.x, y: a.y - b.y) }
  var length: Double { hypot(x, y) }
  func distance(to other: HandVector) -> Double { (self - other).length }
  func cross(_ other: HandVector) -> Double { x * other.y - y * other.x }
  func dot(_ other: HandVector) -> Double { x * other.x + y * other.y }
  /// Unsigned angle between two vectors in degrees (180 when either is zero length).
  static func angle(_ a: HandVector, _ b: HandVector) -> Double {
    let la = a.length, lb = b.length
    guard la > 0, lb > 0 else { return 180 }
    let cosine = max(-1, min(1, (a.x * b.x + a.y * b.y) / (la * lb)))
    return acos(cosine) * 180 / .pi
  }
}

// MARK: - Temporal gate

/// Fires a gesture only after it is seen in `requiredFrames` consecutive analyses spanning `minimumHold`
/// seconds. Any other result, a gap, or `allowed == false` restarts the hold. After firing, nothing fires
/// during `cooldown`, and the same gesture must disappear for `releaseFrames` analyses before it can fire again.
/// Thumb directions are different gestures: turning the thumb from up to right restarts the hold, so a turn fires at
/// most the direction that is then held for the full hold, and a second direction needs the cooldown plus its own hold.
struct GestureGate: Sendable {
  struct Configuration: Sendable, Equatable {
    var requiredFrames = 4                 // at ~3 Hz: 0, 0.33, 0.66, 0.99 s
    var minimumHold: TimeInterval = 0.9    // governs when analysis runs faster than 3 Hz
    var maximumGap: TimeInterval = 0.8     // > 2 missed analyses at 3 Hz restarts the hold
    var cooldown: TimeInterval = 2.0
    var releaseFrames = 2
  }

  let configuration: Configuration
  private(set) var candidate: HandGesture?
  private(set) var count = 0
  private var since: TimeInterval = 0
  private var lastTime: TimeInterval?
  private var cooldownUntil = -Double.infinity
  private var awaitingRelease: HandGesture?
  private var releaseCount = 0

  init(configuration: Configuration = Configuration()) { self.configuration = configuration }

  /// Full reset, e.g. at the start of a scan run.
  mutating func reset() { self = Self(configuration: configuration) }

  /// 0...1 hold progress of the current candidate, for an optional "recognizing" earcon or UI.
  func progress(at time: TimeInterval) -> Double {
    guard candidate != nil, configuration.requiredFrames > 0 else { return 0 }
    let frames = Double(count) / Double(configuration.requiredFrames)
    let hold = configuration.minimumHold > 0 ? (time - since) / configuration.minimumHold : 1
    return max(0, min(1, min(frames, hold)))
  }

  /// - Parameters:
  ///   - gesture: classifier output for this analysis (nil = no gesture).
  ///   - time: monotonic seconds (ProcessInfo.systemUptime), the same clock the scan gates use.
  ///   - allowed: false while a capture/check is in progress or the phase does not accept gestures.
  /// - Returns: the gesture to act on, at most once per hold.
  mutating func observe(_ gesture: HandGesture?, at time: TimeInterval, allowed: Bool = true) -> HandGesture? {
    if let lastTime, time - lastTime > configuration.maximumGap || time <= lastTime { clearHold() }
    lastTime = time
    if let held = awaitingRelease {
      if gesture == held { releaseCount = 0 } else {
        releaseCount += 1
        if releaseCount >= configuration.releaseFrames { awaitingRelease = nil; releaseCount = 0 }
      }
    }
    guard allowed, let gesture else { clearHold(); return nil }
    guard gesture != awaitingRelease, time >= cooldownUntil else { clearHold(); return nil }
    if gesture == candidate { count += 1 } else { candidate = gesture; count = 1; since = time }
    guard count >= configuration.requiredFrames, time - since >= configuration.minimumHold - 1e-9 else { return nil }
    cooldownUntil = time + configuration.cooldown
    awaitingRelease = gesture; releaseCount = 0
    clearHold()
    return gesture
  }

  private mutating func clearHold() { candidate = nil; count = 0 }
}

// MARK: - Vision adapter

#if canImport(Vision)

enum HandPoseVision {
  /// Create per analysis (VNRequest objects carry results; do not share one across concurrent performs).
  static func makeRequest() -> VNDetectHumanHandPoseRequest {
    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 2  // documented default is 2; Vision keeps the largest hands
    request.revision = VNDetectHumanHandPoseRequestRevision1  // only documented revision; pin for stable behavior
    return request
  }

  /// Converts a finished request's observations into Sendable classifier input.
  static func poses(from request: VNDetectHumanHandPoseRequest) -> [HandPose] {
    (request.results ?? []).map(pose(from:))
  }

  static func pose(from observation: VNHumanHandPoseObservation) -> HandPose {
    let points = (try? observation.recognizedPoints(.all)) ?? [:]
    var joints: [HandJoint: HandJointPoint] = [:]
    for joint in HandJoint.allCases {
      guard let point = points[visionName(for: joint)] else { continue }
      joints[joint] = HandJointPoint(x: Double(point.location.x), y: Double(point.location.y),
        confidence: Double(point.confidence))
    }
    let chirality: HandChirality = observation.chirality == .left ? .left
      : (observation.chirality == .right ? .right : .unknown)
    return HandPose(joints: joints, chirality: chirality)
  }

  /// Standalone detection. `maxLongEdge` optionally downscales first (normalized results are unaffected
  /// because the aspect ratio is preserved). Pass the ORIGINAL size to the classifier.
  static func detect(in image: CGImage, orientation: CGImagePropertyOrientation = .up,
                     maxLongEdge: Int? = nil) throws -> [HandPose] {
    let input = maxLongEdge.map { downscaled(image, maxLongEdge: $0) } ?? image
    let request = makeRequest()
    try VNImageRequestHandler(cgImage: input, orientation: orientation, options: [:]).perform([request])
    return poses(from: request)
  }

  /// Size of the image as Vision sees it after applying `orientation` (90-degree EXIF orientations swap axes).
  static func orientedSize(width: Int, height: Int, orientation: CGImagePropertyOrientation) -> (width: Int, height: Int) {
    switch orientation {
    case .left, .leftMirrored, .right, .rightMirrored: return (height, width)
    default: return (width, height)
    }
  }

  static func downscaled(_ image: CGImage, maxLongEdge: Int) -> CGImage {
    let longEdge = max(image.width, image.height)
    guard maxLongEdge > 0, longEdge > maxLongEdge else { return image }
    let scale = Double(maxLongEdge) / Double(longEdge)
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
  }

  static func visionName(for joint: HandJoint) -> VNHumanHandPoseObservation.JointName {
    switch joint {
    case .wrist: return .wrist
    case .thumbCMC: return .thumbCMC
    case .thumbMP: return .thumbMP
    case .thumbIP: return .thumbIP
    case .thumbTip: return .thumbTip
    case .indexMCP: return .indexMCP
    case .indexPIP: return .indexPIP
    case .indexDIP: return .indexDIP
    case .indexTip: return .indexTip
    case .middleMCP: return .middleMCP
    case .middlePIP: return .middlePIP
    case .middleDIP: return .middleDIP
    case .middleTip: return .middleTip
    case .ringMCP: return .ringMCP
    case .ringPIP: return .ringPIP
    case .ringDIP: return .ringDIP
    case .ringTip: return .ringTip
    case .littleMCP: return .littleMCP
    case .littlePIP: return .littlePIP
    case .littleDIP: return .littleDIP
    case .littleTip: return .littleTip
    }
  }
}
#endif
