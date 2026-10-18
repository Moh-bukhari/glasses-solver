import SwiftUI
import PhotosUI
import MWDATCore
import PDFKit

struct AutoScanView: View {
  var wearablesVM: WearablesViewModel? = nil
  var initialImage: UIImage? = nil
  var importOnly = false
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = AutoScanModel(camera: AutoScanCamera(wearables: Wearables.shared))
  @State private var settings = false
  @State private var selection: PhotosPickerItem?
  @State private var importError: String?
  @State private var replacingPhoto: Int?
  @State private var confirmNewBatch = false
  @State private var importedInitial = false
  @AppStorage("voiceGuidance") private var voiceGuidance = true
  @AppStorage("voiceCommands") private var voiceCommands = true
  @AppStorage("cueVolume") private var cueVolume = Double(ScanVoice.quietVolume)

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text("All your pages. One solution PDF.").font(.title2.bold())
          Text("Scan each page close up. Say “finish scanning” when done. Your AI-reviewed PDF opens automatically.")
            .foregroundStyle(.secondary)
          viewfinder
          HStack(spacing: 10) {
            Image(systemName: phaseIcon).foregroundStyle(model.phase == .failed ? .orange : .mint)
            Text(model.guide).font(.headline)
          }.frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("scan_status")
          if model.phase == .seeking || model.phase == .capturing {
            ProgressView(value: model.progress).tint(.mint)
          } else if model.isRunning && model.phase != .awaitingNext { ProgressView().frame(maxWidth: .infinity) }
          if let importError { Text(importError).foregroundStyle(.red) }
          if !model.voiceStatus.isEmpty && model.isCollecting {
            Text(model.voiceStatus).font(.footnote).foregroundStyle(.secondary)
          }
          if model.canFinish {
            Button {
              applyVoiceSettings(); model.finishScanning()
              if model.needsKey { settings = true }
            } label: {
              Label("Finish scanning · Solve \(model.pages.count) pages", systemImage: "sparkles")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("finish_scanning")
          }
          if model.phase == .awaitingNext {
            Button("Next page") { model.nextPage() }.buttonStyle(.bordered)
          }
          if model.isRunning {
            Button(model.isCollecting ? "Pause scanning" : "Stop · keep saved pages", role: .destructive) { model.stop() }
              .buttonStyle(.bordered)
          } else {
            if !importOnly && model.pages.count < 12 {
              if let wearablesVM, wearablesVM.registrationState != .registered {
                Button("Connect glasses in Meta AI") { wearablesVM.connectGlasses() }.buttonStyle(.borderedProminent)
              } else {
                Button {
                  applyVoiceSettings(); model.start()
                } label: {
                  Label(model.pages.isEmpty ? "Start scanning pages" : "Continue scanning", systemImage: "viewfinder")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("start_auto_scan")
              }
            }
            if model.pages.count < 12 {
              PhotosPicker(selection: $selection, matching: .images) { Label("Add a paper photo", systemImage: "photo") }
                .simultaneousGesture(TapGesture().onEnded { replacingPhoto = nil }).buttonStyle(.bordered)
            }
            if model.result != nil {
              Button("Open combined PDF") { model.showPDF = true }.buttonStyle(.borderedProminent)
            }
          }
          if !model.pages.isEmpty { pageQueue }
          if !model.isRunning && !model.pages.isEmpty {
            Button("New batch", role: .destructive) { confirmNewBatch = true }.buttonStyle(.bordered)
          }
          Toggle("Spoken cues and progress", isOn: $voiceGuidance)
            .onChange(of: voiceGuidance) { _, _ in applyVoiceSettings() }
          Text("Keep this app open and the phone unlocked. Pages stay saved if you pause. Bring all writing and diagrams into view; no clean background or paper outline is needed.")
            .font(.footnote).foregroundStyle(.secondary)
          Text("Cue volume: \(Int((cueVolume * 100).rounded()))% · change in Settings.").font(.caption).foregroundStyle(.secondary)
        }.padding(20)
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle(importOnly ? "Add paper photos" : "Auto Scan")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button { settings = true } label: { Image(systemName: "gearshape") }.disabled(model.isRunning) }
      .sheet(isPresented: $settings, onDismiss: { applyVoiceSettings() }) { SolverSettingsView() }
      .sheet(isPresented: $model.showPDF) { if let result = model.result { SolutionViewer(solution: result) } }
      .confirmationDialog("Clear the saved draft and start a new batch? Existing PDFs are kept.", isPresented: $confirmNewBatch, titleVisibility: .visible) {
        Button("Start new batch", role: .destructive) { model.newBatch() }
      }
      .task(id: selection) {
        guard let selection else { return }
        defer { self.selection = nil; replacingPhoto = nil }
        importError = nil
        do {
          guard let data = try await selection.loadTransferable(type: Data.self) else { throw SolverError.message("Could not import this photo.") }
          try Task.checkCancellation(); applyVoiceSettings()
          model.importPhoto(data, replacing: replacingPhoto)
        } catch is CancellationError {} catch { importError = error.localizedDescription }
      }
      .task {
        model.reloadDraft(); applyVoiceSettings()
        if !importedInitial, let initialImage, let data = initialImage.jpegData(compressionQuality: 0.95), model.phase == .idle {
          importedInitial = true
          model.importPhoto(data)
        }
      }
      .onChange(of: model.needsKey) { _, needed in if needed { settings = true } }
      .onChange(of: scenePhase) { _, value in if value == .background { model.backgrounded() } }
      .onDisappear { if model.isRunning { model.stop() } }
    }
  }
  private func applyVoiceSettings() {
    model.voiceGuidance = voiceGuidance; model.voiceCommands = voiceCommands
    model.cueVolume = Float(cueVolume)
  }
  private var pageQueue: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Saved pages · \(model.pages.count)/12").font(.headline)
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 12) {
          ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
            VStack(spacing: 6) {
              if let image = page.thumbnail {
                Image(uiImage: image).resizable().scaledToFit().frame(width: 110, height: 125)
                  .background(.black).clipShape(RoundedRectangle(cornerRadius: 10))
              }
              Text("Page \(index + 1)").font(.caption.bold())
              if !model.isRunning {
                if !importOnly {
                  Button("Retake") { applyVoiceSettings(); model.start(replacing: index) }.font(.caption)
                }
                PhotosPicker(selection: $selection, matching: .images) { Text("Replace photo").font(.caption) }
                  .simultaneousGesture(TapGesture().onEnded { replacingPhoto = index })
                Button("Remove", role: .destructive) { model.removePage(at: index) }.font(.caption)
              }
            }.frame(width: 110)
          }
        }
      }
    }
  }
  private var phaseIcon: String {
    switch model.phase {
    case .finished: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    case .solving, .saving: return "sparkles"
    case .awaitingNext: return "doc.on.doc"
    default: return "viewfinder"
    }
  }
  private var viewfinder: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black
        if let preview = model.preview, [.seeking, .awaitingNext, .capturing].contains(model.phase) {
          Image(decorative: preview, scale: 1).resizable().scaledToFit()
          ContentOutline(points: model.sample.corners, imageSize: CGSize(width: preview.width, height: preview.height))
            .stroke(model.sample.acceptable && model.sample.closeEnough ? Color.mint : Color.orange, lineWidth: 3)
        } else if let image = model.capturedPreview {
          Image(uiImage: image).resizable().scaledToFit()
        } else {
          VStack(spacing: 12) {
            Image(systemName: "doc.viewfinder").font(.system(size: 56, weight: .light))
            Text("Close-up writing • Good light • Hold still").font(.caption)
          }.foregroundStyle(.white.opacity(0.75))
        }
        if model.phase == .capturing || model.phase == .checking {
          Color.black.opacity(0.35); ProgressView().tint(.white).scaleEffect(1.5)
        }
      }.frame(width: geometry.size.width, height: geometry.size.height)
    }.frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 22))
  }
}

private struct ContentOutline: Shape {
  let points: [PagePoint]
  let imageSize: CGSize
  func path(in rect: CGRect) -> Path {
    guard points.count == 4, imageSize.width > 0, imageSize.height > 0 else { return Path() }
    let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
    let w = imageSize.width * scale, h = imageSize.height * scale
    let x = (rect.width - w) / 2, y = (rect.height - h) / 2
    let mapped = points.map { CGPoint(x: x + $0.x * w, y: y + (1 - $0.y) * h) }
    var path = Path(); path.move(to: mapped[0]); for point in mapped.dropFirst() { path.addLine(to: point) }; path.closeSubpath()
    return path
  }
}

struct SolutionViewer: View {
  let solution: SavedSolution
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      PDFPreview(url: solution.pdf).ignoresSafeArea(edges: .bottom)
        .navigationTitle(solution.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
          ToolbarItem(placement: .topBarTrailing) { ShareLink(item: solution.pdf) { Image(systemName: "square.and.arrow.up") } }
        }
    }
  }
}
struct PDFPreview: UIViewRepresentable {
  let url: URL
  func makeUIView(context: Context) -> PDFView {
    let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical; view.document = PDFDocument(url: url); return view
  }
  func updateUIView(_ view: PDFView, context: Context) {
    if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
  }
}
struct SolutionHistoryView: View {
  @State private var entries: [SavedSolution] = []
  @State private var selected: SavedSolution?
  var body: some View {
    NavigationStack {
      List(entries) { item in
        Button { selected = item } label: {
          VStack(alignment: .leading, spacing: 5) {
            Text(item.title).font(.headline)
            Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
          }
        }
      }.overlay {
        if entries.isEmpty { ContentUnavailableView("Your PDFs appear here", systemImage: "doc.richtext", description: Text("Finish an Auto Scan or import a paper photo.")) }
      }
      .navigationTitle("Solutions")
      .onAppear { entries = SolutionStore.history() }
      .sheet(item: $selected) { SolutionViewer(solution: $0) }
    }
  }
}
