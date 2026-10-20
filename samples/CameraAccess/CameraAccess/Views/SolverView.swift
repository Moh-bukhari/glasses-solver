import SwiftUI
import Security
import UIKit

// Separate personal-device credentials. Preserve the original OpenAI account for upgrades.
@MainActor
enum SolverKeychain {
  static func query(_ provider: AIProvider) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "GlassesSolver",
     kSecAttrAccount as String: provider == .openAI ? "OpenAI" : "Anthropic"]
  }
  static func read(_ provider: AIProvider = .openAI) -> String {
    var q = query(provider); q[kSecReturnData as String] = true
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
    return String(decoding: data, as: UTF8.self)
  }
  static func save(_ key: String, provider: AIProvider = .openAI) throws {
    let query = query(provider)
    if key.isEmpty {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw SolverError.message("Could not remove the API key (\(status)).") }
      return
    }
    let data = Data(key.utf8)
    var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var q = query; q[kSecValueData as String] = data
      q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      status = SecItemAdd(q as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw SolverError.message("Could not save API key (\(status)).") }
  }
  static func configuration() -> SolverConfiguration {
    let defaults = UserDefaults.standard
    return SolverConfiguration(mode: .claude,
      openAIKey: read(.openAI), claudeKey: read(.claude),
      openAIModel: defaults.string(forKey: "solverModel") ?? "gpt-5.4",
      claudeModel: defaults.string(forKey: "claudeModel") ?? SolverConfiguration.defaultClaudeModel)
  }
}

struct SolverSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var claudeKey = SolverKeychain.read(.claude)
  @State private var claudeModel = SolverKeychain.configuration().claudeModel
  @AppStorage("cueVolume") private var volume = Double(ScanVoice.quietVolume)
  @AppStorage("voiceCommands") private var commands = true
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section("Claude") {
          SecureField("Anthropic API key", text: $claudeKey).textInputAutocapitalization(.never).autocorrectionDisabled()
          TextField("Claude vision model", text: $claudeModel).textInputAutocapitalization(.never).autocorrectionDisabled()
          Button("Use Claude Sonnet") { claudeModel = SolverConfiguration.defaultClaudeModel }
          Text("Claude combines overlapping photos, organizes the question parts, and returns short calculations and answers for your CG50. Unreadable details get their own review pages; the rest still finish.").font(.footnote)
        }
        Section("Voice") {
          Toggle("Hands-free voice commands", isOn: $commands)
          Text("Commands use on-device English speech recognition and need microphone permission. If unavailable, use Finish scanning on screen.").font(.footnote)
          LabeledContent("Cue volume", value: "\(Int((volume * 100).rounded()))%")
          Slider(value: $volume, in: 0.05...1, step: 0.05)
          Button("Reset to quietest · 5%") { volume = 0.05 }
          Text("5% is the quiet default. iPhone volume and the selected audio output still apply.").font(.footnote)
        }
        Section("Photos and calculator output") {
          Text("Up to \(BatchSolver.maxPhotos) photos and 60 question subparts per batch. Add wide shots and close-ups in any order, then Finish. Photo quality never blocks the other questions.")
          Text("Each calculator picture shows the question label and Page n/m. Download the G3P ZIP, extract it on your computer, and copy the .g3p files to the calculator's storage. The PDF remains available as a reference.")
          Text("One organization request, then one request per group of up to 6 subparts, with up to two groups running at once. Temporary service errors and malformed responses have bounded retries. API usage is billed by Anthropic.")
          Text("Your Claude key stays in the iPhone Keychain. Photos are uploaded only after Finish. Keep the app open while solving.")
        }.font(.footnote)
        if let error { Text(error).foregroundStyle(.red) }
        Button("Save settings") {
          do {
            try SolverKeychain.save(claudeKey.trimmed, provider: .claude)
            let defaults = UserDefaults.standard
            defaults.set(SolverMode.claude.rawValue, forKey: "solverMode")
            defaults.set(claudeModel.trimmed, forKey: "claudeModel"); dismiss()
          } catch { self.error = error.localizedDescription }
        }
      }.navigationTitle("Solver settings")
        .toolbar { Button("Close") { dismiss() } }
    }
  }
}

struct SolverView: View {
  var initialImage: UIImage? = nil
  var body: some View { AutoScanView(initialImage: initialImage, importOnly: true) }
}
