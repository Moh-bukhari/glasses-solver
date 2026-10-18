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
  @AppStorage("voiceGuidance") private var voiceGuidance = true

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text("See the problem. Get the solution.")
            .font(.title2.bold())
          Text(importOnly ? "Choose a photo to check, solve, and open as a PDF." : "Start once. Look at the problem and follow the voice cues. Your PDF opens automatically.")
            .foregroundStyle(.secondary)
          viewfinder
          HStack(spacing: 10) {
            Image(systemName: phaseIcon).foregroundStyle(model.phase == .failed ? .orange : .mint)
            Text(model.guide).font(.headline)
          }.frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("scan_status")
          if model.phase == .seeking || model.phase == .capturing {
            ProgressView(value: model.progress).tint(.mint)
          } else if model.isRunning { ProgressView().frame(maxWidth: .infinity) }
          if let importError { Text(importError).foregroundStyle(.red) }
          if model.isRunning {
            Button("Stop Auto Scan", role: .destructive) { model.stop() }
              .buttonStyle(.bordered).frame(maxWidth: .infinity)
          } else {
            if !importOnly {
              if let wearablesVM, wearablesVM.registrationState != .registered {
                Button("Connect glasses in Meta AI") { wearablesVM.connectGlasses() }
                  .buttonStyle(.borderedProminent)
              } else {
                Button {
                  model.voiceGuidance = voiceGuidance
                  model.start()
                  if model.needsKey { settings = true }
                } label: { Label("Start Auto Scan", systemImage: "viewfinder")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                  .buttonStyle(.borderedProminent).tint(.blue)
                  .accessibilityIdentifier("start_auto_scan")
              }
            }
            PhotosPicker(selection: $selection, matching: .images) {
              Label("Import a paper photo", systemImage: "photo")
            }.buttonStyle(.bordered)
            if model.canRetry {
              Button("Retry AI with captured photo") { model.retrySavedPhoto() }
                .buttonStyle(.bordered)
            }
            if model.result != nil {
              Button("Open solution PDF") { model.showPDF = true }.buttonStyle(.borderedProminent)
            }
          }
          if !importOnly {
            Toggle("Spoken positioning cues", isOn: $voiceGuidance)
              .onChange(of: voiceGuidance) { _, value in model.voiceGuidance = value }
            Text("Keep this app open and the phone unlocked. It stays awake during a scan. One photo is solved per start; scanning stops when the PDF opens.")
              .font(.footnote).foregroundStyle(.secondary)
          }
        }.padding(20)
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle(importOnly ? "Solve photo" : "Auto Scan")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button { settings = true } label: { Image(systemName: "gearshape") }.disabled(model.isRunning) }
      .sheet(isPresented: $settings) { SolverSettingsView() }
      .sheet(isPresented: $model.showPDF) {
        if let result = model.result { SolutionViewer(solution: result) }
      }
      .task(id: selection) {
        guard let selection else { return }
        defer { self.selection = nil }
        importError = nil
        do {
          guard let data = try await selection.loadTransferable(type: Data.self) else { throw SolverError.message("Could not import this photo.") }
          try Task.checkCancellation()
          model.voiceGuidance = voiceGuidance
          model.importPhoto(data)
          if model.needsKey { settings = true }
        } catch is CancellationError {} catch { importError = error.localizedDescription }
      }
      .task {
        model.voiceGuidance = voiceGuidance
        if let initialImage, let data = initialImage.jpegData(compressionQuality: 0.95), model.phase == .idle {
          model.importPhoto(data)
          if model.needsKey { settings = true }
        }
      }
      .onChange(of: scenePhase) { _, value in if value == .background { model.backgrounded() } }
      .onDisappear { if model.isRunning { model.stop() } }
    }
  }

  private var phaseIcon: String {
    switch model.phase {
    case .finished: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    case .solving, .saving: return "sparkles"
    default: return "viewfinder"
    }
  }

  private var viewfinder: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black
        if let preview = model.preview, model.phase == .seeking || model.phase == .capturing {
          Image(decorative: preview, scale: 1).resizable().scaledToFit()
          ContentOutline(points: model.sample.corners, imageSize: CGSize(width: preview.width, height: preview.height))
            .stroke(model.sample.acceptable ? Color.mint : Color.orange, lineWidth: 3)
        } else if let image = model.capturedPreview {
          Image(uiImage: image).resizable().scaledToFit()
        } else {
          VStack(spacing: 12) {
            Image(systemName: "doc.viewfinder").font(.system(size: 56, weight: .light))
            Text("Readable writing • Good light • Hold still").font(.caption)
          }.foregroundStyle(.white.opacity(0.75))
        }
        if model.phase == .capturing || model.phase == .checking {
          Color.black.opacity(0.35)
          ProgressView().tint(.white).scaleEffect(1.5)
        }
      }.frame(width: geometry.size.width, height: geometry.size.height)
    }.frame(height: 330).clipShape(RoundedRectangle(cornerRadius: 22))
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
