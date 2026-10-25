import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = EditorModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var photosPurpose: Purpose?
    @State private var filesPurpose: Purpose?
    @State private var photo: PhotosPickerItem?
    @State private var photosFor: Purpose?
    @State private var filesFor: Purpose?
    @State private var browserFor: Purpose?
    @State private var panel: EditorModel.Panel?
    @State private var showSearch = false
    @State private var showCameraRaw = false
    /// Layer Style's first page; beside the canvas, so its shadow can be dragged there.
    @State private var layerStyle: String?
    @State private var showNewLayer = false
    @State private var showExport = false
    @State private var showSaveForWeb = false
    @State private var showGeneralPreferences = false
    @State private var showNew = false
    @State private var brushName: String?
    @State private var saveSheet: SaveKind?
    @State private var exporting: ExportJob?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// What a picked file is for.
    enum Purpose { case open, place, layer, brushTips, actions }
    enum SaveKind: Identifiable { case saveAs, copy; var id: Self { self } }

    var body: some View {
        sheets(pickers(ZStack {
            HStack(spacing: 0) {
                workspace
                if wide, editing {
                    // Room for the panel, given up while it steps aside.
                    Color.clear.frame(width: model.canvasPick == nil ? 381 : 0)
                }
            }
            .overlay(alignment: .trailing) {
                if wide, editing {
                    // Picking on the canvas: the panel slides off (kept, so nothing set is lost).
                    HStack(spacing: 0) {
                        Divider()
                        editingPanel
                            .environment(\.closePanel, closeEditing)
                            .frame(width: 380)
                    }
                    .offset(x: model.canvasPick == nil ? 0 : 381)
                    .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.2), value: wide && editing)
            .animation(.easeOut(duration: 0.2), value: model.canvasPick)
            if let pick = model.canvasPick {
                CanvasPickBar(prompt: pick.prompt) { model.canvasPick = nil }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 64)
            }
            if let at = model.pencilPalette {
                GeometryReader { g in
                    Color.black.opacity(0.001).onTapGesture { model.pencilPalette = nil }
                    // Beside the Pencil, kept on screen.
                    PencilPalette(model: model, at: at)
                        .position(x: min(max(at.x + 150, 145), g.size.width - 145), y: min(max(at.y, 130), g.size.height - 130))
                }
            }
            if let layer = model.maskView, model.canvasPick == nil {
                MaskViewBar { model.toggleMaskView(layer) }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 64)
            }
            if model.showHome {
                HomeView(model: model).transition(.opacity)
            }
            // Over Home too, so a failed New or Open says why.
            ToastView(model: model).padding(.top, 50)
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        // A field's value is selected when you tap it, so typing replaces it (as in Photoshop's dialogs).
        // iOS may end the app once it's in the background: keep a recovery copy first.
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.saveRecovery(wait: true) } }
        .onChange(of: model.doc?.id) { _, _ in if !model.showHome { model.startTutorialIfNew() } }
        .onChange(of: model.showHome) { _, home in if !home { model.startTutorialIfNew() } }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { note in
            guard let field = note.object as? UITextField else { return }
            DispatchQueue.main.async { field.selectAll(nil) }
        }))
        .overlay(alignment: .bottomLeading) {
            if TestProbe.enabled { TestProbe(model: model).ignoresSafeArea() }
        }
    }

    private func pickers(_ content: some View) -> some View {
        content
        // The picker closes before it hands over the file: keep what it was for until then.
        .photosPicker(isPresented: Binding(get: { photosFor != nil }, set: { if !$0 { photosPurpose = photosFor; photosFor = nil } }), selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in load(item) }
        .fileImporter(isPresented: Binding(get: { filesFor != nil }, set: { if !$0 { filesPurpose = filesFor ?? filesPurpose; filesFor = nil } }),
                      allowedContentTypes: [.image, .rawImage, .psd, .pcraft, .data]) { result in
            let purpose = filesFor ?? filesPurpose ?? .open
            (filesFor, filesPurpose) = (nil, nil)
            guard case let .success(url) = result else { return }
            switch purpose {
            case .open: model.open(url: url)
            case .place: place(url: url)
            case .layer: place(url: url, embedded: false)
            case .brushTips: model.importBrushTips(url)
            case .actions: model.loadActions(url)
            }
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting?.file, contentType: exporting?.type ?? .data, defaultFilename: exporting?.name) { result in
            let job = exporting
            exporting = nil
            switch result {
            case let .success(url):
                if job?.kind == .saveAs { model.savedAs(url) } else { model.toast = "Saved \(url.lastPathComponent)" }
            case let .failure(error):
                model.closeAfterSave = false
                model.show(error)
            }
        }
        .onChange(of: model.request) { _, r in
            if let r { handle(r) }
            model.request = nil
        }
        .onDrop(of: [.image, .data], isTargeted: nil) { providers in model.drop(providers, place: false) }
    }

    private func sheets(_ content: some View) -> some View {
        content
        .sheet(item: Binding(get: { wide && panel == .properties ? nil : panel }, set: { panel = $0 })) { p in
            switch p {
            case .layers: LayersPanel(model: model).panelDetents()
            case .history: HistoryPanel(model: model).panelDetents()
            case .properties: PropertiesPanel(model: model).panelDetents(canvas: true)
            case .adjustments: AdjustPanel(model: model).presentationDetents([.height(390)]).presentationBackgroundInteraction(.enabled)
            case .actions: ActionsPanel(model: model) {
                panel = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { browserFor = .actions }
            }.panelDetents()
            }
        }
        .sheet(isPresented: $showSearch) { CommandSearch(model: model) }
        .sheet(isPresented: $showNewLayer) { NewLayerSheet(model: model) }
        .alert(model.rasterizePromptText?.title ?? "",
               isPresented: Binding(get: { model.rasterizePrompt != nil }, set: { if !$0 { model.rasterizePrompt = nil } })) {
            Button("Cancel", role: .cancel) { model.rasterizePromptAnswered(rasterize: false) }
            Button("Rasterize") { model.rasterizePromptAnswered(rasterize: true) }
                .accessibilityIdentifier("rasterize.ok")
        } message: {
            Text(model.rasterizePromptText?.message ?? "")
        }
        .alert("Download AI Remove?", isPresented: Binding(get: { model.aiRemoveWaiting != nil }, set: { if !$0 { model.aiRemoveWaiting = nil } })) {
            Button("Not Now", role: .cancel) {}
            Button("Download") { model.downloadAIModel() }
                .accessibilityIdentifier("aiRemove.download")
        } message: {
            Text("AI Remove fills with MI-GAN, a model that runs on this device. It's a one-time download of \(ByteCountFormatter.string(fromByteCount: ModelDownload.downloadBytes, countStyle: .file)) from Hugging Face (MIT licence). Your photos never leave the device.")
        }
        .sheet(isPresented: $showExport) { ExportSheet(model: model) }
        .sheet(isPresented: $model.showManual) { ManualView() }
        .sheet(isPresented: $model.showAcknowledgements) {
            NavigationStack {
                AcknowledgementsView().toolbar { ToolbarItem(placement: .cancellationAction) { DoneButton() } }
            }
        }
        .sheet(isPresented: $showSaveForWeb) { SaveForWebSheet(model: model) }
        .sheet(isPresented: $showGeneralPreferences) { GeneralPreferencesSheet(model: model) }
        .sheet(isPresented: $model.showBrushSettings) { BrushSettingsSheet(model: model) }
        .alert("Brush Name", isPresented: Binding(get: { brushName != nil }, set: { if !$0 { brushName = nil } })) {
            TextField("Name", text: Binding(get: { brushName ?? "" }, set: { brushName = $0 }))
            Button("Cancel", role: .cancel) {}
            Button("OK") {
                let name = (brushName ?? "").trimmingCharacters(in: .whitespaces)
                model.run("brush.defineFromSelection", ["name": name.isEmpty ? "Brush" : name])
                model.reloadBrushPresets()
            }
        } message: {
            Text("The selection becomes a brush tip: black paints, white is clear.")
        }
        .sheet(isPresented: Binding(get: { layerStyle != nil && !wide }, set: { if !$0 { layerStyle = nil } })) {
            if let page = layerStyle, let l = model.activeLayer?.id {
                LayerStyleSheet(model: model, layer: l, start: page)
                    .panelDetents(canvas: true)
            }
        }
        .sheet(isPresented: $showCameraRaw) {
            CameraRawView(model: model, change: { model.live("filter.cameraRaw", $0) }, cancel: { model.liveCancel() }) { p in
                model.liveFinish("filter.cameraRaw", p)
            }
            .interactiveDismissDisabled()
        }
        .sheet(item: Binding(get: { model.developOpen }, set: { _ in })) { o in
            CameraRawView(model: model, initial: o.initial, opening: true, change: { model.live("filter.cameraRaw", $0) }) { _ in }
                .interactiveDismissDisabled()
        }
        .sheet(item: $model.developEdit) { e in
            let at: [String: Any] = ["layer": e.layer, "index": e.index]
            CameraRawView(model: model, initial: e.initial, change: { model.live("layer.smartFilter.setParams", at.merging(["params": $0]) { a, _ in a }) },
                          cancel: { model.liveCancel() }) { p in
                model.liveFinish("layer.smartFilter.setParams", at.merging(["params": p]) { a, _ in a })
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showNew) { NewDocumentSheet(model: model) }
        .sheet(isPresented: Binding(get: { browserFor != nil }, set: { if !$0 { browserFor = nil } })) {
            let purpose = browserFor ?? .open
            let many: (([URL]) -> Void)? = purpose == .place || purpose == .layer
                ? { urls in model.placeAll(urls, embedded: purpose == .layer ? false : nil) } : nil
            FileBrowser(title: purpose.title, kinds: purpose.kinds, showPhotos: purpose == .open || purpose == .place || purpose == .layer, pick: { url in
                switch purpose {
                case .open: model.open(url: url)
                case .place: place(url: url)
                case .layer: place(url: url, embedded: false)
                case .brushTips: model.importBrushTips(url)
                case .actions: model.loadActions(url)
                }
            }, browse: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { filesFor = purpose }
            }, photos: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { photosFor = purpose }
            }, pickMany: many)
        }
        .sheet(item: $saveSheet) { kind in
            SaveSheet(model: model, copy: kind == .copy) { data, name, type in
                // The exporter can't open while this sheet is still closing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    exporting = ExportJob(file: DataFile(data: data), type: type, name: name, kind: kind)
                }
            }
        }
        .sheet(item: Binding(get: { wide ? nil : model.commandSettings }, set: { model.commandSettings = $0 })) { c in
            settings(c)
        }
        .sheet(item: $model.prompt) { prompt in
            PromptSheet(prompt: prompt) { model.prompt = nil }
                .presentationDetents([.height(170)])
        }
        .confirmationDialog("Save changes to “\(model.confirmClose?.name ?? "")” before closing?",
                            isPresented: Binding(get: { model.confirmClose != nil }, set: { if !$0 { model.confirmClose = nil } }),
                            titleVisibility: .visible) {
            Button("Save") {
                model.confirmClose = nil
                model.closeAfterSave = true
                if !model.save() { saveSheet = .saveAs }
            }
            Button("Don't Save", role: .destructive) {
                model.confirmClose = nil
                model.closeActive()
            }
            Button("Cancel", role: .cancel) { model.confirmClose = nil }
        }
    }

    private var workspace: some View {
        GeometryReader { g in
            // Landscape: tools down the left and the options bar on top, as in Photoshop. On a
            // phone the document tabs share the top bar, to leave the canvas room.
            let landscape = g.size.width > g.size.height
            let short = verticalSizeClass == .compact
            VStack(spacing: 0) {
                topBar(tabs: short)
                // One document needs no tab row: the image gets the room.
                if !short, model.documents.count > 1 { DocumentTabs(model: model) }
                if landscape {
                    ContextBar(model: model).tutorialTarget(.contextBar)
                    HStack(spacing: 0) {
                        ToolBar(model: model, vertical: true).frame(width: 52)
                        canvasArea
                    }
                    if model.showTimeline { TimelinePanel(model: model) }
                } else {
                    canvasArea
                    if model.showTimeline { TimelinePanel(model: model) }
                    ContextBar(model: model).tutorialTarget(.contextBar)
                    ToolBar(model: model)
                }
            }
        }
        .background(Color(white: 0.07))
        .overlayPreferenceValue(TutorialAnchors.self) { anchors in
            if model.tutorialStep != nil, !model.showHome { TutorialOverlay(model: model, anchors: anchors) }
        }
    }

    private var canvasArea: some View {
        ZStack(alignment: .bottomLeading) {
            CanvasView(model: model)
                .ignoresSafeArea(edges: .horizontal)
                .onDrop(of: [.image], isTargeted: nil) { providers in model.drop(providers, place: true) }
            if model.showSizePreview {
                Circle()
                    .stroke(.white, lineWidth: 1.5)
                    .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 0.5).padding(1.5))
                    .frame(width: sizePreviewDiameter, height: sizePreviewDiameter)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.busy {
                ProgressView().controlSize(.large).tint(.white)
                    .padding(18).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.doc != nil {
                StatusBar(model: model).padding(8)
            }
            if model.liveBusy {
                // A settings change being applied; small, so the image stays in view.
                ProgressView().tint(.white).padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
            }
        }
    }

    private var sizePreviewDiameter: CGFloat {
        CGFloat(model.brushSize) * CGFloat(model.view.zoom) / CGFloat(max(model.view.pixelsPerPoint, 1))
    }

    /// An iPad: settings that change the image open in a column beside the canvas, so you see the
    /// change on the full image. A phone shows them in a sheet with a preview.
    private var wide: Bool { horizontalSizeClass == .regular }

    private var editing: Bool { model.commandSettings != nil || layerStyle != nil || panel == .properties }

    @ViewBuilder
    private var editingPanel: some View {
        if let c = model.commandSettings {
            settings(c)
        } else if let page = layerStyle, let l = model.activeLayer?.id {
            LayerStyleSheet(model: model, layer: l, start: page).id(page)
        } else if panel == .properties {
            PropertiesPanel(model: model)
        }
    }

    private func closeEditing() {
        if let c = model.commandSettings, Self.isLive(c) { model.liveCancel() }
        model.commandSettings = nil
        layerStyle = nil
        if panel == .properties { panel = nil }
    }

    /// Filters and adjustments apply as you change their settings (the last try undone first).
    static func isLive(_ c: CommandInfo) -> Bool {
        c.menu.hasPrefix("Filter") || c.menu.hasPrefix("Image > Adjustments") || c.id == "select.colorRange"
    }

    private func settings(_ c: CommandInfo) -> some View {
        let live = Self.isLive(c)
        return NavigationStack {
            VStack(spacing: 0) {
                if live, !wide, !CommandEditor.ownPreview.contains(c.id) { PreviewPane(model: model) }
                if c.id == "select.refineEdge" {
                    Button { model.refineHair() } label: { Label("Refine Hair", systemImage: "wand.and.rays") }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                        .accessibilityIdentifier("refine.hair")
                }
                let fields = model.editor.commandFields(id: c.id)
                if let kind = AdjustmentEditor.kind(for: c.id) {
                    AdjustmentEditor(model: model, kind: kind, layer: nil, initial: [:], surface: wide ? .canvas : .preview, change: { model.live(c.id, $0) }) { params in
                        model.commandSettings = nil
                        model.liveFinish(c.id, params)
                    }
                } else if CommandEditor.handled.contains(c.id) {
                    CommandEditor(model: model, command: c, surface: wide ? .canvas : .preview, change: live ? { model.live(c.id, $0) } : nil) { params in
                        model.commandSettings = nil
                        if live { model.liveFinish(c.id, params) } else { model.runInBackground(c.id, params) }
                    }
                } else {
                    CommandSettings(title: c.label.replacingOccurrences(of: "…", with: ""), fields: fields, initial: model.startingValues(fields),
                                    runTitle: "OK", change: live ? { model.live(c.id, $0) } : nil, changeOnAppear: live) { params in
                        model.commandSettings = nil
                        if live { model.liveFinish(c.id, params) } else { model.runInBackground(c.id, params) }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if live { model.liveCancel() }
                        model.commandSettings = nil
                    }
                }
                if live {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { model.setLivePreview(!model.livePreview) } label: {
                            Image(systemName: model.livePreview ? "eye" : "eye.slash")
                        }
                        .accessibilityLabel("Preview")
                        .accessibilityValue(model.livePreview ? "on" : "off")
                        .accessibilityIdentifier("settings.preview")
                    }
                }
            }
        }
        // A swipe down would skip Cancel and leave the last try applied.
        .interactiveDismissDisabled(live)
        .onAppear { if live { model.liveBegin() } }
        .onDisappear { if live { model.liveKeep() } }
    }

    private func topBar(tabs: Bool) -> some View {
        HStack(spacing: 4) {
            BarButton("house", "Home") { withAnimation { model.showHome = true } }
                .accessibilityIdentifier("home")
                .tutorialTarget(.home)
            MainMenu(model: model)
                .tutorialTarget(.menu)
            HStack(spacing: 4) {
                BarButton("arrow.uturn.backward", "Undo", enabled: model.doc?.canUndo == true) { model.run("edit.undo") }
                    .accessibilityIdentifier("undo")
                BarButton("arrow.uturn.forward", "Redo", enabled: model.doc?.canRedo == true) { model.run("edit.redo") }
                    .accessibilityIdentifier("redo")
            }
            .tutorialTarget(.undo)
            if tabs, model.documents.count > 1 { DocumentTabs(model: model) } else { Spacer() }
            BarButton("magnifyingglass", "Search Commands") { showSearch = true }
                .tutorialTarget(.search)
            BarButton("clock.arrow.circlepath", "History") { panel = .history }
                .accessibilityIdentifier("history")
                .tutorialTarget(.history)
            Menu {
                Button { model.straighten() } label: { Label("Reset Tilt", systemImage: "rotate.left") }
                Button { model.resetPosition() } label: { Label("Reset Position", systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
                Button { model.resetZoom() } label: { Label("Reset Zoom", systemImage: "plus.magnifyingglass") }
                Button { model.fit() } label: { Label("Fit to Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
            } label: { BarIcon("arrow.up.left.and.arrow.down.right") }
                .disabled(model.doc == nil)
                .accessibilityLabel("View")
                .accessibilityIdentifier("view.fit")
                .tutorialTarget(.view)
            BarButton("square.3.layers.3d", "Layers") { panel = .layers }
                .accessibilityIdentifier("layers")
                .tutorialTarget(.layers)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func handle(_ r: EditorModel.Request) {
        switch r {
        case .openFiles: browserFor = .open
        case .openPhotos: photosFor = .open
        case .placeFiles: browserFor = .place
        case .placePhotos: photosFor = .place
        // From the Layers sheet: close it first, a picker can't open over it.
        case .layerFromFiles: afterPanel { browserFor = .layer }
        case .layerFromPhotos: afterPanel { photosFor = .layer }
        case .search: showSearch = true
        case .newDocument: showNew = true
        case .save: if !model.save() { saveSheet = .saveAs }
        case .saveAs: saveSheet = .saveAs
        case .saveCopy: saveSheet = .copy
        case .close: if let i = model.documents.firstIndex(where: { $0.id == model.doc?.id }) { model.requestClose(i) }
        case let .share(format): share(format)
        case .saveToPhotos: saveToPhotos()
        case .print: model.run("file.print", ["scaleToFit": true])
        case .canvasColor:
            SystemColorPicker.present(title: "Canvas Colour", rgb: CanvasColor.customRGB) { [model] in model.setCustomCanvas($0) }
        case .importBrushTips: browserFor = .brushTips
        case let .panel(p): panel = panel == p ? nil : p
        case .closePanels: panel = nil
        case .cameraRaw: showCameraRaw = true
        case .newLayer: showNewLayer = true
        case .exportAs: showExport = true
        case .saveForWeb: showSaveForWeb = true
        case .generalPreferences: showGeneralPreferences = true
        case .defineBrush: brushName = "Brush"
        case let .layerStyle(page):
            // It opens beside the canvas, not over the Layers sheet.
            if panel != nil {
                panel = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { layerStyle = page }
            } else {
                layerStyle = page
            }
        }
    }

    private func afterPanel(_ show: @escaping () -> Void) {
        if panel != nil {
            panel = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: show)
        } else {
            show()
        }
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        let purpose = photosFor ?? photosPurpose ?? .open
        (photosFor, photosPurpose) = (nil, nil)
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {
                switch purpose {
                case .open: model.open(data: data, name: "Photo.\(ext)")
                case .layer: model.place(data: data, name: "Photo.\(ext)", embedded: false)
                default: model.place(data: data, name: "Photo.\(ext)")
                }
            }
            photo = nil
        }
    }

    private func place(url: URL, embedded: Bool? = nil) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        model.place(data: data, name: url.lastPathComponent, embedded: embedded)
    }

    /// A file dropped on the canvas becomes a layer; dropped anywhere else it opens.
    private func saveToPhotos() {
        guard let data = model.export("png"), let image = UIImage(data: data) else { return }
        PhotoSaver.save(image) { error in
            if let error { model.toast = "Couldn't save to Photos: \(error.localizedDescription)" } else { model.toast = "Saved to Photos" }
        }
    }

    private func share(_ format: String) {
        guard let data = model.export(format) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(model.fileStem).\(format)")
        do { try data.write(to: url) } catch { model.show(error); return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        guard let root = scene?.keyWindow?.rootViewController else { return }
        sheet.popoverPresentationController?.sourceView = root.view
        root.present(sheet, animated: true)
    }
}

struct ExportJob {
    let file: DataFile
    let type: UTType
    let name: String
    let kind: ContentView.SaveKind
}

extension UTType {
    static let psd = UTType(filenameExtension: "psd", conformingTo: .image) ?? .data
    static let pcraft = UTType(filenameExtension: "pcraft", conformingTo: .data) ?? .data
}

/// Saves to Photos and reports how it went (it asks for permission the first time).
final class PhotoSaver: NSObject {
    private let done: (Error?) -> Void
    private static var pending: [PhotoSaver] = []

    private init(_ done: @escaping (Error?) -> Void) { self.done = done }

    static func save(_ image: UIImage, done: @escaping (Error?) -> Void) {
        let saver = PhotoSaver(done)
        pending.append(saver)
        UIImageWriteToSavedPhotosAlbum(image, saver, #selector(finished(_:error:context:)), nil)
    }

    @objc private func finished(_ image: UIImage, error: Error?, context: UnsafeMutableRawPointer?) {
        done(error)
        PhotoSaver.pending.removeAll { $0 === self }
    }
}

struct PromptSheet: View {
    let prompt: TextPrompt
    let close: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextField("Text", text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("prompt.field")
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(finish)
                .padding()
                .navigationTitle(prompt.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                    ToolbarItem(placement: .confirmationAction) { Button("OK", action: finish).accessibilityIdentifier("prompt.ok") }
                }
        }
        .onAppear {
            text = prompt.text
            focused = true
        }
    }

    private func finish() {
        let t = text
        close()
        prompt.done(t)
    }
}

struct DataFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// MARK: - Small pieces

struct BarIcon: View {
    let symbol: String
    init(_ symbol: String) { self.symbol = symbol }
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .frame(width: 42, height: 38)
            .contentShape(Rectangle())
    }
}

struct BarButton: View {
    let symbol: String
    let title: String
    var enabled = true
    let action: () -> Void
    init(_ symbol: String, _ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        (self.symbol, self.title, self.enabled, self.action) = (symbol, title, enabled, action)
    }
    var body: some View {
        Button(action: action) { BarIcon(symbol) }.disabled(!enabled).accessibilityLabel(title)
    }
}

struct ToastView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var lama = ModelDownload.shared
    var body: some View {
        VStack {
            if case .downloading(let f) = lama.state {
                HStack(spacing: 10) {
                    ProgressView(value: f).frame(width: 80)
                    Text("Downloading AI Remove… \(Int(f * 100))%").font(.footnote)
                    Button("Cancel") { lama.cancel() }.font(.footnote)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 10)
            }
            if let text = model.toast {
                Text(text)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { model.toast = nil }
                    }
            }
            if model.toast == nil, let hint = model.hint { HintBubble(model: model, text: hint) }
            Spacer()
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .animation(.easeOut(duration: 0.15), value: model.hint)
        .allowsHitTesting(false)
    }
}

/// A name shown for a moment: the tool just picked, or a button held down.
struct HintBubble: View {
    @ObservedObject var model: EditorModel
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 10)
            .transition(.opacity)
            .task(id: text) {
                try? await Task.sleep(for: .seconds(1.2))
                if model.hint == text { withAnimation { model.hint = nil } }
            }
            .accessibilityIdentifier("hint")
    }
}

/// The system colour picker over the app, reporting each change.
@MainActor
enum SystemColorPicker {
    private static var delegate: Delegate?

    static func present(title: String, rgb: [Float], changed: @escaping ([Float]) -> Void) {
        let root = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
        guard var top = root else { return }
        while let next = top.presentedViewController { top = next }
        let c = UIColorPickerViewController()
        c.title = title
        c.supportsAlpha = false
        if rgb.count == 3 { c.selectedColor = UIColor(red: CGFloat(rgb[0]), green: CGFloat(rgb[1]), blue: CGFloat(rgb[2]), alpha: 1) }
        let d = Delegate(changed)
        delegate = d
        c.delegate = d
        top.present(c, animated: true)
    }

    final class Delegate: NSObject, UIColorPickerViewControllerDelegate {
        let changed: ([Float]) -> Void
        init(_ changed: @escaping ([Float]) -> Void) { self.changed = changed }

        func colorPickerViewController(_ c: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
            var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
            guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            changed([r, g, b].map { Float(min(max($0, 0), 1)) })
        }

        func colorPickerViewControllerDidFinish(_ c: UIColorPickerViewController) { SystemColorPicker.delegate = nil }
    }
}

/// UI tests only (`-uiTestProbe <folder>`): the test writes `{"seq": n, "id": "document.stats",
/// "params": {…}}` to `query.json` in that folder; the app answers in `result.json` with the same
/// `seq`. Read-only commands only, plus `app.docToCanvas` {x, y}, `app.documents`, `app.objectHighlight`
/// and `app.toasts`.
struct TestProbe: View {
    static let folder = UserDefaults.standard.string(forKey: "uiTestProbe").map { URL(fileURLWithPath: $0) }
    static var enabled: Bool { folder != nil }
    private static let allowed: Set<String> = ["session.inspect", "document.inspect", "document.pixel", "document.stats", "type.info", "brush.get", "brush.presets.list", "actions.list", "actions.get", "shape.info", "gradient.fill.get", "layer.layerStyle.get", "animation.info"]
    @ObservedObject var model: EditorModel
    @State private var answered = -1
    /// Shared: one made per view would start again each time the screen redraws (playing
    /// redraws it more often than it ticks).
    private static let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        Color.clear.frame(width: 1, height: 1).onReceive(Self.tick) { _ in poll() }
    }

    private func poll() {
        guard let dir = Self.folder, let data = try? Data(contentsOf: dir.appendingPathComponent("query.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let seq = obj["seq"] as? Int, seq != answered else { return }
        answered = seq
        var out: Any = ["error": "bad query"]
        let params = obj["params"] as? [String: Any] ?? [:]
        if obj["id"] as? String == "app.docToCanvas", let x = params["x"] as? Double, let y = params["y"] as? Double {
            // Where a document pixel is on the canvas, in points from its top left.
            let p = docToScreen(view: model.view, x: Float(x), y: Float(y))
            let ppp = Double(max(model.view.pixelsPerPoint, 1))
            out = ["x": Double(p.x) / ppp, "y": Double(p.y) / ppp]
        } else if obj["id"] as? String == "app.documents" {
            // The open documents' names, as their tabs show them (the tab row hides with one).
            out = ["names": model.documents.map(\.name), "active": model.doc.map(\.name) ?? NSNull()]
        } else if obj["id"] as? String == "app.objectHighlight" {
            // The last Object Finder highlight, in document pixels [x0, y0, x1, y1].
            out = ["shown": model.objectHighlight != nil, "last": model.lastObjectHighlight.map { $0.map(Double.init) as Any } ?? NSNull()]
        } else if obj["id"] as? String == "app.toasts" {
            out = ["toasts": model.toasts]
        } else if let id = obj["id"] as? String, Self.allowed.contains(id) {
            let params = (obj["params"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            do {
                let r = try model.editor.execute(id: id, params: params)
                out = (try? JSONSerialization.jsonObject(with: Data(r.utf8), options: [.fragmentsAllowed])) ?? r
            } catch { out = ["error": error.localizedDescription] }
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["seq": seq, "result": out], options: [.fragmentsAllowed]) {
            try? data.write(to: dir.appendingPathComponent("result.json"))
        }
    }
}

extension ContentView.Purpose {
    var title: String {
        switch self {
        case .open: "Open"
        case .place: "Place Embedded"
        case .layer: "New Layer from File"
        case .brushTips: "Import Brush Tips"
        case .actions: "Load Actions"
        }
    }

    var kinds: Set<String> {
        switch self {
        case .open, .place, .layer: AppFolder.openable
        case .brushTips: AppFolder.brushes
        case .actions: ["atn"]
        }
    }
}

/// Over the canvas while an eyedropper picks there: what to tap, and Cancel to go back.
struct CanvasPickBar: View {
    let prompt: String
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eyedropper")
            Text(prompt).font(.callout)
            Button("Cancel", action: cancel)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("pick.cancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pick.bar")
    }
}
