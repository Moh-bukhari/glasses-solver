@testable import CameraAccess
import XCTest
import CoreGraphics
import Vision

/// Synthetic Vision-style hand poses. Shapes are authored in "hand space": right hand, palm toward the camera,
/// wrist at the origin, wrist->middle MCP = 1 palm along +y, thumb side +x. `hand(...)` mirrors (left hand or
/// back of a right hand), rotates counter-clockwise, scales to `palm` short-side units, places the palm centre
/// (hand-space (0, 0.6)) at `center`, and converts to normalized lower-left coordinates for a width x height frame.
private enum Shape {
  typealias Points = [HandJoint: (Double, Double)]

  static let knuckles: Points = [.wrist: (0, 0), .indexMCP: (0.28, 0.95), .middleMCP: (0, 1.0),
    .ringMCP: (-0.22, 0.95), .littleMCP: (-0.42, 0.85)]
  /// Fist seen from the palm side: proximal phalanges point at the camera, tips fold back toward the wrist.
  static let curledFingers: Points = [
    .indexPIP: (0.30, 1.08), .indexDIP: (0.29, 0.86), .indexTip: (0.25, 0.66),
    .middlePIP: (0, 1.12), .middleDIP: (0, 0.90), .middleTip: (-0.02, 0.68),
    .ringPIP: (-0.24, 1.06), .ringDIP: (-0.23, 0.85), .ringTip: (-0.20, 0.65),
    .littlePIP: (-0.45, 0.94), .littleDIP: (-0.43, 0.76), .littleTip: (-0.38, 0.60)]
  static let straightIndex: Points = [.indexPIP: (0.29, 1.31), .indexDIP: (0.30, 1.53), .indexTip: (0.31, 1.72)]
  /// Thumb extended sideways from the fist (perpendicular to the palm axis).
  static let thumbOut: Points = [.thumbCMC: (0.22, 0.22), .thumbMP: (0.48, 0.48), .thumbIP: (0.78, 0.56),
    .thumbTip: (1.05, 0.62)]

  static func merge(_ parts: Points...) -> Points {
    parts.reduce(into: Points()) { result, part in result.merge(part) { _, new in new } }
  }

  /// Rotated +90 (right hand) / -90 mirrored (left hand): thumbs up. The opposite rotation: thumbs down.
  static let thumbOutFist = merge(knuckles, curledFingers, thumbOut)
  /// Thumb wrapped across the curled fingers.
  static let fist = merge(knuckles, curledFingers, [.thumbCMC: (0.22, 0.22), .thumbMP: (0.42, 0.50),
    .thumbIP: (0.28, 0.72), .thumbTip: (0.08, 0.80)])
  static let openSpread = merge(knuckles, [
    .thumbCMC: (0.25, 0.22), .thumbMP: (0.52, 0.45), .thumbIP: (0.72, 0.65), .thumbTip: (0.90, 0.85),
    .indexPIP: (0.355, 1.302), .indexDIP: (0.403, 1.527), .indexTip: (0.442, 1.713),
    .middlePIP: (0, 1.39), .middleDIP: (0, 1.65), .middleTip: (0, 1.86),
    .ringPIP: (-0.283, 1.305), .ringDIP: (-0.321, 1.521), .ringTip: (-0.359, 1.738),
    .littlePIP: (-0.525, 1.110), .littleDIP: (-0.589, 1.267), .littleTip: (-0.653, 1.425)])
  /// Relaxed flat hand holding a sheet: fingers straight and together, thumb along the edge.
  static let flatGrip = merge(knuckles, straightIndex, [
    .thumbCMC: (0.25, 0.22), .thumbMP: (0.50, 0.45), .thumbIP: (0.66, 0.68), .thumbTip: (0.78, 0.90),
    .middlePIP: (0, 1.39), .middleDIP: (0, 1.65), .middleTip: (0, 1.86),
    .ringPIP: (-0.23, 1.31), .ringDIP: (-0.235, 1.52), .ringTip: (-0.24, 1.73),
    .littlePIP: (-0.44, 1.12), .littleDIP: (-0.45, 1.28), .littleTip: (-0.46, 1.45)])
  static let pointing = merge(knuckles, curledFingers, straightIndex, [.thumbCMC: (0.22, 0.22),
    .thumbMP: (0.42, 0.50), .thumbIP: (0.25, 0.74), .thumbTip: (0.05, 0.82)])
  /// Lateral "key" pinch on a paper edge: fingers folded, thumb pressed on the side of the index finger.
  static let keyGrip = merge(knuckles, curledFingers, [.thumbCMC: (0.22, 0.22), .thumbMP: (0.48, 0.50),
    .thumbIP: (0.50, 0.75), .thumbTip: (0.40, 0.98)])
  static let lShape = merge(knuckles, curledFingers, straightIndex, thumbOut)
}

private func hand(_ shape: Shape.Points, palm: Double = 0.25, center: (x: Double, y: Double) = (0.5, 0.5),
                  rotation degrees: Double = 0, mirrored: Bool = false, confidence: Double = 0.9,
                  chirality: HandChirality = .right, width: Int = 720, height: Int = 1280,
                  overrides: [HandJoint: Double] = [:]) -> HandPose {
  let shortSide = Double(min(width, height))
  let sx = Double(width) / shortSide, sy = Double(height) / shortSide
  let radians = degrees * .pi / 180, c = cos(radians), s = sin(radians)
  func place(_ point: (Double, Double)) -> (x: Double, y: Double) {
    let x = mirrored ? -point.0 : point.0, y = point.1
    return (x * c - y * s, x * s + y * c)
  }
  let anchor = place((0, 0.6))
  var joints: [HandJoint: HandJointPoint] = [:]
  for (joint, point) in shape {
    let r = place(point)
    let isoX = center.x * sx + (r.x - anchor.x) * palm
    let isoY = center.y * sy + (r.y - anchor.y) * palm
    joints[joint] = HandJointPoint(x: isoX / sx, y: isoY / sy, confidence: overrides[joint] ?? confidence)
  }
  return HandPose(joints: joints, chirality: chirality)
}

final class HandGestureTests: XCTestCase {
  private let all = HandGestureClassifier(enabled: Set(HandGesture.allCases))
  private let standard = HandGestureClassifier()

  private func gesture(_ pose: HandPose, _ classifier: HandGestureClassifier? = nil,
                       width: Int = 720, height: Int = 1280) -> HandGesture? {
    (classifier ?? all).classify([pose], imageWidth: width, imageHeight: height)
  }
  private func rejection(_ pose: HandPose, width: Int = 720, height: Int = 1280) -> HandGestureEvaluation.Rejection? {
    all.evaluate(pose, imageWidth: width, imageHeight: height).rejection
  }

  // MARK: Classifier

  func testThumbsUpBothHandsAndModerateRotations() {
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: 90)), .thumbsUp)           // thumb 13.8 deg left of up
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: -90, mirrored: true, chirality: .left)), .thumbsUp)
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: 105)), .thumbsUp)          // 28.8 deg
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: 60)), .thumbsUp)           // 16.2 deg right of up
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: -105, mirrored: true, chirality: .left)), .thumbsUp)
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: 114)), .thumbsUp)          // 37.8 deg, inside 40
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: 90, chirality: .unknown)), .thumbsUp)
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: 90), standard), .thumbsUp)
  }

  func testGeometryUsesTheFrameAspectRatio() {
    let landscape = hand(Shape.thumbOutFist, rotation: 90, width: 1280, height: 720)
    XCTAssertEqual(gesture(landscape, width: 1280, height: 720), .thumbsUp)
    XCTAssertEqual(all.evaluate(landscape, imageWidth: 1280, imageHeight: 720).palmSize, 0.25, accuracy: 1e-9)
    XCTAssertEqual(all.evaluate(hand(Shape.thumbOutFist, rotation: 90), imageWidth: 720, imageHeight: 1280).palmSize,
      0.25, accuracy: 1e-9)
  }

  func testThumbTooFarFromVerticalIsIgnored() {
    XCTAssertNil(gesture(hand(Shape.thumbOutFist, rotation: 122)))  // 45.8 deg
    XCTAssertNil(gesture(hand(Shape.thumbOutFist, rotation: 140)))  // 63.8 deg
    XCTAssertNil(gesture(hand(Shape.thumbOutFist, rotation: 0)))    // thumb sideways
  }

  func testThumbsDownBothHands() {
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: -90)), .thumbsDown)
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: 90, mirrored: true, chirality: .left)), .thumbsDown)
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: -90), standard), .thumbsDown)
  }

  func testOpenPalmIsOptInAndRequiresThePalmFacingTheGlasses() {
    XCTAssertEqual(gesture(hand(Shape.openSpread)), .openPalm)
    XCTAssertEqual(gesture(hand(Shape.openSpread, mirrored: true, chirality: .left)), .openPalm)
    XCTAssertNil(gesture(hand(Shape.openSpread), standard))
    // Back of a right hand (e.g. flat on the desk) is the mirrored layout with right chirality.
    XCTAssertNil(gesture(hand(Shape.openSpread, mirrored: true, chirality: .right)))
    XCTAssertNil(gesture(hand(Shape.openSpread, chirality: .unknown)))
    XCTAssertNil(gesture(hand(Shape.openSpread, rotation: 90)))   // fingers sideways
  }

  func testFistPointingAndLShapeAreIgnored() {
    XCTAssertNil(gesture(hand(Shape.fist)))
    XCTAssertNil(gesture(hand(Shape.fist, rotation: 90)))
    XCTAssertNil(gesture(hand(Shape.pointing)))
    XCTAssertNil(gesture(hand(Shape.lShape, rotation: 90)))       // thumb up but index extended
  }

  func testHandsHoldingPaperAreIgnored() {
    XCTAssertNil(gesture(hand(Shape.flatGrip, center: (0.72, 0.45), rotation: 90)))  // fingers sideways
    XCTAssertNil(gesture(hand(Shape.flatGrip, center: (0.5, 0.3))))                   // fingers up, together
    XCTAssertNil(gesture(hand(Shape.keyGrip)))                                        // thumb up, pinching
    XCTAssertNil(gesture(hand(Shape.keyGrip, rotation: 180)))                         // thumb down, pinching
    XCTAssertEqual(rejection(hand(Shape.keyGrip)), .noMatch)
  }

  func testSmallOrDistantHandsAreTooSmall() {
    XCTAssertEqual(rejection(hand(Shape.thumbOutFist, palm: 0.08, rotation: 90)), .tooSmall)
    XCTAssertEqual(rejection(hand(Shape.flatGrip, palm: 0.13, center: (0.4, 0.3))), .tooSmall)  // hand on the desk
  }

  func testLowConfidenceAndMissingJointsAreRejected() {
    XCTAssertEqual(rejection(hand(Shape.thumbOutFist, rotation: 90, confidence: 0.3)), .lowConfidence)
    XCTAssertEqual(rejection(HandPose(joints: [:])), .missingJoint)
    XCTAssertNil(gesture(HandPose(joints: [:])))
  }

  func testOneSelfOccludedFingerIsToleratedButTwoAreNot() {
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: 90, overrides: [.ringTip: 0.1])), .thumbsUp)
    XCTAssertNil(gesture(hand(Shape.thumbOutFist, rotation: 90, overrides: [.ringTip: 0.1, .littleTip: 0.1])))
  }

  func testHandsTouchingTheFrameEdgeAreRejected() {
    XCTAssertEqual(rejection(hand(Shape.thumbOutFist, center: (0.86, 0.5), rotation: 90)), .nearEdge)
  }

  func testTwoHandsMustAgree() {
    let paper = hand(Shape.flatGrip, center: (0.72, 0.45), rotation: 90)
    let up = hand(Shape.thumbOutFist, center: (0.3, 0.7), rotation: -90, mirrored: true, chirality: .left)
    let down = hand(Shape.thumbOutFist, center: (0.7, 0.3), rotation: -90)
    XCTAssertEqual(all.classify([paper, up], imageWidth: 720, imageHeight: 1280), .thumbsUp)
    XCTAssertEqual(all.classify([down, paper], imageWidth: 720, imageHeight: 1280), .thumbsDown)
    XCTAssertNil(all.classify([up, down], imageWidth: 720, imageHeight: 1280))
    XCTAssertNil(all.classify([], imageWidth: 720, imageHeight: 1280))
  }

  // MARK: Temporal gate

  func testGateFiresAfterFourConsecutiveFramesSpanningTheHold() {
    var gate = GestureGate()
    XCTAssertNil(gate.observe(.thumbsUp, at: 10.00))
    XCTAssertNil(gate.observe(.thumbsUp, at: 10.33))
    XCTAssertEqual(gate.progress(at: 10.33), min(2.0 / 4.0, 0.33 / 0.9), accuracy: 1e-9)
    XCTAssertNil(gate.observe(.thumbsUp, at: 10.66))
    XCTAssertEqual(gate.observe(.thumbsUp, at: 10.99), .thumbsUp)
  }

  func testGateNeedsTheMinimumHoldWhenAnalysisIsFast() {
    var gate = GestureGate()
    for time in [0, 0.2, 0.4, 0.6, 0.8] { XCTAssertNil(gate.observe(.thumbsUp, at: time)) }
    XCTAssertEqual(gate.observe(.thumbsUp, at: 1.0), .thumbsUp)
  }

  func testGateRestartsOnAMissedFrameAGapOrAnotherGesture() {
    var missed = GestureGate()
    for time in [0, 0.33] { XCTAssertNil(missed.observe(.thumbsUp, at: time)) }
    XCTAssertNil(missed.observe(nil, at: 0.66))
    for time in [0.99, 1.32, 1.65] { XCTAssertNil(missed.observe(.thumbsUp, at: time)) }
    XCTAssertEqual(missed.observe(.thumbsUp, at: 1.98), .thumbsUp)

    var gapped = GestureGate()
    for time in [0, 0.33, 0.66, 1.66, 1.99, 2.32] { XCTAssertNil(gapped.observe(.thumbsUp, at: time)) }

    var switched = GestureGate()
    for time in [0, 0.33, 0.66] { XCTAssertNil(switched.observe(.thumbsUp, at: time)) }
    for time in [0.99, 1.32, 1.65] { XCTAssertNil(switched.observe(.thumbsDown, at: time)) }
    XCTAssertEqual(switched.observe(.thumbsDown, at: 1.98), .thumbsDown)

    var backwards = GestureGate()
    for time in [1.0, 1.33, 1.2, 1.53, 1.86] { XCTAssertNil(backwards.observe(.thumbsUp, at: time)) }
    XCTAssertEqual(backwards.observe(.thumbsUp, at: 2.19), .thumbsUp)
  }

  func testGateNeverFiresWhileACaptureIsInProgress() {
    var gate = GestureGate()
    for time in [0, 0.33, 0.66, 0.99, 1.32] { XCTAssertNil(gate.observe(.thumbsUp, at: time, allowed: false)) }
    for time in [1.65, 1.98, 2.31] { XCTAssertNil(gate.observe(.thumbsUp, at: time)) }
    XCTAssertEqual(gate.observe(.thumbsUp, at: 2.64), .thumbsUp)
  }

  func testHoldingTheGestureFiresOnceUntilReleased() {
    var gate = GestureGate()
    for time in [0, 0.33, 0.66] { XCTAssertNil(gate.observe(.thumbsUp, at: time)) }
    XCTAssertEqual(gate.observe(.thumbsUp, at: 0.99), .thumbsUp)
    var time = 1.32
    while time < 6.0 { XCTAssertNil(gate.observe(.thumbsUp, at: time)); time += 0.33 }  // still held: no repeat
    XCTAssertNil(gate.observe(nil, at: 6.27))
    XCTAssertNil(gate.observe(nil, at: 6.60))                                           // released
    for time in [6.93, 7.26, 7.59] { XCTAssertNil(gate.observe(.thumbsUp, at: time)) }
    XCTAssertEqual(gate.observe(.thumbsUp, at: 7.92), .thumbsUp)
  }

  func testCooldownBlocksAnotherGestureRightAfterFiring() {
    var gate = GestureGate()
    for time in [0, 0.33, 0.66] { XCTAssertNil(gate.observe(.thumbsUp, at: time)) }
    XCTAssertEqual(gate.observe(.thumbsUp, at: 0.99), .thumbsUp)                      // cooldown until 2.99
    for time in [1.32, 1.65, 1.98, 2.31, 2.64, 2.97, 3.30, 3.63, 3.96] {
      XCTAssertNil(gate.observe(.thumbsDown, at: time))
    }
    XCTAssertEqual(gate.observe(.thumbsDown, at: 4.29), .thumbsDown)
  }

  // MARK: Vision adapter

  func testVisionAdapterMapsEveryJointAndConfiguresTheRequest() {
    let names = Set(HandJoint.allCases.map { HandPoseVision.visionName(for: $0) })
    XCTAssertEqual(names.count, 21)
    let request = HandPoseVision.makeRequest()
    XCTAssertEqual(request.maximumHandCount, 2)
    XCTAssertEqual(request.revision, VNDetectHumanHandPoseRequestRevision1)
    let rotated = HandPoseVision.orientedSize(width: 720, height: 1280, orientation: .right)
    XCTAssertEqual(rotated.width, 1280)
    XCTAssertEqual(rotated.height, 720)
    let upright = HandPoseVision.orientedSize(width: 720, height: 1280, orientation: .up)
    XCTAssertEqual(upright.width, 720)
    XCTAssertEqual(upright.height, 1280)
  }

  func testBlankFrameReportsNoHands() throws {
    let context = try XCTUnwrap(CGContext(data: nil, width: 360, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 360, height: 640))
    let image = try XCTUnwrap(context.makeImage())
    XCTAssertEqual(HandPoseVision.downscaled(image, maxLongEdge: 320).height, 320)
    // Some simulator runtimes cannot load Vision's hand model; only assert that no hand is invented.
    let hands = (try? HandPoseVision.detect(in: image, maxLongEdge: 320)) ?? []
    XCTAssertTrue(hands.isEmpty)
    XCTAssertNil(standard.classify(hands, imageWidth: 360, imageHeight: 640))
  }
}
