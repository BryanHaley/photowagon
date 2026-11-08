import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model: EditorModel
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
    @State private var showCropRotate = false
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
    enum Purpose: Equatable { case open, place, layer, brushTips, actions, folder(String), commandFile(String) }
    enum SaveKind: Identifiable { case saveAs, copy; var id: Self { self } }

    init(model: EditorModel? = nil) {
        _model = StateObject(wrappedValue: model ?? EditorModel())
    }

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
            if DeviceProbe.enabled { DeviceProbe(model: model) }
        }
    }

    private func pickers(_ content: some View) -> some View {
        content
        // The picker closes before it hands over the file: keep what it was for until then.
        .photosPicker(isPresented: Binding(get: { photosFor != nil }, set: { if !$0 { photosPurpose = photosFor; photosFor = nil } }), selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in load(item) }
        .fileImporter(isPresented: Binding(get: { filesFor != nil }, set: { if !$0 { filesPurpose = filesFor ?? filesPurpose; filesFor = nil } }),
                      allowedContentTypes: (filesFor ?? filesPurpose)?.contentTypes ?? [.image, .rawImage, .psd, .pcraft, .data]) { result in
            let purpose = filesFor ?? filesPurpose ?? .open
            (filesFor, filesPurpose) = (nil, nil)
            guard case let .success(url) = result else { return }
            model.picked(url, for: purpose)
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting?.file, contentType: exporting?.type ?? .data, defaultFilename: exporting?.name) { result in
            let job = exporting
            exporting = nil
            model.exported(result, kind: job?.kind)
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
            Button("OK") { model.defineBrush(named: brushName ?? "") }
        } message: {
            Text("The selection becomes a brush tip: black paints, white is clear.")
        }
        .sheet(isPresented: Binding(get: { layerStyle != nil && !wide }, set: { if !$0 { layerStyle = nil } })) {
            if let page = layerStyle, let l = model.activeLayer?.id {
                LayerStyleSheet(model: model, layer: l, start: page)
                    .panelDetents(canvas: true)
            }
        }
        .fullScreenCover(isPresented: $showCropRotate) { CropRotateView(model: model) }
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
                model.picked(url, for: purpose)
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
            Button("Save") { if !model.saveBeforeClose() { saveSheet = .saveAs } }
            Button("Don't Save", role: .destructive) { model.closeWithoutSaving() }
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

    /// Settings that change the image apply as you change them (the last try undone first): a
    /// preview on a phone, the image itself on an iPad.
    static func isLive(_ c: CommandInfo) -> Bool {
        c.menu.hasPrefix("Filter") || c.menu.hasPrefix("Image > Adjustments") || liveCommands.contains(c.id)
    }

    static let liveCommands: Set<String> = [
        "select.colorRange",
        "image.rotation.arbitrary", "image.canvasSize", "image.trim", "image.applyImage",
        "image.mode.bitmap", "image.mode.indexedColor", "image.mode.duotone", "image.mode.colorTable",
        "edit.fill", "edit.stroke", "edit.fade", "edit.contentAwareFill", "edit.assignProfile", "edit.convertToProfile",
        "layer.matting.defringe", "layer.matting.colorDecontaminate", "type.warpText",
    ]

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
                    AdjustmentEditor(model: model, kind: kind, layer: nil, initial: [:], surface: wide ? .canvas : .preview, change: { model.live(c.id, $0) }) {
                        model.settingsDone(c.id, $0, live: true)
                    }
                } else if CommandEditor.handled.contains(c.id) {
                    CommandEditor(model: model, command: c, surface: wide ? .canvas : .preview, change: live ? { model.live(c.id, $0) } : nil) {
                        model.settingsDone(c.id, $0, live: live)
                    }
                } else {
                    CommandSettings(title: c.label.replacingOccurrences(of: "…", with: ""), fields: fields, initial: model.startingValues(fields, for: c.id),
                                    runTitle: "OK", change: live ? { model.live(c.id, $0) } : nil, changeOnAppear: live) {
                        model.settingsDone(c.id, $0, live: live)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        if live { model.liveCancel() }
                        model.commandSettings = nil
                    }
                }
                if live {
                    SeparateBubbles(placement: .topBarLeading)
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
            SystemColorPicker.present(title: "Canvas Color", rgb: CanvasColor.customRGB) { [model] in model.setCustomCanvas($0) }
        case .importBrushTips: browserFor = .brushTips
        case let .panel(p): panel = panel == p ? nil : p
        case .closePanels: panel = nil
        case .cameraRaw: showCameraRaw = true
        case .cropRotate: afterPanel { showCropRotate = true }
        case .newLayer: showNewLayer = true
        case .exportAs: showExport = true
        case .saveForWeb: showSaveForWeb = true
        case .generalPreferences: showGeneralPreferences = true
        case .defineBrush: brushName = "Brush"
        case let .exportToFolder(id): filesFor = .folder(id)
        case let .commandFile(id): filesFor = .commandFile(id)
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

    /// A file dropped on the canvas becomes a layer; dropped anywhere else it opens.
    private func saveToPhotos() {
        guard let data = model.export("png"), let image = UIImage(data: data) else { return }
        PhotoSaver.save(image) { error in
            if let error { model.toast = "Couldn't save to Photos: \(error.localizedDescription)" } else { model.toast = "Saved to Photos" }
        }
    }

    private func share(_ format: String) {
        guard let data = model.export(format) else { return }
        let url: URL
        do { url = try EditorModel.shareFile(data, name: "\(model.fileStem).\(format)") } catch { model.show(error); return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        guard let root = scene?.keyWindow?.rootViewController else { return }
        sheet.popoverPresentationController?.sourceView = root.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 1, height: 1)
        root.present(sheet, animated: true)
    }
}

extension EditorModel {
    /// A file picked in the Files picker or the app's own browser, used for `purpose`.
    func picked(_ url: URL, for purpose: ContentView.Purpose) {
        switch purpose {
        case .open: open(url: url)
        case .place: placeFile(url)
        case .layer: placeFile(url, embedded: false)
        case .brushTips: importBrushTips(url)
        case .actions: loadActions(url)
        case let .folder(id): exportToFolder(id, url)
        case let .commandFile(id): runWithFile(id, url)
        }
    }

    /// The Files picker's access to a folder lasts until the command has written into it.
    func exportToFolder(_ id: String, _ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        runInBackground(id, ["dir": url.path]) { [weak self] out in
            if access { url.stopAccessingSecurityScopedResource() }
            if out != nil { self?.toast = "Saved to \(url.lastPathComponent)" }
        }
    }

    /// A command that reads a file the Files picker chose.
    func runWithFile(_ id: String, _ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        runInBackground(id, ["path": url.path]) { _ in
            if access { url.stopAccessingSecurityScopedResource() }
        }
    }

    func placeFile(_ url: URL, embedded: Bool? = nil) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        place(data: data, name: url.lastPathComponent, embedded: embedded)
    }

    /// The Files exporter finished: after Save As the document is that file.
    func exported(_ result: Result<URL, Error>, kind: ContentView.SaveKind?) {
        switch result {
        case let .success(url):
            if kind == .saveAs { savedAs(url) } else { toast = "Saved \(url.lastPathComponent)" }
        case let .failure(error):
            closeAfterSave = false
            show(error)
        }
    }

    /// Define Brush Preset's OK.
    func defineBrush(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        run("brush.defineFromSelection", ["name": name.isEmpty ? "Brush" : name])
        reloadBrushPresets()
    }

    /// Save before closing; false when it needs Save As first.
    func saveBeforeClose() -> Bool {
        confirmClose = nil
        closeAfterSave = true
        return save()
    }

    func closeWithoutSaving() {
        confirmClose = nil
        closeActive()
    }

    /// A settings screen's OK: a live one keeps its last try, the others run now.
    func settingsDone(_ id: String, _ params: [String: Any], live: Bool) {
        commandSettings = nil
        if live { liveFinish(id, params) } else { runInBackground(id, params) }
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
            field
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("prompt.field")
                .focused($focused)
                .padding()
                .navigationTitle(prompt.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                    // ⌘Return: Return starts a new line in type.
                    ToolbarItem(placement: .confirmationAction) {
                        Button("OK", action: finish).keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("prompt.ok")
                    }
                }
        }
        .onAppear {
            text = prompt.text
            focused = true
        }
    }

    @ViewBuilder private var field: some View {
        if prompt.multiline {
            TextField("Text", text: $text, axis: .vertical).lineLimit(1...8)
        } else {
            TextField("Text", text: $text).submitLabel(.done).onSubmit(finish)
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
    /// Kept until the next picker opens: on a Mac the Colors window it opens keeps sending colours
    /// after the picker itself has closed.
    private static var delegate: Delegate?
    private static var picker: UIColorPickerViewController?

    static func present(title: String, rgb: [Float], tries: Int = 5, changed: @escaping ([Float]) -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first { $0.activationState == .foregroundActive }?.keyWindow ?? scenes.compactMap(\.keyWindow).first
        guard var top = window?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        // One picker at a time (a Pencil double-tapped twice), and not onto a screen that's still
        // coming or going.
        guard !(top is UIColorPickerViewController) else { return }
        // A menu still closing would swallow the picker.
        if top.isBeingPresented || top.isBeingDismissed {
            if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { present(title: title, rgb: rgb, tries: tries - 1, changed: changed) } }
            return
        }
        let c = UIColorPickerViewController()
        c.title = title
        c.supportsAlpha = false
        if rgb.count == 3 { c.selectedColor = UIColor(red: CGFloat(rgb[0]), green: CGFloat(rgb[1]), blue: CGFloat(rgb[2]), alpha: 1) }
        let d = Delegate(changed, from: Self.rgb(c.selectedColor))
        (delegate, picker) = (d, c)
        c.delegate = d
        // Where iPadOS shows it as a popover, it needs something to point at.
        if let pop = c.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        top.present(c, animated: true)
    }

    final class Delegate: NSObject, UIColorPickerViewControllerDelegate {
        let changed: ([Float]) -> Void
        /// The colour last reported, the starting one at first: closing without a pick changes nothing.
        private var last: [Float]?
        init(_ changed: @escaping ([Float]) -> Void, from start: [Float]? = nil) { (self.changed, last) = (changed, start) }

        // A Mac running the iPad app may report a colour only one of these ways.
        func colorPickerViewController(_ c: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) { report(color) }
        func colorPickerViewControllerDidSelectColor(_ c: UIColorPickerViewController) { report(c.selectedColor) }
        func colorPickerViewControllerDidFinish(_ c: UIColorPickerViewController) { report(c.selectedColor) }

        private func report(_ color: UIColor) {
            guard let rgb = SystemColorPicker.rgb(color), rgb != last else { return }
            last = rgb
            changed(rgb)
        }
    }

    /// `color` as sRGB 0…1; colours in another space (a Mac's Colors window) are converted.
    static func rgb(_ color: UIColor) -> [Float]? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = color.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil)?.components, c.count >= 3 else { return nil }
        return c.prefix(3).map { Float(min(max($0, 0), 1)) }
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
        let out = Self.answer(obj["id"] as? String ?? "", obj["params"] as? [String: Any] ?? [:], model: model)
        if let data = try? JSONSerialization.data(withJSONObject: ["seq": seq, "result": out], options: [.fragmentsAllowed]) {
            try? data.write(to: dir.appendingPathComponent("result.json"))
        }
    }

    /// The answer to query `id`.
    static func answer(_ id: String, _ params: [String: Any], model: EditorModel) -> Any {
        var out: Any = ["error": "bad query"]
        if id == "app.docToCanvas", let x = params["x"] as? Double, let y = params["y"] as? Double {
            // Where a document pixel is on the canvas, in points from its top left.
            let p = docToScreen(view: model.view, x: Float(x), y: Float(y))
            let ppp = Double(max(model.view.pixelsPerPoint, 1))
            out = ["x": Double(p.x) / ppp, "y": Double(p.y) / ppp]
        } else if id == "app.documents" {
            // The open documents' names, as their tabs show them (the tab row hides with one).
            out = ["names": model.documents.map(\.name), "active": model.doc.map(\.name) ?? NSNull()]
        } else if id == "app.objectHighlight" {
            // The last Object Finder highlight, in document pixels [x0, y0, x1, y1].
            out = ["shown": model.objectHighlight != nil, "last": model.lastObjectHighlight.map { $0.map(Double.init) as Any } ?? NSNull()]
        } else if id == "app.toasts" {
            out = ["toasts": model.toasts]
        } else if id == "app.state" {
            let mode: String? = model.transform != nil ? "transform" : model.puppet != nil ? "puppet" : model.fluidWarp != nil ? "fluidWarp" : nil
            var state: [String: Any] = ["history": model.history.past.count, "dispatched": model.dispatched, "tool": model.tool.rawValue]
            state["request"] = model.request.map { String(describing: $0) } ?? NSNull()
            state["settings"] = model.commandSettings?.id ?? NSNull()
            state["toast"] = model.toast ?? NSNull()
            state["documents"] = model.documents.count
            state["busy"] = model.busy || model.liveBusy
            state["hint"] = model.hint ?? NSNull()
            state["mode"] = mode ?? NSNull()
            // Changes that aren't history steps: any document change, the view, the canvas, the
            // session's own settings (proofing, guides), a screen over the app.
            state["revision"] = model.doc.map { Int($0.revision) } ?? -1
            state["view"] = "\(model.view.zoom) \(model.view.centerX) \(model.view.centerY) \(model.view.rotation)"
            state["canvas"] = model.canvasColor.rawValue
            state["session"] = (try? model.editor.execute(id: "session.inspect", params: "{}")).map { String($0.hashValue) } ?? ""
            let root = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
            state["presented"] = root?.presentedViewController.map { String(describing: type(of: $0)) } ?? ""
            state["timeline"] = model.showTimeline
            state["snap"] = model.snap
            state["tutorial"] = model.tutorialStep != nil
            out = state
        } else if id == "app.menuTree" {
            out = ["items": Self.menuTree(model)]
        } else if id == "app.tools" {
            out = ["groups": Tool.groups.map { $0.map { ["id": $0.rawValue, "title": $0.title] } }]
        } else if id == "app.coverage" {
            // Omega's Rust coverage: the line counts so far, before the test ends the app.
            out = ["written": coverageWrite(path: params["path"] as? String ?? "")]
        } else if id == "app.reset" {
            // Omega's touch tier: the same document before every item it tries.
            model.cancelPending()
            model.endTutorial()
            model.toast = nil
            _ = try? model.editor.execute(id: "file.closeAll", params: "{}")
            model.newDocument(["width": 400, "height": 300, "name": "Omega"])
            for (id, p) in [("select.rect", ["x": 40, "y": 30, "width": 220, "height": 150]), ("edit.fill", ["color": "#c04020"]),
                            ("select.deselect", [:]), ("layer.new.layer", [:]),
                            ("paint.stroke", ["points": [[20, 260], [380, 40]], "color": "#2060d0", "size": 20])] as [(String, [String: Any])] {
                _ = try? model.editor.execute(id: id, params: json(p))
            }
            model.sync()
            out = ["ok": true]
        } else if Self.allowed.contains(id) {
            let text = (try? JSONSerialization.data(withJSONObject: params)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            do {
                let r = try model.editor.execute(id: id, params: text)
                out = (try? JSONSerialization.jsonObject(with: Data(r.utf8), options: [.fragmentsAllowed])) ?? r
            } catch { out = ["error": error.localizedDescription] }
        }
        return out
    }
}

/// Omega on a real device (`-omegaDeviceProbe YES`): a UI test there can't read the app's files,
/// so the app shows its state as the label of a hidden element, `omega.state`.
struct DeviceProbe: View {
    static let enabled = UserDefaults.standard.bool(forKey: "omegaDeviceProbe")
    @ObservedObject var model: EditorModel
    @State private var label = "{}"
    private static let tick = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("omega.state")
            .accessibilityLabel(label)
            .onReceive(Self.tick) { _ in
                let state: [String: Any] = [
                    "history": model.history.past.count, "toast": model.toast ?? NSNull(), "documents": model.documents.count,
                    "tutorial": model.tutorialStep != nil, "tool": model.tool.rawValue, "busy": model.busy || model.liveBusy, "selection": model.doc?.hasSelection ?? false,
                    "layers": model.layerCount, "width": model.doc?.width ?? 0, "height": model.doc?.height ?? 0,
                ]
                label = (try? JSONSerialization.data(withJSONObject: state)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            }
    }
}

extension TestProbe {
    /// Every item of the ☰ menu as the app builds it: its path, title and whether it's enabled.
    @MainActor
    static func menuTree(_ model: EditorModel) -> [[String: Any]] {
        let menu = MainMenu(model: model)
        var out: [[String: Any]] = []
        func walk(_ elements: [UIMenuElement], _ path: [String]) {
            for e in elements {
                if let m = e as? UIMenu {
                    walk(m.children, m.title.isEmpty ? path : path + [m.title])
                } else if let a = e as? UIAction {
                    out.append(["path": path, "title": a.title, "enabled": !a.attributes.contains(.disabled)])
                } else {
                    out.append(["path": path, "title": "", "enabled": false, "deferred": true])
                }
            }
        }
        walk(menu.quickActions(), ["Quick Actions"])
        for name in MenuTree.order { walk(menu.items(name), [name]) }
        return out
    }
}

extension ContentView.Purpose {
    var isFolder: Bool { if case .folder = self { true } else { false } }

    var contentTypes: [UTType] {
        switch self {
        case .folder: [.folder]
        case .commandFile: [.item]
        default: [.image, .rawImage, .psd, .pcraft, .data]
        }
    }

    var title: String {
        switch self {
        case .open: "Open"
        case .place: "Place Embedded"
        case .layer: "New Layer from File"
        case .brushTips: "Import Brush Tips"
        case .actions: "Load Actions"
        case .folder: "Choose a Folder"
        case .commandFile: "Choose a File"
        }
    }

    var kinds: Set<String> {
        switch self {
        case .open, .place, .layer: AppFolder.openable
        case .brushTips: AppFolder.brushes
        case .actions: ["atn"]
        case .folder, .commandFile: []
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
