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
  @AppStorage("voiceCommands") private var voiceCommands = false
  @AppStorage("cueVolume") private var cueVolume = Double(ScanVoice.quietVolume)
  @AppStorage("privateAudio") private var privateAudio = true
  @AppStorage("handGestures") private var handGestures = true
  @AppStorage("glassesButtons") private var glassesButtons = true
  @AppStorage("solveWhileScanning") private var solveWhileScanning = true

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text("One button. Every page. One PDF.").font(.title2.bold())
          Text("Tap Start and look at each page; it captures automatically. Give a 👍 thumbs-up (or double-tap the glasses) to solve. Pages are solved while you scan.")
            .foregroundStyle(.secondary)
          ScanViewfinder(model: model)
          HStack(spacing: 10) {
            Image(systemName: phaseIcon).foregroundStyle(model.phase == .failed ? .orange : .mint)
            Text(model.guide).font(.headline)
          }.frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("scan_status")
          if model.phase == .seeking || model.phase == .capturing || model.phase == .solving {
            ProgressView(value: model.progress).tint(.mint)
          } else if model.isRunning && model.phase != .awaitingNext { ProgressView().frame(maxWidth: .infinity) }
          if let importError { Text(importError).foregroundStyle(.red) }
          if !model.voiceStatus.isEmpty && model.isCollecting {
            Text(model.voiceStatus).font(.footnote).foregroundStyle(.secondary)
          }
          if !model.solveStatus.isEmpty && model.isCollecting {
            Text(model.solveStatus).font(.footnote).foregroundStyle(.secondary)
          }
          primaryControls
          if !model.pages.isEmpty {
            PageQueueView(pages: model.pages, thumbnails: model.thumbnails, states: model.pageStates,
              editable: !model.isRunning, importOnly: importOnly, selection: $selection,
              retake: { index in applySettings(); model.start(replacing: index) },
              replace: { index in replacingPhoto = index },
              remove: { index in model.removePage(at: index) })
          }
          if !model.isRunning && !model.pages.isEmpty {
            Button("New packet", role: .destructive) { confirmNewBatch = true }.buttonStyle(.bordered)
          }
          controlsHelp
        }.padding(20)
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle(importOnly ? "Add paper photos" : "Auto Scan")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button { settings = true } label: { Image(systemName: "gearshape") }.disabled(model.isRunning) }
      .sheet(isPresented: $settings, onDismiss: { applySettings() }) { SolverSettingsView() }
      .sheet(isPresented: $model.showPDF) { if let result = model.result { SolutionViewer(solution: result) } }
      .confirmationDialog("Clear the saved pages and start a new packet? Existing PDFs are kept.", isPresented: $confirmNewBatch, titleVisibility: .visible) {
        Button("Start new packet", role: .destructive) { model.newBatch() }
      }
      .task(id: selection) {
        guard let selection else { return }
        defer { self.selection = nil; replacingPhoto = nil }
        importError = nil
        do {
          guard let data = try await selection.loadTransferable(type: Data.self) else { throw SolverError.message("Could not import this photo.") }
          try Task.checkCancellation(); applySettings()
          model.importPhoto(data, replacing: replacingPhoto)
        } catch is CancellationError {} catch { importError = error.localizedDescription }
      }
      .task {
        model.reloadDraft(); applySettings()
        if !importedInitial, let initialImage, let data = initialImage.jpegData(compressionQuality: 0.95), model.phase == .idle {
          importedInitial = true
          model.importPhoto(data)
        }
      }
      .onChange(of: model.needsKey) { _, needed in if needed { settings = true } }
      .onChange(of: scenePhase) { _, value in if value == .background { model.backgrounded() } }
      // Switching tabs stops the camera only; page solving and the PDF keep going.
      .onDisappear { model.viewDisappeared() }
    }
  }

  @ViewBuilder private var primaryControls: some View {
    if model.canFinish {
      Button {
        applySettings(); model.finishScanning()
        if model.needsKey { settings = true }
      } label: {
        Label("Done · Solve \(model.pages.count) page\(model.pages.count == 1 ? "" : "s")", systemImage: "hand.thumbsup.fill")
          .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
      }.buttonStyle(.borderedProminent).accessibilityIdentifier("finish_scanning")
    }
    if model.phase == .awaitingNext {
      Button("Next page now") { model.nextPage() }.buttonStyle(.bordered)
    }
    if model.isRunning {
      Button(model.isCollecting ? "Pause scanning" : "Stop · keep saved pages", role: .destructive) { model.stop() }
        .buttonStyle(.bordered)
    } else {
      if !importOnly && model.pages.count < AutoScanModel.maxPages {
        if let wearablesVM, wearablesVM.registrationState != .registered {
          Button("Connect glasses in Meta AI") { wearablesVM.connectGlasses() }.buttonStyle(.borderedProminent)
        } else {
          Button {
            applySettings(); model.start()
          } label: {
            Label(model.pages.isEmpty ? "Start scanning" : "Continue scanning", systemImage: "viewfinder")
              .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
          }.buttonStyle(.borderedProminent).accessibilityIdentifier("start_auto_scan")
        }
      }
      if model.pages.count < AutoScanModel.maxPages {
        PhotosPicker(selection: $selection, matching: .images) { Label("Add a paper photo", systemImage: "photo") }
          .simultaneousGesture(TapGesture().onEnded { replacingPhoto = nil }).buttonStyle(.bordered)
      }
      if model.result != nil {
        Button("Open solution PDF") { model.showPDF = true }.buttonStyle(.borderedProminent)
      }
    }
  }

  private var controlsHelp: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Silent controls").font(.subheadline.bold())
      Text("👍 Thumbs-up, held about one second in front of the glasses: finish and solve.")
      Text("👎 Thumbs-down: retake the last page.")
      Text("Glasses: double-tap the touchpad or double-press the capture button to finish. Press the capture button for the next page now; hold it to retake. A single tap pauses or resumes the glasses.")
      Text("Directions are spoken quietly through the glasses only. Keep this app open and the phone unlocked while scanning; solving continues if you switch tabs.")
    }.font(.footnote).foregroundStyle(.secondary)
  }

  private func applySettings() {
    model.voiceGuidance = voiceGuidance; model.voiceCommands = voiceCommands
    model.cueVolume = Float(cueVolume); model.privateAudio = privateAudio
    model.gesturesEnabled = handGestures; model.glassesButtons = glassesButtons
    model.solveWhileScanning = solveWhileScanning
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
}

/// Reads the per-frame preview in its own view so the page queue does not re-render on every frame.
private struct ScanViewfinder: View {
  let model: AutoScanModel
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black
        if let preview = model.preview, [.seeking, .awaitingNext, .capturing].contains(model.phase) {
          Image(decorative: preview, scale: 1).resizable().scaledToFit()
          ContentOutline(points: model.sample.corners, imageSize: CGSize(width: preview.width, height: preview.height))
            .stroke(model.sample.acceptable && model.sample.closeEnough ? Color.mint : Color.orange, lineWidth: 3)
          if model.sample.gesture != nil {
            Image(systemName: "hand.raised.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.85))
          }
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

private struct PageQueueView: View {
  let pages: [CapturedPage]
  let thumbnails: [UUID: UIImage]
  let states: [UUID: AutoScanModel.PageState]
  let editable: Bool
  let importOnly: Bool
  @Binding var selection: PhotosPickerItem?
  let retake: (Int) -> Void
  let replace: (Int) -> Void
  let remove: (Int) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Saved pages · \(pages.count)/\(AutoScanModel.maxPages)").font(.headline)
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 12) {
          ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
            VStack(spacing: 6) {
              ZStack(alignment: .topTrailing) {
                Group {
                  if let image = thumbnails[page.id] { Image(uiImage: image).resizable().scaledToFit() }
                  else { Color.black }
                }.frame(width: 110, height: 125).background(.black).clipShape(RoundedRectangle(cornerRadius: 10))
                badge(states[page.id]).padding(5)
              }
              Text("Page \(index + 1)").font(.caption.bold())
              if case .failed(let message)? = states[page.id] {
                Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(3)
              }
              if editable {
                if !importOnly { Button("Retake") { retake(index) }.font(.caption) }
                PhotosPicker(selection: $selection, matching: .images) { Text("Replace photo").font(.caption) }
                  .simultaneousGesture(TapGesture().onEnded { replace(index) })
                Button("Remove", role: .destructive) { remove(index) }.font(.caption)
              }
            }.frame(width: 110)
          }
        }
      }
    }
  }
  @ViewBuilder private func badge(_ state: AutoScanModel.PageState?) -> some View {
    switch state {
    case .solved?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).background(Circle().fill(.white))
    case .solving?: ProgressView().tint(.white).padding(4).background(Circle().fill(.black.opacity(0.6)))
    case .failed?: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    case .queued?: Image(systemName: "clock.fill").foregroundStyle(.white.opacity(0.8))
    default: EmptyView()
    }
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
