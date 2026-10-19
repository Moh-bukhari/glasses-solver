import AppIntents
import Foundation

/// Opens Glasses Solver and starts a hands-free scan, so nothing needs tapping inside the app.
///
/// Run it from the Action button, Back Tap, Control Center, the Lock Screen, Spotlight, Siri or the Shortcuts
/// app. The app comes to the foreground first (`openAppWhenRun`); `perform()` only records the request, and
/// Auto Scan starts the glasses camera once the app is active, because the Meta camera session needs it.
struct StartScanIntent: AppIntent {
  // Constants: App Intents reads them at build time, and Swift 6 rejects stored static vars as shared mutable state.
  static let title: LocalizedStringResource = "Start Glasses Scan"
  static let description = IntentDescription(
    "Opens Glasses Solver and starts scanning with your glasses. Control the scan with hand gestures.")

  @MainActor
  func perform() async throws -> some IntentResult {
    AutoScanModel.shared.requestShortcutStart()
    return .result()
  }
}

/// Finishes the scan and solves, like a thumbs-up: for Siri ("Finish the scan in Glasses Solver") or a second
/// Action button shortcut.
struct FinishScanIntent: AppIntent {
  static let title: LocalizedStringResource = "Finish Glasses Scan"
  static let description = IntentDescription(
    "Solves the pages scanned so far and makes the PDF, like a thumbs-up.")

  @MainActor
  func perform() async throws -> some IntentResult {
    AutoScanModel.shared.handle(.finish)
    return .result()
  }
}

// Deprecated in the iOS 26 SDK in favor of `supportedModes`, which needs iOS 26; Apple documents this form for
// apps that still target earlier versions. At an iOS 26 deployment target use `static let supportedModes: IntentModes = .foreground`.
@available(*, deprecated)
extension StartScanIntent {
  static var openAppWhenRun: Bool { true }
}
@available(*, deprecated)
extension FinishScanIntent {
  static var openAppWhenRun: Bool { true }
}

/// Installs "Start Glasses Scan" with the app: Shortcuts, Spotlight, Siri and the Action button list it without setup.
struct GlassesSolverShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartScanIntent(),
      phrases: [
        "Start a scan in \(.applicationName)",
        "Start scanning with \(.applicationName)",
        "Scan pages with \(.applicationName)",
      ],
      shortTitle: "Start Glasses Scan",
      systemImageName: "viewfinder"
    )
    AppShortcut(
      intent: FinishScanIntent(),
      phrases: [
        "Finish the scan in \(.applicationName)",
        "Solve my pages with \(.applicationName)",
      ],
      shortTitle: "Finish Glasses Scan",
      systemImageName: "hand.thumbsup"
    )
  }
}
