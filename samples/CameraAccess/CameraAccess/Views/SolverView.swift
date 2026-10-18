import SwiftUI
import PhotosUI
import Security
import UIKit

// Personal-device key: never included in the repository or build artifact.
@MainActor
enum SolverKeychain {
  static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "GlassesSolver", kSecAttrAccount as String: "OpenAI"]
  static func read() -> String {
    var q = query
    q[kSecReturnData as String] = true
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data else { return "" }
    return String(decoding: data, as: UTF8.self)
  }
  static func save(_ key: String) throws {
    if key.isEmpty { SecItemDelete(query as CFDictionary); return }
    let data = Data(key.utf8)
    var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var q = query
      q[kSecValueData as String] = data
      q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      status = SecItemAdd(q as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw SolverError.message("Could not save API key (\(status)).") }
  }
}

enum SolverError: LocalizedError {
  case message(String)
  var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct SolverSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var key = SolverKeychain.read()
  @AppStorage("solverModel") private var model = "gpt-5.4"
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section("OpenAI") {
          SecureField("API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
          TextField("Vision model", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
          Text("Auto Scan sends a photo to OpenAI after its quality checks pass. Imported photos are also processed automatically. API usage is billed separately from ChatGPT. Your key stays in this iPhone’s Keychain.").font(.footnote)
        }
        Section("Model presets") {
          Button("Use GPT-5.4 · reasoning") { model = "gpt-5.4" }
          Button("Use GPT-4.1 · faster") { model = "gpt-4.1" }
          Text("A scan can make up to two AI requests if the first asks for a clearer photo. Preview checks run on your phone.").font(.footnote)
        }
        if let error { Text(error).foregroundStyle(.red) }
        Button("Save") {
          do { try SolverKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
          catch { self.error = error.localizedDescription }
        }
      }.navigationTitle("Solver settings")
        .toolbar { Button("Close") { dismiss() } }
    }
  }
}

struct SolverView: View {
  var initialImage: UIImage? = nil
  var body: some View {
    AutoScanView(initialImage: initialImage, importOnly: true)
  }
}
