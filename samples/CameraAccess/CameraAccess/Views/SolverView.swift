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
      claudeModel: defaults.string(forKey: "claudeModel") ?? SolverConfiguration.claudeDefault,
      fastTiers: defaults.object(forKey: "fastProcessing") as? Bool ?? true)
  }
  /// With both keys, both providers solve every page and Claude Opus 5.5 reconciles (2.7: best answer, cost no object).
  /// With one key, that provider.
  static func defaultMode() -> SolverMode {
    let claude = !read(.claude).isEmpty, openAI = !read(.openAI).isEmpty
    return claude && openAI ? .both : claude ? .claude : .openAI
  }
  /// 2.0 moves the old defaults to GPT-6.1 Sol / Claude Opus 5.5 and single-provider solving.
  /// Custom model IDs are kept; cross-check mode can be chosen again in Settings.
  static func migrateDefaults() {
    let defaults = UserDefaults.standard
    let version = defaults.integer(forKey: "settingsVersion")
    guard version < 7 else { return }
    if version < 2 {
      if defaults.string(forKey: "solverModel") == "gpt-5.4" { defaults.set(SolverConfiguration.openAIDefault, forKey: "solverModel") }
      if defaults.string(forKey: "claudeModel") == "claude-sonnet-5-5" { defaults.set(SolverConfiguration.claudeDefault, forKey: "claudeModel") }
      if defaults.string(forKey: "solverMode") == SolverMode.both.rawValue {
        defaults.set(defaultMode().rawValue, forKey: "solverMode"); defaults.set(true, forKey: "solverModeNotice")
      }
      // 2.0 is controlled by gestures; an old "on" choice must not keep the microphone open.
      defaults.set(false, forKey: "voiceCommands")
    }
    if version < 3 {
      // 2.1 is controlled by hand gestures only. Glasses buttons (Meta's experimental Inputs) stay an opt-in in Settings.
      defaults.set(false, forKey: "glassesButtons")
    }
    if version < 4 {
      // 2.4 checks each page while scanning and solves everything after the thumbs-up.
      defaults.set(false, forKey: "solveWhileScanning")
    }
    if version < 5 {
      // 2.5: the user asked for the best accuracy and speed from either provider, whatever the cost. Claude Opus 5.5
      // reads printed values best, so Claude solves when its key is saved; GPT-6 Astra is OpenAI's best reader.
      if defaults.string(forKey: "solverModel") == "gpt-6.1-sol" { defaults.set(SolverConfiguration.openAIDefault, forKey: "solverModel") }
      if !read(.claude).isEmpty && defaults.string(forKey: "solverMode") != SolverMode.both.rawValue {
        defaults.set(SolverMode.claude.rawValue, forKey: "solverMode")
      }
    }
    if version < 6 {
      // 2.6: the glasses' video is too blurry for small print, so pages are photographed with the capture button.
      defaults.set(AutoScanModel.CaptureMode.buttonPhotos.rawValue, forKey: "captureMode")
    }
    // 2.7: the user asked for both APIs on every page, for the best solutions.
    if !read(.claude).isEmpty && !read(.openAI).isEmpty { defaults.set(SolverMode.both.rawValue, forKey: "solverMode") }
    defaults.set(7, forKey: "settingsVersion")
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
  @AppStorage("solveWhileScanning") private var solveWhileScanning = false
  @AppStorage("checkPages") private var checkPages = true
  @AppStorage("fastProcessing") private var fastProcessing = true
  @AppStorage("captureMode") private var captureMode = AutoScanModel.CaptureMode.buttonPhotos.rawValue
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section("Solve with") {
          Picker("AI provider", selection: $mode) {
            ForEach(SolverMode.allCases) { Text($0.name).tag($0) }
          }
          Text(mode == .both
            ? "Claude Opus 5.5 and GPT-6 Astra each solve every page, then Claude checks both against your photo and writes the final answer. The most accurate; each page takes an extra round and costs more."
            : "Claude Opus 5.5 reads printed numbers most accurately; GPT-6 Astra is OpenAI's best. One request per page, with worked steps and its own check.").font(.footnote)
          Toggle("Fast processing", isOn: $fastProcessing)
          Text(fastProcessing
            ? "Uses Claude fast mode or OpenAI Ultrafast: the same answers, up to several times sooner, at several times the price. If your account can't use them, the app falls back by itself."
            : "Standard speed and price.").font(.footnote)
          Toggle("Check each page before the next", isOn: $checkPages)
          Text(checkPages
            ? "Each page's photos are checked by the most accurate reader you have a key for (Claude Opus 5.5, else GPT-6 Astra) that every question can be read. You hear \"Page 1 is clear\" before you move on, or what to photograph again."
            : "No AI check: with glasses photos each photo is saved as its own page; with live frames a page is saved once nothing new appears.").font(.footnote)
          Toggle("Solve pages while scanning (live frames)", isOn: $solveWhileScanning)
          Text(solveWhileScanning
            ? "Each page is uploaded and solved as soon as the next page is saved, so the PDF is ready moments after you finish."
            : "Live-frame pages are solved after your thumbs-up, all at once. Glasses photos are always solved as you go.").font(.footnote)
        }
        Section("Capture") {
          Picker("Photos", selection: $captureMode) {
            Text("Glasses photos · capture button").tag(AutoScanModel.CaptureMode.buttonPhotos.rawValue)
            Text("Live frames · hands-free").tag(AutoScanModel.CaptureMode.frames.rawValue)
            Text("Full-resolution photo · stream").tag(AutoScanModel.CaptureMode.photos.rawValue)
          }
          Text(captureMode == AutoScanModel.CaptureMode.buttonPhotos.rawValue
            ? "Recommended: you take each photo with the capture button, the sharpest the glasses can take. Meta AI imports it into Photos (turn on Auto-import in Meta AI, and give this app Full Access to Photos), and it is checked as soon as it arrives."
            : captureMode == AutoScanModel.CaptureMode.photos.rawValue
            ? "One 12-megapixel photo per page through the camera stream. Each photo pauses the camera and takes several seconds."
            : "Keeps the clearest moments of the live video, several per page. Hands-free, but the video is much blurrier than photos.").font(.footnote)
        }
        // Both keys are always editable: page checks use Claude whenever its key is saved, whichever provider solves.
        Section {
          SecureField("Anthropic API key", text: $claudeKey).textInputAutocapitalization(.never).autocorrectionDisabled()
          TextField("Claude vision model", text: $claudeModel).textInputAutocapitalization(.never).autocorrectionDisabled()
          Button("Use Claude Opus 5.5 · most accurate") { claudeModel = SolverConfiguration.claudeDefault }
          Button("Use Claude Sonnet 5.5") { claudeModel = "claude-sonnet-5-5" }
        } header: { Text("Claude") } footer: {
          Text("With a Claude key saved, every page is checked by Claude Opus 5.5, even when OpenAI solves.")
        }
        Section("OpenAI") {
          SecureField("OpenAI API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
          TextField("OpenAI vision model", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
          Button("Use GPT-6 Astra · most accurate") { model = SolverConfiguration.openAIDefault }
          Button("Use GPT-6.1 Sol") { model = "gpt-6.1-sol" }
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
            let addedClaude = SolverKeychain.read(.claude).isEmpty && !claudeKey.trimmed.isEmpty
            let addedOpenAI = SolverKeychain.read(.openAI).isEmpty && !key.trimmed.isEmpty
            try SolverKeychain.save(key.trimmed, provider: .openAI)
            try SolverKeychain.save(claudeKey.trimmed, provider: .claude)
            let defaults = UserDefaults.standard
            // The chosen provider must have a key; a newly added Claude key solves (Claude Opus 5.5 reads best).
            var mode = self.mode
            if mode == .openAI && (key.trimmed.isEmpty || addedClaude) && !claudeKey.trimmed.isEmpty { mode = .claude }
            if mode == .claude && claudeKey.trimmed.isEmpty && !key.trimmed.isEmpty { mode = .openAI }
            // Both providers whenever both keys are saved and one was just added; never Both with a key missing.
            if !key.trimmed.isEmpty && !claudeKey.trimmed.isEmpty && (addedClaude || addedOpenAI) { mode = .both }
            if mode == .both && (key.trimmed.isEmpty || claudeKey.trimmed.isEmpty) {
              mode = claudeKey.trimmed.isEmpty ? .openAI : .claude
            }
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
