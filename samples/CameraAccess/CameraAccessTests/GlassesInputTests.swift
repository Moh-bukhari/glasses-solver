@testable import CameraAccess
import XCTest
import MWDATInputs

/// Kept apart from MWDATMockDevice, which redeclares the Inputs enums.
final class GlassesInputTests: XCTestCase {
  func testGlassesClicksMapToScanCommands() {
    XCTAssertEqual(ScanCommand.glasses(.select(source: .captouch, timestampMs: 1)), .finish)
    XCTAssertEqual(ScanCommand.glasses(.capture(.doublePress, source: .captureButton, timestampMs: 1)), .finish)
    XCTAssertEqual(ScanCommand.glasses(.capture(.shortPress, source: .captureButton, timestampMs: 1)), .next)
    XCTAssertEqual(ScanCommand.glasses(.capture(.hold, source: .captureButton, timestampMs: 1)), .previous)
    XCTAssertEqual(ScanCommand.glasses(.button(.action, source: .actionButton, timestampMs: 1)), .finish)
  }
  func testSwipesBackAndOtherSourcesAreIgnored() {
    // Swipe direction depends on the wearer's settings and fires when adjusting the glasses.
    XCTAssertNil(ScanCommand.glasses(.nav(direction: .left, source: .captouch, timestampMs: 1)))
    XCTAssertNil(ScanCommand.glasses(.back(source: .captouch, timestampMs: 1)))
    XCTAssertNil(ScanCommand.glasses(.select(source: .neuralBand, timestampMs: 1)))
    XCTAssertNil(ScanCommand.glasses(.drag(action: .move, x: 0, y: 0, dx: 1, dy: 0, source: .neuralBandDrag, timestampMs: 1)))
  }
}
