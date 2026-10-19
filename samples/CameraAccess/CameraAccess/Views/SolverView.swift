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
    return SolverConfiguration(mode: SolverMode(rawValue: defaults.string(forKey: "solverMode") ?? "both") ?? .both,
      openAIKey: read(.openAI), claudeKey: read(.claude),
      openAIModel: defaults.string(forKey: "solverModel") ?? "gpt-5.4",
      claudeModel: defaults.string(forKey: "claudeModel") ?? "claude-sonnet-5-5")
  }
}

enum SolverError: LocalizedError {
  case message(String)
  var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct SolverSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var key = SolverKeychain.read(.openAI)
  @State private var claudeKey = SolverKeychain.read(.claude)
  @State private var mode = SolverKeychain.configuration().mode
  @State private var model = SolverKeychain.configuration().openAIModel
  @State private var claudeModel = SolverKeychain.configuration().claudeModel
  @AppStorage("cueVolume") private var volume = Double(ScanVoice.quietVolume)
  @AppStorage("voiceCommands") private var commands = true
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section("Solve with") {
          Picker("AI providers", selection: $mode) {
            ForEach(SolverMode.allCases) { Text($0.name).tag($0) }
          }
          Text(mode == .both
            ? "Both APIs receive your saved photos. Claude checks the question checklist; both solve independently, then OpenAI compares and reconciles their answers. Draft answers are shared between the services."
            : "The selected API inventories the packet, solves each group, then reviews its answers against your photos.").font(.footnote)
        }
        if mode != .claude {
          Section("OpenAI") {
            SecureField("OpenAI API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("OpenAI vision model", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Use GPT-5.4") { model = "gpt-5.4" }
            Button("Use GPT-4.1") { model = "gpt-4.1" }
          }
        }
        if mode != .openAI {
          Section("Claude") {
            SecureField("Anthropic API key", text: $claudeKey).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Claude vision model", text: $claudeModel).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Use Claude Sonnet 5.5") { claudeModel = "claude-sonnet-5-5" }
            Button("Use Claude Opus 5.5") { claudeModel = "claude-opus-5-5" }
          }
        }
        Section("Voice") {
          Toggle("Hands-free voice commands", isOn: $commands)
          Text("Commands use on-device English speech recognition and need microphone permission. If unavailable, use Finish scanning on screen.").font(.footnote)
          LabeledContent("Cue volume", value: "\(Int((volume * 100).rounded()))%")
          Slider(value: $volume, in: 0.05...1, step: 0.05)
          Button("Reset to quietest · 5%") { volume = 0.05 }
          Text("5% is the quiet default. iPhone volume and the selected audio output still apply.").font(.footnote)
        }
        Section("Batch limits and usage") {
          Text("Up to 12 photos and 60 question subparts per batch. Nothing is uploaded until you finish scanning. Longer packets and two-provider review take more time and API credit.")
          Text("With both APIs: 2 checklist requests, then 3 requests per group of up to 6 subparts. A malformed or incomplete response gets at most one repair per request. Network and billing errors are not automatically retried. Retrying the batch repeats these requests.")
          Text("Keys stay in separate iPhone Keychain entries. API usage is billed by the selected providers. Check flagged answers and the source transcription in the final PDF.")
        }.font(.footnote)
        if let error { Text(error).foregroundStyle(.red) }
        Button("Save settings") {
          do {
            try SolverKeychain.save(key.trimmed, provider: .openAI)
            try SolverKeychain.save(claudeKey.trimmed, provider: .claude)
            let defaults = UserDefaults.standard
            defaults.set(mode.rawValue, forKey: "solverMode"); defaults.set(model.trimmed, forKey: "solverModel")
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
