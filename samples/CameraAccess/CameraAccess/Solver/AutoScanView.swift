import SwiftUI
import PhotosUI
import MWDATCore
import PDFKit

struct AutoScanView: View {
  var wearablesVM: WearablesViewModel? = nil
  var initialImage: UIImage? = nil
  var importOnly = false
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = AutoScanModel.shared
  @State private var settings = false
  @State private var selection: PhotosPickerItem?
  /// Manual import: the question photos picked, in the order picked.
  @State private var selections: [PhotosPickerItem] = []
  /// Picked photos are being read from the library (iCloud originals can take a while): nothing else may start.
  @State private var loadingPhotos = false
  @State private var importError: String?
  @State private var replacingPhoto: Int?
  @State private var confirmNewBatch = false
  @State private var importedInitial = false
  @AppStorage("voiceGuidance") private var voiceGuidance = true
  @AppStorage("voiceCommands") private var voiceCommands = false
  @AppStorage("cueVolume") private var cueVolume = Double(ScanVoice.quietVolume)
  @AppStorage("privateAudio") private var privateAudio = true
  @AppStorage("handGestures") private var handGestures = true
  @AppStorage("glassesButtons") private var glassesButtons = false
  @AppStorage("solveWhileScanning") private var solveWhileScanning = false
  @AppStorage("checkPages") private var checkPages = true
  @AppStorage("captureMode") private var captureMode = AutoScanModel.CaptureMode.buttonPhotos.rawValue
  @AppStorage("solverModeNotice") private var modeNotice = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text("Pick your photos. Get every solution.").font(.title2.bold())
          Text("Choose the clearest photo of each page of questions, in order. Claude and OpenAI both solve every page and Claude reconciles them into one answer. You get a PDF and fx-CG50 pictures of every solution, in one folder ready to copy to the calculator.")
            .foregroundStyle(.secondary)
          Text(buttonPhotos
            ? "Tap Start, then take photos of page 1 with the capture button on your glasses. Each photo is checked as it arrives: you hear \"Page 1 is clear. Take page 2.\", or what to photograph again. Pages are solved as you go; a photo of a thumbs-up finishes, and one folder in Files holds the PDF and every photo."
            : "Tap Start, or run the Start Glasses Scan shortcut, and look closely at each part of a page, top to bottom. Each page is checked before you move on: you hear \"Page 1 is clear\", or what to show again. 👍 solves every page, 👉 keeps a page as it is, 👈 previous page.")
            .foregroundStyle(.secondary)
          if modeNotice && !importOnly {
            HStack(alignment: .top) {
              Text("For speed, 2.0 solves with one provider. Choose Both · cross-check in Settings to compare two providers.")
                .font(.footnote)
              Button("OK") { modeNotice = false }.font(.footnote.bold())
            }.padding(10).background(.yellow.opacity(0.2)).clipShape(RoundedRectangle(cornerRadius: 10))
          }
          ScanViewfinder(model: model)
          HStack(spacing: 10) {
            Image(systemName: phaseIcon).foregroundStyle(model.phase == .failed ? .orange : .mint)
            Text(model.guide).font(.headline)
          }.frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("scan_status")
          if loadingPhotos {
            ProgressView("Loading the photos you picked…").frame(maxWidth: .infinity)
          } else if model.phase == .seeking || model.phase == .capturing || model.phase == .solving || model.phase == .importing {
            ProgressView(value: model.progress).tint(.mint)
          } else if model.isRunning && model.phase != .awaitingNext { ProgressView().frame(maxWidth: .infinity) }
          if let importError { Text(importError).foregroundStyle(.red) }
          if model.photoScan && model.isCollecting && !model.photoStatus.isEmpty {
            Text(model.photoStatus).font(.footnote).foregroundStyle(.secondary)
          }
          if model.needsPhotoAccess && !model.isRunning {
            Button("Open Settings to allow Photos access") {
              if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }.buttonStyle(.bordered)
          }
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
      .task(id: selections) {
        guard !selections.isEmpty else { return }
        let items = selections
        // Clear only this pick: a newer pick made meanwhile must not be wiped (that would cancel it too).
        defer { if selections == items { selections = [] } }
        importError = nil; loadingPhotos = true
        defer { loadingPhotos = false }
        var photos: [Data] = []
        for item in items {
          if let data = try? await item.loadTransferable(type: Data.self) { photos.append(data) }
        }
        guard !Task.isCancelled else { return }
        if photos.count < items.count { importError = "\(items.count - photos.count) photo(s) could not be loaded." }
        applySettings(); model.importPhotos(photos)
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
        model.reloadDraft(); applySettings(); startFromShortcut()
        if !importedInitial, let initialImage, let data = initialImage.jpegData(compressionQuality: 0.95) {
          if model.isRunning {
            importError = "A packet is being scanned or solved. Add this photo when it finishes."
          } else {
            importedInitial = true
            model.importPhoto(data)
          }
        }
      }
      .onChange(of: model.keyPrompts) { _, _ in settings = true }
      .onChange(of: model.shortcutRequests) { _, _ in startFromShortcut() }
      .onChange(of: scenePhase) { _, value in
        if value == .background { model.backgrounded() }
        if value == .active { model.foregrounded(); startFromShortcut() }
      }
      // Switching tabs stops the camera only; page solving and the PDF keep going.
      .onDisappear { model.viewDisappeared() }
    }
  }

  @ViewBuilder private var primaryControls: some View {
    if model.canFinish, !loadingPhotos {
      Button {
        applySettings(); model.finishScanning()
        if model.needsKey { settings = true }
      } label: {
        let count = model.pages.count + (model.hasOpenPhotos ? 1 : 0)
        Label("Solve \(count) page\(count == 1 ? "" : "s")", systemImage: "sparkles")
          .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
      }.buttonStyle(.borderedProminent).accessibilityIdentifier("finish_scanning")
    }
    if model.phase == .awaitingNext {
      Button("Next page now") { model.nextPage() }.buttonStyle(.bordered)
    }
    if model.photoScan && model.phase == .seeking && model.hasOpenPhotos {
      Button("Keep this page as it is") { model.handle(.next) }.buttonStyle(.bordered)
    }
    if model.isRunning {
      if model.phase != .saving {
        Button(model.isCollecting ? "Pause scanning" : "Stop · keep saved pages", role: .destructive) { model.pause() }
          .buttonStyle(.bordered)
      }
    } else {
      // After a PDF, picking photos starts a new packet, so the old packet's pages don't count.
      let startsNew = model.pages.isEmpty || model.packetSolved
      let room = startsNew ? AutoScanModel.maxPages : AutoScanModel.maxPages - model.pages.count
      if room > 0, !loadingPhotos {
        PhotosPicker(selection: $selections, maxSelectionCount: room, selectionBehavior: .ordered, matching: .images) {
          Label(startsNew ? "Choose question photos" : "Add more photos",
                systemImage: "photo.on.rectangle.angled")
            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
        }.buttonStyle(.borderedProminent).accessibilityIdentifier("import_photos")
      }
      if !importOnly && model.pages.count < AutoScanModel.maxPages {
        // Glasses photos come through Meta AI's import, so they need no camera connection to the app.
        if !buttonPhotos, let wearablesVM, wearablesVM.registrationState != .registered {
          Button("Connect glasses in Meta AI") { wearablesVM.connectGlasses() }.buttonStyle(.borderedProminent)
        } else {
          Button {
            applySettings(); model.start()
          } label: {
            Label(model.pages.isEmpty ? "Scan with glasses instead" : (model.packetSolved ? "New packet with glasses" : "Continue with glasses"),
                  systemImage: "eyeglasses")
              .frame(maxWidth: .infinity).padding(.vertical, 6)
          }.buttonStyle(.bordered).accessibilityIdentifier("start_auto_scan")
        }
      }
      if model.result != nil {
        Button("Open solution PDF") { model.showPDF = true }.buttonStyle(.borderedProminent)
      }
    }
  }

  @ViewBuilder private var controlsHelp: some View {
    if buttonPhotos { photoHelp } else { gestureHelp }
  }
  private var photoHelp: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Glasses photos").font(.subheadline.bold())
      Text("Before your first scan: in the Meta AI app, turn on Auto-import for your glasses' media (and Wi-Fi Aware if it is offered), and allow this app Full Access to Photos. Turn off any automatic crop or enhancement of photos.")
      Text("Take one or more photos of each page with the capture button: a whole-page photo, plus close-ups of small print. Each photo reaches the phone through Meta AI, usually within seconds; the screen shows how long the last one took.")
      Text("You hear \"Page 1 is clear. Take page 2.\" once every question can be read, or what to photograph again. A photo of page 2 taken too early waits until page 1 is clear.")
      Text("Hold a fist with the thumb out close to the glasses and take a photo of it: 👍 thumb up solves everything; 👉 to your right keeps the page as it is; 👈 to your left retakes the page before.")
      Text("Each page is solved as soon as the next one is saved, so the PDF is ready moments after you finish. It is saved with every photo in one folder: Files › On My iPhone › Glasses Solver › Solutions.")
      Text("Keep the phone unlocked with this app open while scanning. If no photo arrives, open Meta AI's gallery once to import, then come back.")
    }.font(.footnote).foregroundStyle(.secondary)
  }
  private var gestureHelp: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Hand gestures").font(.subheadline.bold())
      Text("Make a fist with the thumb out and hold it about one second in front of the glasses.")
      Text("👍 Thumb up: start solving (finish).")
      Text("👉 Thumb to your right: next page now, or take the page in view now.")
      Text("👈 Thumb to your left (or 👎): previous page. Retakes the page you just scanned; again to go one more page back. Turn back to that page and it is captured when steady.")
      Text("Live frames (default): look at each part of the page from close up, about a hand's width of text at a time, top to bottom, and hold still for half a second. When you pause, the page is checked by a fast AI model: you hear \"Page 1 is clear. Turn the page.\" or what to show again. 👉 keeps a page as it is.")
      Text("If the AI can't read a page, the glasses ask for it again after you finish. Show it, or give 👍 to solve without it.")
      Text("Start without touching the app: add the Start Glasses Scan shortcut to the Action button (Settings › Action Button › Shortcut) or Back Tap (Settings › Accessibility › Touch › Back Tap), or say \u{201C}Start a scan in Glasses Solver\u{201D} to Siri. The phone must be unlocked.")
      Text("Directions are spoken quietly through the glasses only. Keep the phone unlocked with this app open while scanning; solving continues if you switch tabs.")
    }.font(.footnote).foregroundStyle(.secondary)
  }

  /// The launch shortcut starts scanning once the app is in the foreground; the import sheet never starts the camera.
  private func startFromShortcut() {
    guard !importOnly, scenePhase == .active, model.shortcutPending else { return }
    applySettings(); model.startFromShortcut()
  }
  private func applySettings() {
    model.voiceGuidance = voiceGuidance; model.voiceCommands = voiceCommands
    model.cueVolume = Float(cueVolume); model.privateAudio = privateAudio
    model.gesturesEnabled = handGestures; model.glassesButtons = glassesButtons
    model.solveWhileScanning = solveWhileScanning; model.checkPages = checkPages
    model.captureMode = AutoScanModel.CaptureMode(rawValue: captureMode) ?? .buttonPhotos
  }
  private var buttonPhotos: Bool { captureMode == AutoScanModel.CaptureMode.buttonPhotos.rawValue }
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

extension HandGesture {
  /// Shown on the viewfinder while a command hand is held. The sideways thumbs use pointing symbols.
  var symbol: String {
    switch self {
    case .thumbsUp: return "👍"
    case .thumbsDown: return "👎"
    case .thumbsRight: return "👉"
    case .thumbsLeft: return "👈"
    case .openPalm: return "✋"
    }
  }
}

extension AutoScanModel {
  /// One coordinator owns the draft: the Auto Scan tab and the photo-import sheet share it, so solving that
  /// continues across tabs never races a second model over the same pages.
  static let shared: AutoScanModel = {
    // Before the draft loads: 2.6 starts with an empty packet and empty PDF list, and glasses photos by default.
    SolutionStore.startFresh(); SolverKeychain.migrateDefaults()
    return AutoScanModel(camera: AutoScanCamera(wearables: Wearables.shared))
  }()
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
          if let gesture = model.sample.gesture {
            Text(gesture.symbol).font(.system(size: 54)).shadow(radius: 4)
          }
        } else if let image = model.capturedPreview {
          Image(uiImage: image).resizable().scaledToFit()
        } else {
          VStack(spacing: 12) {
            Image(systemName: model.captureMode == .buttonPhotos ? "camera.fill" : "doc.viewfinder")
              .font(.system(size: 56, weight: .light))
            Text(model.captureMode == .buttonPhotos ? "Capture button • Good light • Whole page, then close-ups"
              : "Close-up writing • Good light • Hold still").font(.caption)
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
  /// The calculator folder, zipped for the share sheet once the viewer opens.
  @State private var calculatorZip: URL?
  var body: some View {
    NavigationStack {
      PDFPreview(url: solution.pdf).ignoresSafeArea(edges: .bottom)
        .navigationTitle(solution.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
          ToolbarItem(placement: .topBarTrailing) { ShareLink(item: solution.pdf) { Image(systemName: "square.and.arrow.up") } }
          if let calculatorZip {
            ToolbarItem(placement: .bottomBar) {
              ShareLink(item: calculatorZip) {
                Label("Calculator pictures (\(solution.calculator?.lastPathComponent ?? "folder"))", systemImage: "square.grid.2x2")
              }
            }
          }
        }
        .task {
          guard let folder = solution.calculator else { return }
          calculatorZip = try? await Task.detached(priority: .userInitiated) { try SolutionStore.zipCalculatorFolder(folder) }.value
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
