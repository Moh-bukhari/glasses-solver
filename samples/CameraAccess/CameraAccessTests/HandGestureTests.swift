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
  /// Middle, ring and little straight and together (a flat hand).
  static let straightFingers: Points = [
    .middlePIP: (0, 1.39), .middleDIP: (0, 1.65), .middleTip: (0, 1.86),
    .ringPIP: (-0.23, 1.31), .ringDIP: (-0.235, 1.52), .ringTip: (-0.24, 1.73),
    .littlePIP: (-0.44, 1.12), .littleDIP: (-0.45, 1.28), .littleTip: (-0.46, 1.45)]
  /// Thumb extended sideways from the fist (perpendicular to the palm axis).
  static let thumbOut: Points = [.thumbCMC: (0.22, 0.22), .thumbMP: (0.48, 0.48), .thumbIP: (0.78, 0.56),
    .thumbTip: (1.05, 0.62)]

  static func merge(_ parts: Points...) -> Points {
    parts.reduce(into: Points()) { result, part in result.merge(part) { _, new in new } }
  }

  /// The one command shape: a fist with the thumb straight out. Rotated so the thumb points up, down, right or left.
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
  static let flatGrip = merge(knuckles, straightIndex, straightFingers, [
    .thumbCMC: (0.25, 0.22), .thumbMP: (0.50, 0.45), .thumbIP: (0.66, 0.68), .thumbTip: (0.78, 0.90)])
  static let pointing = merge(knuckles, curledFingers, straightIndex, [.thumbCMC: (0.22, 0.22),
    .thumbMP: (0.42, 0.50), .thumbIP: (0.25, 0.74), .thumbTip: (0.05, 0.82)])
  /// Lateral "key" pinch on a paper edge: fingers folded, thumb pressed on the side of the index finger.
  static let keyGrip = merge(knuckles, curledFingers, [.thumbCMC: (0.22, 0.22), .thumbMP: (0.48, 0.50),
    .thumbIP: (0.50, 0.75), .thumbTip: (0.40, 0.98)])
  static let lShape = merge(knuckles, curledFingers, straightIndex, thumbOut)

  // Holding the left or right edge of a sheet with the thumb on its front face (rotated so the thumb is level).
  /// Pinch: index and middle curled behind the sheet, their pads under the thumb pad (thumb tip 0.25 palm away).
  static let edgePinch = merge(knuckles, curledFingers, thumbOut, [
    .indexPIP: (0.50, 1.10), .indexDIP: (0.72, 0.86), .indexTip: (0.80, 0.60),
    .middlePIP: (0.22, 1.14), .middleDIP: (0.45, 0.95), .middleTip: (0.62, 0.70)])
  /// Pinch nearer the thumb's IP joint: the thumb tip still leads the fist by 0.38 palm along its axis, but the index
  /// tip is only 0.40 palm from it, so only the clearance rule rejects it.
  static let edgePinchAtIP = merge(knuckles, curledFingers, thumbOut, [
    .indexPIP: (0.45, 1.05), .indexDIP: (0.62, 0.78), .indexTip: (0.70, 0.42),
    .middlePIP: (0.18, 1.12), .middleDIP: (0.40, 0.92), .middleTip: (0.52, 0.62)])
  /// Sheet clamped between the base of a straight thumb and the side of the curled index; the thumb lies along
  /// the edge, parallel to the palm axis, and barely passes the knuckles.
  static let edgeClamp = merge(knuckles, curledFingers, [.thumbCMC: (0.22, 0.22), .thumbMP: (0.48, 0.50),
    .thumbIP: (0.53, 0.82), .thumbTip: (0.58, 1.14)])
  /// Flat fingers behind the sheet, straight thumb out across its front.
  static let flatThumbOut = merge(knuckles, straightIndex, straightFingers, thumbOut)
  /// Fingers hooked over the edge (middle and distal phalanges toward the camera), thumb straight out along it.
  static let hookThumbOut = merge(knuckles, thumbOut, [
    .indexPIP: (0.30, 1.40), .indexDIP: (0.31, 1.33), .indexTip: (0.31, 1.24),
    .middlePIP: (0, 1.45), .middleDIP: (0, 1.38), .middleTip: (0, 1.29),
    .ringPIP: (-0.24, 1.38), .ringDIP: (-0.24, 1.31), .ringTip: (-0.24, 1.23),
    .littlePIP: (-0.46, 1.17), .littleDIP: (-0.46, 1.11), .littleTip: (-0.46, 1.04)])
  /// Fist with an unusually long thumb (1.0 palm), long enough to lead the fist along two axes at 45 degrees.
  static let longThumbFist = merge(knuckles, curledFingers, [.thumbCMC: (0.22, 0.22), .thumbMP: (0.48, 0.48),
    .thumbIP: (0.95, 0.60), .thumbTip: (1.45, 0.72)])
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

/// `shape` rotated so its thumb (MP -> tip) points `degrees` counter-clockwise from image right (0 = right,
/// 90 = up, 180 = left). Unmirrored = right palm or back of a left hand; mirrored = left palm or back of a right hand.
private func thumb(_ degrees: Double, _ shape: Shape.Points = Shape.thumbOutFist, mirrored: Bool = false,
                   palm: Double = 0.25, center: (x: Double, y: Double) = (0.5, 0.5), chirality: HandChirality? = nil,
                   width: Int = 720, height: Int = 1280, overrides: [HandJoint: Double] = [:]) -> HandPose {
  let mp = shape[.thumbMP] ?? (0, 0), tip = shape[.thumbTip] ?? (1, 0)
  let dx = (mirrored ? -1.0 : 1.0) * (tip.0 - mp.0)
  let authored = atan2(tip.1 - mp.1, dx) * 180 / .pi
  return hand(shape, palm: palm, center: center, rotation: degrees - authored, mirrored: mirrored,
    chirality: chirality ?? (mirrored ? .left : .right), width: width, height: height, overrides: overrides)
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

  func testDefaultsEnableTheFourThumbDirectionsWithDisjointCones() {
    XCTAssertEqual(standard.enabled, [.thumbsUp, .thumbsDown, .thumbsRight, .thumbsLeft])
    XCTAssertEqual(HandGesture.thumbs, standard.enabled)
    XCTAssertFalse(standard.enabled.contains(.openPalm))
    let t = HandGestureClassifier.Thresholds()
    XCTAssertLessThan(t.thumbAxisTolerance + t.thumbSideTolerance, 90)
    // A classifier limited to up/down ignores sideways thumbs.
    let vertical = HandGestureClassifier(enabled: [.thumbsUp, .thumbsDown])
    XCTAssertNil(gesture(thumb(0), vertical))
    XCTAssertEqual(gesture(thumb(90), vertical), .thumbsUp)
    // If the tolerances are ever tuned to overlap, a thumb inside two cones is refused instead of taking the first.
    var overlapping = HandGestureClassifier.Thresholds()
    overlapping.thumbAxisTolerance = 50
    overlapping.thumbSideTolerance = 50
    let loose = HandGestureClassifier(thresholds: overlapping)
    XCTAssertNil(gesture(thumb(45, Shape.longThumbFist), loose))   // leads 0.87 palm right and 0.29 up
    XCTAssertEqual(gesture(thumb(20, Shape.longThumbFist), loose), .thumbsRight)
    XCTAssertNil(gesture(thumb(45, Shape.longThumbFist)))          // default cones: 45 degrees is in neither
  }

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

  func testThumbsDownBothHands() {
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: -90)), .thumbsDown)
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: 90, mirrored: true, chirality: .left)), .thumbsDown)
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: -90), standard), .thumbsDown)
  }

  func testThumbsRightAndLeftWithEitherHand() {
    // Palm toward the glasses (forearm turned palm-up): the right thumb points right, the left thumb left.
    XCTAssertEqual(gesture(thumb(0), standard), .thumbsRight)
    XCTAssertEqual(gesture(thumb(180, mirrored: true), standard), .thumbsLeft)
    // Back of the hand toward the glasses (palm down): right hand points left, left hand points right.
    XCTAssertEqual(gesture(thumb(180, mirrored: true, chirality: .right)), .thumbsLeft)
    XCTAssertEqual(gesture(thumb(0, chirality: .left)), .thumbsRight)
    XCTAssertEqual(gesture(thumb(0, chirality: .unknown)), .thumbsRight)
    // The unrotated authored fist already points right (thumb 13.8 deg above level); its mirror points left.
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist)), .thumbsRight)
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, mirrored: true, chirality: .left)), .thumbsLeft)
    // Only the thumb direction matters, not how the fist is turned around it.
    XCTAssertEqual(gesture(thumb(0, mirrored: true)), .thumbsRight)
    XCTAssertEqual(gesture(thumb(180)), .thumbsLeft)
  }

  func testSidewaysThumbsTolerateModerateTilts() {
    for mirrored in [false, true] {
      for tilt in [-20.0, -10, 10, 20] {
        XCTAssertEqual(gesture(thumb(tilt, mirrored: mirrored)), .thumbsRight, "right \(tilt) mirrored \(mirrored)")
        XCTAssertEqual(gesture(thumb(180 + tilt, mirrored: mirrored)), .thumbsLeft, "left \(tilt) mirrored \(mirrored)")
      }
    }
    // Tilted up toward the knuckle side, up to the 35-degree cone (right palm right, left palm left).
    for tilt in [25.0, 30, 34] {
      XCTAssertEqual(gesture(thumb(tilt)), .thumbsRight, "right +\(tilt)")
      XCTAssertEqual(gesture(thumb(180 - tilt, mirrored: true)), .thumbsLeft, "left +\(tilt)")
    }
    // Tilted the other way the knuckles lean into the pointing direction; past about 28 degrees the tip no longer
    // leads them by 0.25 palm (0.22 at 30 degrees), as for thumbs up/down.
    XCTAssertNil(gesture(thumb(-30)))
    XCTAssertNil(gesture(thumb(210, mirrored: true)))
  }

  func testDiagonalThumbsMatchNoDirection() {
    for mirrored in [false, true] {
      for diagonal in [45.0, 135, 225, 315] {
        for offset in [-8.0, -3, 0, 3] {   // 37-48 degrees from horizontal: between the cones
          let pose = thumb(diagonal + offset * (diagonal == 45 || diagonal == 225 ? 1 : -1), mirrored: mirrored)
          XCTAssertNil(gesture(pose), "\(diagonal) \(offset) mirrored \(mirrored)")
          XCTAssertEqual(rejection(pose), .noMatch)
        }
      }
    }
    // The first two used to be "too far from vertical"; the second now points left (26.2 deg above level).
    XCTAssertNil(gesture(hand(Shape.thumbOutFist, rotation: 122)))                 // 45.8 deg from up
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: 140)), .thumbsLeft)  // 63.8 deg from up, lead 0.28
    XCTAssertEqual(gesture(thumb(128)), .thumbsUp)                                 // 38 deg from up
    XCTAssertEqual(gesture(thumb(52, mirrored: true)), .thumbsUp)
    XCTAssertEqual(gesture(thumb(-52)), .thumbsDown)                               // 38 deg from down
    XCTAssertEqual(gesture(thumb(-128, mirrored: true)), .thumbsDown)
  }

  func testNoThumbAngleMatchesTwoDirectionsOrTheWrongOne() {
    let side = HandGestureClassifier.Thresholds().thumbSideTolerance
    let vertical = HandGestureClassifier.Thresholds().thumbAxisTolerance
    for mirrored in [false, true] {
      for degrees in stride(from: -180, to: 180, by: 1) {
        let found = gesture(thumb(Double(degrees), mirrored: mirrored))
        let a = Double(degrees), fromRight = abs(a), fromLeft = 180 - abs(a)
        let fromUp = abs(a - 90), fromDown = abs(a + 90)
        let cone: HandGesture? = fromRight <= side ? .thumbsRight : fromLeft <= side ? .thumbsLeft
          : fromUp <= vertical ? .thumbsUp : fromDown <= vertical ? .thumbsDown : nil
        // Skip the exact cone edges, where acos rounding decides.
        if [fromRight, fromLeft].contains(side) || [fromUp, fromDown].contains(vertical) { continue }
        // Inside a cone: that direction or nothing (the lead rule may still refuse). Outside every cone: nothing.
        if let found { XCTAssertEqual(found, cone, "\(degrees) mirrored \(mirrored)") }
        if cone == nil { XCTAssertNil(found, "\(degrees) mirrored \(mirrored)") }
        // Within 20 degrees of an axis every hand layout is recognized.
        if min(fromRight, fromLeft) <= 20 || min(fromUp, fromDown) <= 20 {
          XCTAssertEqual(found, cone, "\(degrees) mirrored \(mirrored)")
        }
      }
    }
  }

  func testGeometryUsesTheFrameAspectRatio() {
    let landscape = hand(Shape.thumbOutFist, rotation: 90, width: 1280, height: 720)
    XCTAssertEqual(gesture(landscape, width: 1280, height: 720), .thumbsUp)
    XCTAssertEqual(all.evaluate(landscape, imageWidth: 1280, imageHeight: 720).palmSize, 0.25, accuracy: 1e-9)
    XCTAssertEqual(all.evaluate(hand(Shape.thumbOutFist, rotation: 90), imageWidth: 720, imageHeight: 1280).palmSize,
      0.25, accuracy: 1e-9)
    // 30 degrees above level stays 30 degrees in a landscape frame (not stretched to about 46 by the 16:9 aspect).
    XCTAssertEqual(gesture(thumb(30, width: 1280, height: 720), width: 1280, height: 720), .thumbsRight)
    XCTAssertEqual(gesture(thumb(150, mirrored: true, width: 1280, height: 720), width: 1280, height: 720),
      .thumbsLeft)
  }

  func testOpenPalmIsOptInAndRequiresThePalmFacingTheGlasses() {
    XCTAssertEqual(gesture(hand(Shape.openSpread)), .openPalm)
    XCTAssertEqual(gesture(hand(Shape.openSpread, mirrored: true, chirality: .left)), .openPalm)
    XCTAssertNil(gesture(hand(Shape.openSpread), standard))
    // Back of a right hand (e.g. flat on the desk) is the mirrored layout with right chirality.
    XCTAssertNil(gesture(hand(Shape.openSpread, mirrored: true, chirality: .right)))
    XCTAssertNil(gesture(hand(Shape.openSpread, chirality: .unknown)))
    XCTAssertNil(gesture(hand(Shape.openSpread, rotation: 90)))   // fingers sideways
    XCTAssertNil(gesture(hand(Shape.openSpread, rotation: -90)))  // fingers sideways, thumb up: not a thumb gesture
  }

  func testFistPointingAndLShapeAreIgnored() {
    XCTAssertNil(gesture(hand(Shape.fist)))
    XCTAssertNil(gesture(hand(Shape.fist, rotation: 90)))
    XCTAssertNil(gesture(hand(Shape.pointing)))
    XCTAssertNil(gesture(hand(Shape.lShape, rotation: 90)))       // thumb up but index extended
    // Sideways thumb with the index (or every finger) extended: L-shape, finger gun, pointing, flat hand.
    XCTAssertNil(gesture(thumb(0, Shape.lShape)))
    XCTAssertNil(gesture(thumb(180, Shape.lShape, mirrored: true)))
    XCTAssertNil(gesture(hand(Shape.lShape, rotation: -90)))      // finger gun: index pointing right, thumb down
    XCTAssertNil(gesture(hand(Shape.pointing, rotation: -90)))    // index pointing right, thumb tucked
    XCTAssertNil(gesture(hand(Shape.pointing, rotation: 90, mirrored: true, chirality: .left)))  // pointing left
    XCTAssertNil(gesture(thumb(0, Shape.flatThumbOut)))
    XCTAssertNil(gesture(hand(Shape.fist, rotation: -90)))
  }

  func testHandsHoldingPaperAreIgnored() {
    XCTAssertNil(gesture(hand(Shape.flatGrip, center: (0.72, 0.45), rotation: 90)))  // fingers sideways
    XCTAssertNil(gesture(hand(Shape.flatGrip, center: (0.5, 0.3))))                   // fingers up, together
    XCTAssertNil(gesture(hand(Shape.keyGrip)))                                        // thumb up, pinching
    XCTAssertNil(gesture(hand(Shape.keyGrip, rotation: 180)))                         // thumb down, pinching
    XCTAssertEqual(rejection(hand(Shape.keyGrip)), .noMatch)
    XCTAssertNil(gesture(thumb(0, Shape.keyGrip)))                                    // key pinch, thumb level
    XCTAssertNil(gesture(thumb(180, Shape.keyGrip, mirrored: true)))
  }

  func testSideEdgeGripsWithTheThumbOnTheSheetAreIgnored() {
    // Right hand on the right edge points its thumb left into the sheet (back of the hand toward the glasses);
    // left hand on the left edge points right. Also checked the other way round and tilted by 20 degrees.
    let grips = [Shape.edgePinch, Shape.edgePinchAtIP, Shape.edgeClamp, Shape.flatThumbOut, Shape.hookThumbOut]
    for (index, grip) in grips.enumerated() {
      for degrees in [0.0, 20, -20, 180, 160, 200] {
        for mirrored in [false, true] {
          let pose = thumb(degrees, grip, mirrored: mirrored, center: (0.5, 0.45))
          XCTAssertNil(gesture(pose), "grip \(index) at \(degrees) mirrored \(mirrored)")
          XCTAssertEqual(rejection(pose), .noMatch)
        }
      }
    }
    // Fingers hidden behind the sheet (Vision reports them with low confidence): unverifiable, not a fist.
    let hidden: [HandJoint: Double] = [.indexPIP: 0.1, .indexDIP: 0.1, .indexTip: 0.1, .middlePIP: 0.1,
      .middleDIP: 0.1, .middleTip: 0.1]
    XCTAssertNil(gesture(thumb(180, mirrored: true, chirality: .right, overrides: hidden)))
    XCTAssertNil(gesture(thumb(0, overrides: [.indexTip: 0.1])))
    XCTAssertNil(gesture(thumb(0, overrides: [.middlePIP: 0.1])))
  }

  func testSmallOrDistantHandsAreTooSmall() {
    XCTAssertEqual(rejection(hand(Shape.thumbOutFist, palm: 0.08, rotation: 90)), .tooSmall)
    XCTAssertEqual(rejection(hand(Shape.flatGrip, palm: 0.13, center: (0.4, 0.3))), .tooSmall)  // hand on the desk
    XCTAssertEqual(rejection(thumb(0, palm: 0.08)), .tooSmall)
    XCTAssertEqual(rejection(thumb(180, mirrored: true, palm: 0.14)), .tooSmall)
    XCTAssertEqual(gesture(thumb(0, palm: 0.16)), .thumbsRight)
    XCTAssertEqual(gesture(thumb(180, mirrored: true, palm: 0.16)), .thumbsLeft)
  }

  func testLowConfidenceAndMissingJointsAreRejected() {
    XCTAssertEqual(rejection(hand(Shape.thumbOutFist, rotation: 90, confidence: 0.3)), .lowConfidence)
    XCTAssertEqual(rejection(thumb(0, overrides: [.thumbTip: 0.3])), .lowConfidence)
    XCTAssertEqual(rejection(HandPose(joints: [:])), .missingJoint)
    XCTAssertNil(gesture(HandPose(joints: [:])))
  }

  func testOneSelfOccludedFingerIsToleratedButTwoAreNot() {
    XCTAssertEqual(gesture(hand(Shape.thumbOutFist, rotation: 90, overrides: [.ringTip: 0.1])), .thumbsUp)
    XCTAssertNil(gesture(hand(Shape.thumbOutFist, rotation: 90, overrides: [.ringTip: 0.1, .littleTip: 0.1])))
    XCTAssertEqual(gesture(thumb(0, overrides: [.littleTip: 0.1])), .thumbsRight)
    XCTAssertNil(gesture(thumb(0, overrides: [.ringTip: 0.1, .littleTip: 0.1])))
  }

  func testHandsTouchingTheFrameEdgeAreRejected() {
    XCTAssertEqual(rejection(hand(Shape.thumbOutFist, center: (0.86, 0.5), rotation: 90)), .nearEdge)
    // A level thumb reaches 1.02 palm (0.26 of the width at palm 0.25) right of the palm centre.
    XCTAssertEqual(gesture(thumb(0, center: (0.70, 0.5))), .thumbsRight)
    XCTAssertEqual(rejection(thumb(0, center: (0.74, 0.5))), .nearEdge)
    XCTAssertEqual(gesture(thumb(180, mirrored: true, center: (0.30, 0.5))), .thumbsLeft)
    XCTAssertEqual(rejection(thumb(180, mirrored: true, center: (0.26, 0.5))), .nearEdge)
  }

  func testTwoHandsMustAgree() {
    let paper = hand(Shape.flatGrip, center: (0.72, 0.45), rotation: 90)
    let up = hand(Shape.thumbOutFist, center: (0.3, 0.7), rotation: -90, mirrored: true, chirality: .left)
    let down = hand(Shape.thumbOutFist, center: (0.7, 0.3), rotation: -90)
    XCTAssertEqual(all.classify([paper, up], imageWidth: 720, imageHeight: 1280), .thumbsUp)
    XCTAssertEqual(all.classify([down, paper], imageWidth: 720, imageHeight: 1280), .thumbsDown)
    XCTAssertNil(all.classify([up, down], imageWidth: 720, imageHeight: 1280))
    XCTAssertNil(all.classify([], imageWidth: 720, imageHeight: 1280))
    let right = thumb(0, center: (0.6, 0.35)), left = thumb(180, mirrored: true, center: (0.4, 0.75))
    let edge = thumb(180, Shape.edgePinch, mirrored: true, center: (0.6, 0.75), chirality: .right)
    XCTAssertEqual(standard.classify([right, edge], imageWidth: 720, imageHeight: 1280), .thumbsRight)
    XCTAssertEqual(standard.classify([paper, left], imageWidth: 720, imageHeight: 1280), .thumbsLeft)
    XCTAssertNil(standard.classify([right, left], imageWidth: 720, imageHeight: 1280))
    XCTAssertNil(standard.classify([right, up], imageWidth: 720, imageHeight: 1280))
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
    for time in [0, 0.2, 0.4, 0.6, 0.8] { XCTAssertNil(gate.observe(.thumbsRight, at: time)) }
    XCTAssertEqual(gate.observe(.thumbsRight, at: 1.0), .thumbsRight)
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

  func testTurningTheThumbFiresOnlyTheDirectionThatIsHeld() {
    // Up for 0.66 s, through the diagonal (no match), then right: only right fires, after its own full hold.
    var turned = GestureGate()
    for time in [0, 0.33, 0.66] { XCTAssertNil(turned.observe(.thumbsUp, at: time)) }
    XCTAssertNil(turned.observe(nil, at: 0.99))
    for time in [1.32, 1.65, 1.98] { XCTAssertNil(turned.observe(.thumbsRight, at: time)) }
    XCTAssertEqual(turned.observe(.thumbsRight, at: 2.31), .thumbsRight)

    // Straight from right to left without a gap frame: still one fresh hold.
    var flipped = GestureGate()
    for time in [0, 0.33, 0.66] { XCTAssertNil(flipped.observe(.thumbsRight, at: time)) }
    for time in [0.99, 1.32, 1.65] { XCTAssertNil(flipped.observe(.thumbsLeft, at: time)) }
    XCTAssertEqual(flipped.observe(.thumbsLeft, at: 1.98), .thumbsLeft)

    // A wavering diagonal thumb that alternates between two directions never fires.
    var wavering = GestureGate()
    var time = 0.0
    for index in 0..<30 {
      XCTAssertNil(wavering.observe(index % 2 == 0 ? .thumbsUp : .thumbsRight, at: time)); time += 0.33
    }
  }

  func testGateNeverFiresWhileACaptureIsInProgress() {
    var gate = GestureGate()
    for time in [0, 0.33, 0.66, 0.99, 1.32] { XCTAssertNil(gate.observe(.thumbsUp, at: time, allowed: false)) }
    for time in [1.65, 1.98, 2.31] { XCTAssertNil(gate.observe(.thumbsUp, at: time)) }
    XCTAssertEqual(gate.observe(.thumbsUp, at: 2.64), .thumbsUp)
  }

  func testHoldingTheGestureFiresOnceUntilReleased() {
    var gate = GestureGate()
    for time in [0, 0.33, 0.66] { XCTAssertNil(gate.observe(.thumbsRight, at: time)) }
    XCTAssertEqual(gate.observe(.thumbsRight, at: 0.99), .thumbsRight)
    var time = 1.32
    while time < 6.0 { XCTAssertNil(gate.observe(.thumbsRight, at: time)); time += 0.33 }  // still held: no repeat
    XCTAssertNil(gate.observe(nil, at: 6.27))
    XCTAssertNil(gate.observe(nil, at: 6.60))                                              // released
    for time in [6.93, 7.26, 7.59] { XCTAssertNil(gate.observe(.thumbsRight, at: time)) }
    XCTAssertEqual(gate.observe(.thumbsRight, at: 7.92), .thumbsRight)                     // next page again
  }

  func testCooldownBlocksAnotherGestureRightAfterFiring() {
    var gate = GestureGate()
    for time in [0, 0.33, 0.66] { XCTAssertNil(gate.observe(.thumbsUp, at: time)) }
    XCTAssertEqual(gate.observe(.thumbsUp, at: 0.99), .thumbsUp)                      // cooldown until 2.99
    for time in [1.32, 1.65, 1.98, 2.31, 2.64, 2.97, 3.30, 3.63, 3.96] {
      XCTAssertNil(gate.observe(.thumbsDown, at: time))
    }
    XCTAssertEqual(gate.observe(.thumbsDown, at: 4.29), .thumbsDown)

    // Next page, then the thumb turned straight to "previous": the earliest second command is 3.3 s later.
    var sideways = GestureGate()
    for time in [0, 0.33, 0.66] { XCTAssertNil(sideways.observe(.thumbsRight, at: time)) }
    XCTAssertEqual(sideways.observe(.thumbsRight, at: 0.99), .thumbsRight)
    for time in [1.32, 1.65, 1.98, 2.31, 2.64, 2.97, 3.30, 3.63, 3.96] {
      XCTAssertNil(sideways.observe(.thumbsLeft, at: time))
    }
    XCTAssertEqual(sideways.observe(.thumbsLeft, at: 4.29), .thumbsLeft)
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
