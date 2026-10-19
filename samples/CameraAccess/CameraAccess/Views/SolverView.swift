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
    migrateDefaults()
    let defaults = UserDefaults.standard
    return SolverConfiguration(mode: SolverMode(rawValue: defaults.string(forKey: "solverMode") ?? "") ?? defaultMode(),
      openAIKey: read(.openAI), claudeKey: read(.claude),
      openAIModel: defaults.string(forKey: "solverModel") ?? SolverConfiguration.openAIDefault,
      claudeModel: defaults.string(forKey: "claudeModel") ?? SolverConfiguration.claudeDefault)
  }
  /// One provider is fastest: OpenAI when its key exists (the original setup), otherwise Claude.
  static func defaultMode() -> SolverMode {
    !read(.openAI).isEmpty ? .openAI : (!read(.claude).isEmpty ? .claude : .openAI)
  }
  /// 2.0 moves the old defaults to GPT-6.1 Sol / Claude Opus 5.5 and single-provider solving.
  /// Custom model IDs are kept; cross-check mode can be chosen again in Settings.
  static func migrateDefaults() {
    let defaults = UserDefaults.standard
    let version = defaults.integer(forKey: "settingsVersion")
    guard version < 3 else { return }
    if version < 2 {
      if defaults.string(forKey: "solverModel") == "gpt-5.4" { defaults.set(SolverConfiguration.openAIDefault, forKey: "solverModel") }
      if defaults.string(forKey: "claudeModel") == "claude-sonnet-5-5" { defaults.set(SolverConfiguration.claudeDefault, forKey: "claudeModel") }
      if defaults.string(forKey: "solverMode") == SolverMode.both.rawValue {
        defaults.set(defaultMode().rawValue, forKey: "solverMode"); defaults.set(true, forKey: "solverModeNotice")
      }
      // 2.0 is controlled by gestures; an old "on" choice must not keep the microphone open.
      defaults.set(false, forKey: "voiceCommands")
    }
    // 2.1 is controlled by hand gestures only. Glasses buttons (Meta's experimental Inputs) stay an opt-in in Settings.
    defaults.set(false, forKey: "glassesButtons")
    defaults.set(3, forKey: "settingsVersion")
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
  @AppStorage("voiceGuidance") private var guidance = true
  @AppStorage("privateAudio") private var privateAudio = true
  @AppStorage("voiceCommands") private var commands = false
  @AppStorage("handGestures") private var gestures = true
  @AppStorage("glassesButtons") private var glassesButtons = false
  @AppStorage("solveWhileScanning") private var solveWhileScanning = true
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section("Solve with") {
          Picker("AI provider", selection: $mode) {
            ForEach(SolverMode.allCases) { Text($0.name).tag($0) }
          }
          Text(mode == .both
            ? "Both APIs solve every page independently, then OpenAI reconciles the two answers against your photo. More careful, but each page takes an extra round and costs more."
            : "Fastest: one request per page. Each answer includes worked steps and its own check.").font(.footnote)
          Toggle("Solve pages while scanning", isOn: $solveWhileScanning)
          Text(solveWhileScanning
            ? "Each page is uploaded and solved as soon as the next page is saved, so the PDF is ready moments after you finish."
            : "Nothing is uploaded until you finish; then all pages are solved at once.").font(.footnote)
        }
        if mode != .claude {
          Section("OpenAI") {
            SecureField("OpenAI API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("OpenAI vision model", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Use GPT-6.1 Sol") { model = SolverConfiguration.openAIDefault }
          }
        }
        if mode != .openAI {
          Section("Claude") {
            SecureField("Anthropic API key", text: $claudeKey).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Claude vision model", text: $claudeModel).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Use Claude Opus 5.5") { claudeModel = SolverConfiguration.claudeDefault }
            Button("Use Claude Sonnet 5.5 · faster") { claudeModel = "claude-sonnet-5-5" }
          }
        }
        Section("Silent controls") {
          Toggle("Hand gestures", isOn: $gestures)
          Text("Fist with the thumb out, held about one second in front of the glasses: 👍 up solves, 👉 to your right is next page, 👈 to your left (or 👎) is previous page. Detection runs on the iPhone.").font(.footnote)
          Toggle("Glasses buttons (experimental)", isOn: $glassesButtons)
          Text("Off by default. Uses Meta's experimental Inputs, which may not reach the app on your glasses or Meta AI version. Gestures always work.").font(.footnote)
          Toggle("Voice commands", isOn: $commands)
          Text("Off by default. Turning this on uses the microphone and on-device speech recognition.").font(.footnote)
        }
        Section("Spoken directions") {
          Toggle("Speak directions and progress", isOn: $guidance)
          Toggle("Only through glasses or headphones", isOn: $privateAudio)
          LabeledContent("Volume", value: "\(Int((volume * 100).rounded()))%")
          Slider(value: $volume, in: 0.05...1, step: 0.05)
          Button("Reset to quietest · 5%") { volume = 0.05 }
          Text("Directions play quietly through the glasses and are never sent to the phone speaker while the private option is on. The screen shows the same instructions.").font(.footnote)
        }
        Section("Limits and usage") {
          Text("Up to \(AutoScanModel.maxPages) pages per packet. Each page is one request with its neighbors as context (three in cross-check mode). Overloads and dropped connections are retried at most twice; malformed answers get one repair. Key, billing and model errors are never retried.")
          Text("Keys stay in separate iPhone Keychain entries and are sent only to their own provider. API usage is billed by the selected providers. Check items marked NEEDS REVIEW in the PDF.")
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
      }.navigationTitle("Settings")
        .toolbar { Button("Close") { dismiss() } }
    }
  }
}

struct SolverView: View {
  var initialImage: UIImage? = nil
  var body: some View { AutoScanView(initialImage: initialImage, importOnly: true) }
}
