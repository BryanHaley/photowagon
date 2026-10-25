import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Recent files

/// A file opened or saved recently (a bookmark, so it reopens after a restart).
struct RecentFile: Codable, Identifiable, Equatable {
    let name: String
    let bookmark: Data
    let date: Date
    var id: String { name + bookmark.base64EncodedString().prefix(32) }

    static func load(_ defaults: UserDefaults = .standard) -> [RecentFile] {
        guard let data = defaults.data(forKey: "recentFiles") else { return [] }
        return (try? JSONDecoder().decode([RecentFile].self, from: data)) ?? []
    }

    static func save(_ list: [RecentFile], _ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(list), forKey: "recentFiles")
    }
}

extension RecentFile {
    var url: URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
    }
}

/// A file's picture for a file list: the thumbnail a .pcraft file stores, else Quick Look's.
struct FileThumbnail: View {
    let url: URL?
    @State private var image: UIImage?
    private static let side: CGFloat = 44
    @MainActor private static var cache: [String: UIImage] = [:]

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "doc").foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement()
        .accessibilityIdentifier("thumb.\(url?.deletingPathExtension().lastPathComponent ?? "")")
        .accessibilityValue(image == nil ? "none" : "image")
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        let key = url.path + "\(AppFolder.date(url)?.timeIntervalSince1970 ?? 0)"
        if let hit = Self.cache[key] { image = hit; return }
        let scale = UIScreen.main.scale
        let found = await Self.make(url, scale: scale)
        if let found {
            Self.cache[key] = found
            image = found
        }
    }

    /// The file's thumbnail: `.pcraft` files carry their own, the rest come from Quick Look.
    nonisolated static func make(_ url: URL, scale: CGFloat) async -> UIImage? {
        await Task.detached(priority: .utility) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if url.pathExtension.lowercased() == "pcraft" {
                // The file is read whole to find its thumbnail: skip very large ones.
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size < 300_000_000, let data = try? Data(contentsOf: url, options: .alwaysMapped),
                      let png = pcraftThumbnail(bytes: data) else { return nil }
                return UIImage(data: png)
            }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: Self.side, height: Self.side), scale: scale, representationTypes: .thumbnail)
            return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }.value
    }
}

// MARK: - Home

/// What the app shows with no document in front: start something new, or pick up recent work.
struct HomeView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Image("Logo").resizable().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("PhotoWagon").font(.largeTitle.bold()).lineLimit(1).minimumScaleFactor(0.5)
                    Spacer()
                    Button { model.request = .generalPreferences } label: { Image(systemName: "gearshape").font(.title2) }
                        .accessibilityLabel("Preferences")
                        .accessibilityIdentifier("home.preferences")
                }
                if model.doc != nil {
                    Button { model.showHome = false } label: {
                        Label("Back to Workspace", systemImage: "rectangle.and.pencil.and.ellipsis")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .accessibilityIdentifier("home.workspace")
                }
                HStack(spacing: 12) {
                    HomeAction(title: "New file", symbol: "plus.square") { model.request = .newDocument }
                        .accessibilityIdentifier("home.new")
                    HomeAction(title: "Open", symbol: "folder") { model.request = .openFiles }
                        .accessibilityIdentifier("home.open")
                    HomeAction(title: "Photos", symbol: "photo.on.rectangle") { model.request = .openPhotos }
                        .accessibilityIdentifier("home.photos")
                }
                if !model.documents.isEmpty {
                    Text("Open").font(.headline)
                    ForEach(Array(model.documents.enumerated()), id: \.element.id) { i, d in
                        Button { model.activate(i) } label: {
                            Label("\(d.name)  ·  \(d.width) × \(d.height)", systemImage: "doc.richtext")
                        }
                    }
                }
                if !model.recovered.isEmpty {
                    Text("Recovered").font(.headline)
                    Text("Unsaved work from when PhotoWagon last closed. Tap one to open it.").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.recovered) { r in
                        HStack {
                            Button { model.openRecovered(r) } label: {
                                HStack {
                                    Image(systemName: "arrow.uturn.backward.circle.fill").font(.title3)
                                    VStack(alignment: .leading) {
                                        Text(r.name)
                                        Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("Open").font(.subheadline.weight(.semibold))
                                }
                                .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("recovered.\(r.name)")
                            Spacer()
                            Button("Discard", role: .destructive) { model.discardRecovered(r) }
                                .accessibilityIdentifier("recovered.discard.\(r.name)")
                        }
                    }
                }
                Text("Recent").font(.headline)
                if model.recents.isEmpty {
                    Text("Files you open or save show up here.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.recents) { r in
                        Button { model.openRecent(r) } label: {
                            HStack {
                                FileThumbnail(url: r.url)
                                VStack(alignment: .leading) {
                                    Text(r.name)
                                    Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("recent.\(r.name)")
                    }
                }
            }
            .padding(20)
        }
        .foregroundStyle(.white)
        .background(Color(white: 0.07))
    }
}

private struct HomeAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.subheadline)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Tabs

/// The open documents, like tabs: tap to switch, ✕ to close.
struct DocumentTabs: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollViewReader { reader in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(model.documents.enumerated()), id: \.element.id) { i, d in
                    let active = d.id == model.doc?.id
                    HStack(spacing: 6) {
                        Text(d.name + (model.isDirty(d) ? " •" : ""))
                            .font(.caption)
                            .lineLimit(1)
                        Button { model.requestClose(i) } label: { Image(systemName: "xmark").font(.caption2.bold()) }
                            .accessibilityLabel("Close \(d.name)")
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(active ? Color(white: 0.24) : Color(white: 0.13), in: RoundedRectangle(cornerRadius: 7))
                    .onTapGesture { model.activate(i) }
                    .accessibilityIdentifier("tab.\(d.name)")
                    .id(d.id)
                }
            }
            .padding(.horizontal, 10)
        }
        // The document in front keeps its tab in view.
        .onChange(of: model.documents.map { "\($0.id) \($0.name)" } + [model.doc.map { "\($0.id)" } ?? ""]) { _, _ in
            if let id = model.doc?.id { withAnimation { reader.scrollTo(id, anchor: .center) } }
        }
        }
        .frame(height: 32)
    }
}

// MARK: - Status bar

/// Zoom and one fact about the document, like Photoshop's status bar; tap to pick the fact.
struct StatusBar: View {
    @ObservedObject var model: EditorModel
    @AppStorage("statusInfo") private var info = Info.dimensions

    enum Info: String, CaseIterable {
        case dimensions = "Document Dimensions"
        case layers = "Layer Count"
        case tool = "Current Tool"
    }

    var body: some View {
        Menu {
            Picker("Show", selection: $info) {
                ForEach(Info.allCases, id: \.self) { Text($0.rawValue) }
            }
        } label: {
            Text("\(model.zoomPercent)%   \(text)" + (model.recordingAction.map { "   ● Recording \($0)" } ?? ""))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.45), in: Capsule())
        }
        .accessibilityIdentifier("statusBar")
    }

    private var text: String {
        guard let d = model.doc else { return "" }
        switch info {
        case .dimensions: return "\(d.width) × \(d.height) px"
        case .layers: return model.layerCount == 1 ? "1 layer" : "\(model.layerCount) layers"
        case .tool: return model.tool.title
        }
    }
}

// MARK: - New document

struct DocPreset: Identifiable, Hashable {
    let name: String
    let width: Int
    let height: Int
    let resolution: Int
    var id: String { name }
}

/// File › New: pick a preset or set the size, resolution, mode and background yourself.
struct NewDocumentSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Untitled"
    @State private var width = "1920"
    @State private var height = "1080"
    @State private var unit = Unit.pixels
    @State private var resolution = "72"
    @State private var mode = "rgb"
    @State private var depth = 8
    @State private var background = "white"
    @State private var profile = "srgb"
    @State private var preset = ""

    /// Colour profiles for each mode, as the engine names them.
    static let profiles: [String: [(String, String)]] = [
        "rgb": [("srgb", "sRGB IEC61966-2.1"), ("display-p3", "Display P3"), ("adobe-rgb-compat", "Adobe RGB (1998) compatible"),
                ("prophoto-compat", "ProPhoto RGB compatible"), ("rec2020", "Rec. 2020"), ("linear-srgb", "Linear sRGB"), ("none", "Don't Color Manage")],
        "gray": [("gray-gamma-2.2", "Gray Gamma 2.2"), ("sgray", "sGray"), ("dot-gain-20-compat", "Dot Gain 20% compatible"), ("none", "Don't Color Manage")],
        "cmyk": [("coated-cmyk", "Coated CMYK"), ("none", "Don't Color Manage")],
        "lab": [("lab-d50", "Lab D50")],
    ]

    enum Unit: String, CaseIterable {
        case pixels = "Pixels", inches = "Inches", centimeters = "Centimeters"
        var perInch: Double { switch self { case .pixels: 0; case .inches: 1; case .centimeters: 2.54 } }
    }

    static let presets: [(String, [DocPreset])] = [
        ("Photo", [DocPreset(name: "Landscape 6 × 4 in", width: 1800, height: 1200, resolution: 300),
                   DocPreset(name: "Portrait 4 × 6 in", width: 1200, height: 1800, resolution: 300),
                   DocPreset(name: "Landscape 7 × 5 in", width: 2100, height: 1500, resolution: 300)]),
        ("Print", [DocPreset(name: "Letter", width: 2550, height: 3300, resolution: 300),
                   DocPreset(name: "A4", width: 2480, height: 3508, resolution: 300)]),
        ("Art & Illustration", [DocPreset(name: "Default", width: 4000, height: 3000, resolution: 300),
                                DocPreset(name: "Square", width: 3000, height: 3000, resolution: 300)]),
        ("Web", [DocPreset(name: "Web Large", width: 1920, height: 1080, resolution: 72),
                 DocPreset(name: "Web Medium", width: 1440, height: 900, resolution: 72),
                 DocPreset(name: "Social Square", width: 1080, height: 1080, resolution: 72)]),
        ("Mobile", [DocPreset(name: "iPhone 16 Pro", width: 1206, height: 2622, resolution: 72),
                    DocPreset(name: "iPad Pro 11 in", width: 1668, height: 2420, resolution: 72)]),
        ("Film & Video", [DocPreset(name: "HDTV 1080p", width: 1920, height: 1080, resolution: 72),
                          DocPreset(name: "UHD 4K", width: 3840, height: 2160, resolution: 72)]),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Preset", selection: Binding(get: { preset }, set: { name in
                        preset = name
                        if let p = Self.presets.flatMap(\.1).first(where: { $0.name == name }) { apply(p) }
                    })) {
                        Text("Custom").tag("")
                        ForEach(Self.presets, id: \.0) { group in
                            Section(group.0) {
                                ForEach(group.1) { p in Text(verbatim: "\(p.name) — \(p.width) × \(p.height) px").tag(p.name) }
                            }
                        }
                    }
                    .accessibilityIdentifier("new.preset")
                }
                Section("Details") {
                    TextField("Name", text: $name).accessibilityIdentifier("new.name")
                    Picker("Units", selection: $unit) { ForEach(Unit.allCases, id: \.self) { Text($0.rawValue) } }
                        .accessibilityIdentifier("new.units")
                    number("Width", $width, id: "new.width")
                    number("Height", $height, id: "new.height")
                    number("Resolution (pixels/inch)", $resolution, id: "new.resolution")
                }
                Section("Color") {
                    Picker("Color Mode", selection: $mode) {
                        Text("RGB Color").tag("rgb"); Text("Grayscale").tag("gray"); Text("CMYK Color").tag("cmyk"); Text("Lab Color").tag("lab")
                    }
                    .onChange(of: mode) { _, m in profile = Self.profiles[m]?.first?.0 ?? "none" }
                    Picker("Color Profile", selection: $profile) {
                        ForEach(Self.profiles[mode] ?? [], id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .accessibilityIdentifier("new.profile")
                    Picker("Bit Depth", selection: $depth) { Text("8 bit").tag(8); Text("16 bit").tag(16); Text("32 bit").tag(32) }
                    Picker("Background", selection: $background) {
                        Text("White").tag("white"); Text("Black").tag("black"); Text("Background Color").tag("backgroundColor"); Text("Transparent").tag("transparent")
                    }
                }
                Section {
                    Text("\(px(width)) × \(px(height)) px").foregroundStyle(.secondary)
                    if let problem { Text(problem).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("New Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create).disabled(problem != nil).accessibilityIdentifier("new.create")
                }
            }
        }
    }

    /// A number typed as text and read on Create, so nothing is lost when Create is tapped while
    /// the field is still being edited.
    private func number(_ title: String, _ value: Binding<String>, id: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: value)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
                .accessibilityIdentifier(id)
        }
    }

    /// A typed number ("1,920" too); 0 when it isn't one.
    static func value(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) ?? 0 }

    /// A typed size in pixels, from `unit` at `resolution` pixels per inch.
    static func pixels(_ s: String, unit: Unit, resolution: String) -> Int {
        let v = value(s)
        return unit == .pixels ? Int(v.rounded()) : Int((v / unit.perInch * value(resolution)).rounded())
    }

    private func px(_ s: String) -> Int { Self.pixels(s, unit: unit, resolution: resolution) }

    private func apply(_ p: DocPreset) {
        (name, unit, width, height, resolution) = (p.name, .pixels, "\(p.width)", "\(p.height)", "\(p.resolution)")
    }

    private var problem: String? { Self.problem(width: px(width), height: px(height)) }

    /// Why a `width × height` pixel document can't be made, if it can't.
    static func problem(width w: Int, height h: Int) -> String? {
        if w < 1 || h < 1 { return "Width and height must be at least 1 pixel." }
        if w > 300_000 || h > 300_000 { return "Width and height can be at most 300,000 pixels." }
        return nil
    }

    private func create() {
        let (w, h) = (px(width), px(height))
        guard problem == nil else { return }
        model.newDocument(["width": w, "height": h, "resolution": max(Self.value(resolution), 1), "mode": mode, "depth": depth, "background": background, "profile": profile, "name": name])
        dismiss()
    }
}

// MARK: - Files

/// The app's own folder: On My iPhone › PhotoWagon in Files.
enum AppFolder {
    static var url: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static let openable: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "jxl", "tif", "tiff", "psd", "psb", "pcraft", "webp", "gif", "bmp",
                                        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "exr", "svg", "ora"]

    /// Brush files Import Brush Tips reads (plus images, as sampled tips).
    static let brushes: Set<String> = ["abr", "gbr", "gih", "vbr", "bundle", "kpp", "png", "jpg", "jpeg", "tif", "tiff", "psd", "svg"]

    static func files(_ kinds: Set<String> = openable) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let list = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
        return list.filter { kinds.contains($0.pathExtension.lowercased()) }
            .sorted { (date($0) ?? .distantPast) > (date($1) ?? .distantPast) }
    }

    static func date(_ u: URL) -> Date? { try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
}

/// Open, Place or Import Brush Tips: the files in the app's folder, or Files (and Photos) for
/// anything else.
struct FileBrowser: View {
    let title: String
    var kinds = AppFolder.openable
    var showPhotos = true
    let pick: (URL) -> Void
    let browse: () -> Void
    let photos: () -> Void
    /// Several files at once (Place, a layer from each); `nil` picks one.
    var pickMany: (([URL]) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var choosing = false
    @State private var chosen: [URL] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { dismiss(); browse() } label: { Label("Browse Files…", systemImage: "folder") }
                        .accessibilityIdentifier("browser.files")
                    if showPhotos { Button { dismiss(); photos() } label: { Label("Photos…", systemImage: "photo.on.rectangle") } }
                }
                Section("On My iPhone › PhotoWagon") {
                    if files.isEmpty { Text("No files yet").foregroundStyle(.secondary) }
                    ForEach(files, id: \.self) { u in
                        Button {
                            if choosing {
                                if let i = chosen.firstIndex(of: u) { chosen.remove(at: i) } else { chosen.append(u) }
                            } else {
                                dismiss()
                                pick(u)
                            }
                        } label: {
                            HStack {
                                if choosing {
                                    Image(systemName: chosen.contains(u) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(chosen.contains(u) ? Color.accentColor : .secondary)
                                }
                                FileThumbnail(url: u)
                                Text(u.lastPathComponent)
                                Spacer()
                                if let d = AppFolder.date(u) { Text(d.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                            }
                            .accessibilityElement(children: .contain)
                        }
                        .accessibilityIdentifier("file.\(u.deletingPathExtension().lastPathComponent)")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if let pickMany {
                    ToolbarItem(placement: .confirmationAction) {
                        if choosing {
                            Button("Place \(chosen.count)") {
                                dismiss()
                                // In name order, as a sequence of frames is numbered.
                                pickMany(chosen.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
                            }
                            .disabled(chosen.isEmpty)
                            .accessibilityIdentifier("browser.placeChosen")
                        } else {
                            Button("Select") { choosing = true }.accessibilityIdentifier("browser.select")
                        }
                    }
                }
            }
            .onAppear { files = AppFolder.files(kinds) }
        }
    }
}

// MARK: - Save As / Save a Copy

struct SaveFormat: Hashable {
    let title: String
    let ext: String
    var type: UTType { UTType(filenameExtension: ext) ?? .data }

    static let layered = [SaveFormat(title: "PhotoCraft (default)", ext: "pcraft"), SaveFormat(title: "Photoshop® (PSD)", ext: "psd"), SaveFormat(title: "TIFF", ext: "tiff")]
    static let all = layered + [SaveFormat(title: "JPEG", ext: "jpg"), SaveFormat(title: "PNG", ext: "png"),
                                SaveFormat(title: "WebP", ext: "webp"), SaveFormat(title: "JPEG XL", ext: "jxl"), SaveFormat(title: "GIF", ext: "gif"),
                                SaveFormat(title: "BMP", ext: "bmp")]

    /// Save As offers only formats that keep layers once there is more than one, as Photoshop does.
    static func offered(copy: Bool, layerCount: Int) -> [SaveFormat] { copy || layerCount <= 1 ? all : layered }
}

/// Save As (formats that keep layers; the document then lives in the new file) or Save a Copy
/// (any format; the document keeps its own file).
struct SaveSheet: View {
    @ObservedObject var model: EditorModel
    let copy: Bool
    /// Save somewhere else through the system sheet.
    let elsewhere: (Data, String, UTType) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var format = SaveFormat.layered[0]

    private var formats: [SaveFormat] { SaveFormat.offered(copy: copy, layerCount: model.layerCount) }
    @State private var quality = 10.0
    @State private var inAppFolder = true
    @State private var jxlLossless = true
    @State private var jxlQuality = 90.0
    @State private var jxlEffort = 7.0

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).accessibilityIdentifier("save.name")
                Picker("Format", selection: $format) {
                    ForEach(formats, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("save.format")
                if format.ext == "jpg" {
                    VStack(alignment: .leading) {
                        HStack { Text("Quality"); Spacer(); Text("\(Int(quality))").monospacedDigit() }
                        Slider(value: $quality, in: 0...12, step: 1).accessibilityIdentifier("save.quality")
                    }
                }
                if format.ext == "jxl" {
                    JXLOptions(lossless: $jxlLossless, quality: $jxlQuality, effort: $jxlEffort, id: "save")
                }
                Picker("Where", selection: $inAppFolder) {
                    Text("On My iPhone › PhotoWagon").tag(true)
                    Text("Other Location…").tag(false)
                }
                .accessibilityIdentifier("save.where")
                if !copy {
                    Text("Only formats that keep layers are listed. Use Save a Copy for JPEG or PNG.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if format.ext == "psd" {
                    Text("Adobe and Photoshop are either registered trademarks or trademarks of Adobe in the United States and/or other countries. PhotoWagon isn't affiliated with Adobe.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(copy ? "Save a Copy" : "Save As")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let data = format.ext == "jxl"
                            ? model.exportJXL(lossless: jxlLossless, quality: Int(jxlQuality), effort: Int(jxlEffort))
                            : model.export(format.ext, quality: format.ext == "jpg" ? UInt8(quality) : nil)
                        guard let data else { return }
                        let file = "\(name.isEmpty ? model.fileStem : name).\(format.ext)"
                        dismiss()
                        if inAppFolder {
                            let url = AppFolder.url.appendingPathComponent(file)
                            do {
                                try data.write(to: url)
                                if copy { model.toast = "Saved \(file)" } else { model.savedAs(url) }
                            } catch {
                                model.show(error)
                            }
                        } else {
                            elsewhere(data, file, format.type)
                        }
                    }
                    .accessibilityIdentifier("save.save")
                }
            }
            .onAppear {
                name = model.fileStem + (copy ? " copy" : "")
                if copy { format = SaveFormat.all[0] }
            }
        }
    }
}

/// JPEG XL's settings: lossless (every pixel kept), or a quality; and the effort (time spent
/// making the file smaller).
struct JXLOptions: View {
    @Binding var lossless: Bool
    @Binding var quality: Double
    @Binding var effort: Double
    let id: String

    var body: some View {
        Toggle("Lossless", isOn: $lossless).accessibilityIdentifier("\(id).jxlLossless")
        if !lossless {
            VStack(alignment: .leading) {
                HStack { Text("Quality"); Spacer(); Text("\(Int(quality))").monospacedDigit() }
                Slider(value: $quality, in: 1...100, step: 1).accessibilityIdentifier("\(id).jxlQuality")
            }
        }
        VStack(alignment: .leading) {
            HStack { Text("Effort"); Spacer(); Text("\(Int(effort))").monospacedDigit() }
            Slider(value: $effort, in: 1...10, step: 1).accessibilityIdentifier("\(id).jxlEffort")
            Text("Higher takes longer and makes a smaller file.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// File › Export › Export As…: flat copies in the app's folder, in a web format at one or more
/// sizes, optionally converted to sRGB (the engine's Export As settings, which Quick Export then
/// uses too).
struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var format = "png"
    @State private var quality = 80.0
    @State private var jxlLossless = false
    @State private var srgb = true
    @State private var transparency = true
    @State private var width = 0
    @State private var scales: Set<Double> = [1]

    static let scaleChoices: [Double] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3]

    private var height: Int {
        guard let d = model.doc, d.width > 0 else { return 0 }
        return Int((Double(width) * Double(d.height) / Double(d.width)).rounded())
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).accessibilityIdentifier("export.name")
                Picker("Format", selection: $format) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpg")
                    Text("WebP").tag("webp")
                    Text("JPEG XL").tag("jxl")
                    Text("GIF").tag("gif")
                }
                .accessibilityIdentifier("export.format")
                if format == "jxl" {
                    Toggle("Lossless", isOn: $jxlLossless).accessibilityIdentifier("export.jxlLossless")
                }
                if format == "jpg" || format == "webp" || (format == "jxl" && !jxlLossless) {
                    VStack(alignment: .leading) {
                        HStack { Text("Quality"); Spacer(); Text("\(Int(quality))").monospacedDigit() }
                        Slider(value: $quality, in: 1...100, step: 1)
                    }
                }
                if format == "jpg" {
                    Text("JPEG has no transparency: transparent areas come out white.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Toggle("Transparency", isOn: $transparency).accessibilityIdentifier("export.transparency")
                }
                Section("Image Size") {
                    HStack {
                        Text("Width")
                        Spacer()
                        TextField("", value: $width, format: .number)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
                            .accessibilityIdentifier("export.width")
                        Text("px").foregroundStyle(.secondary)
                    }
                    HStack { Text("Height"); Spacer(); Text("\(height) px").foregroundStyle(.secondary).accessibilityIdentifier("export.height") }
                }
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Self.scaleChoices, id: \.self) { s in
                                Toggle(String(format: "%gx", s), isOn: Binding(get: { scales.contains(s) }, set: { on in
                                    if on { scales.insert(s) } else if scales.count > 1 { scales.remove(s) }
                                }))
                                .toggleStyle(.button)
                                .accessibilityIdentifier("export.scale.\(String(format: "%g", s))")
                            }
                        }
                    }
                } header: {
                    Text("Sizes")
                } footer: {
                    Text("Each size is its own file: name.png, name@2x.png…")
                }
                Toggle("Convert to sRGB", isOn: $srgb).accessibilityIdentifier("export.srgb")
            }
            .navigationTitle("Export As")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        dismiss()
                        var prefs: [String: Any] = ["quickExportFormat": format, "convertToSrgb": srgb]
                        if format == "jpg" { prefs["jpegQuality"] = Int(quality) }
                        if format == "webp" { prefs["webpQuality"] = Int(quality) }
                        if format == "jxl" { (prefs["jxlLossless"], prefs["jxlQuality"]) = (jxlLossless, Int(quality)) }
                        model.exportAs(name: name, prefs: prefs, width: max(width, 1), scales: Array(scales), transparency: transparency || format == "jpg")
                    }
                    .accessibilityIdentifier("export.export")
                }
            }
            .onAppear {
                name = model.fileStem
                width = Int(model.doc?.width ?? 1)
            }
        }
    }
}

/// File › Export › Save for Web: a web image (GIF, PNG-8, PNG-24 or JPEG) with its colours,
/// dither, transparency and size, and a frame animation's looping, saved in the app's folder. The
/// size it comes to shows as the settings change.
struct SaveForWebSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var format = "gif"
    @State private var colors = 256
    @State private var palette = "selective"
    @State private var dither = "diffusion"
    @State private var transparency = true
    @State private var quality = 60.0
    @State private var percent = 100.0
    @State private var loops = 0
    @State private var estimate: String?

    static let formats = [("gif", "GIF"), ("png8", "PNG-8"), ("png24", "PNG-24"), ("jpeg", "JPEG")]
    private var indexed: Bool { format == "gif" || format == "png8" }
    private var animated: Bool { format == "gif" && (model.animation?.count ?? 0) > 1 }
    private var ext: String { ["png8": "png", "png24": "png", "jpeg": "jpg"][format] ?? format }

    /// The engine's params for these settings.
    static func params(format: String, colors: Int, palette: String, dither: String, transparency: Bool, quality: Int, percent: Double, loops: Int?) -> [String: Any] {
        var p: [String: Any] = ["format": format, "transparency": transparency, "percent": percent]
        if format == "gif" || format == "png8" { p.merge(["colors": colors, "palette": palette, "dither": dither]) { _, b in b } }
        if format == "jpeg" { p["quality"] = quality }
        if let loops { p["loops"] = loops == 0 ? "forever" as Any : loops == 1 ? "once" as Any : loops }
        return p
    }

    private var params: [String: Any] {
        Self.params(format: format, colors: colors, palette: palette, dither: dither, transparency: transparency, quality: Int(quality), percent: percent, loops: animated ? loops : nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PreviewPane(model: model)
                Form {
                    Section {
                        TextField("Name", text: $name).accessibilityIdentifier("web.name")
                        Picker("Format", selection: $format) {
                            ForEach(Self.formats, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("web.format")
                    } footer: {
                        Text(estimate ?? " ").accessibilityIdentifier("web.estimate")
                    }
                    if indexed {
                        Section("Colors") {
                            Picker("Color Reduction", selection: $palette) {
                                ForEach(["perceptual", "selective", "adaptive", "restrictive"], id: \.self) { Text($0.capitalized).tag($0) }
                            }
                            Picker("Colors", selection: $colors) {
                                ForEach([2, 4, 8, 16, 32, 64, 128, 256], id: \.self) { Text("\($0)").tag($0) }
                            }
                            .accessibilityIdentifier("web.colors")
                            Picker("Dither", selection: $dither) {
                                ForEach(["diffusion", "pattern", "noise", "none"], id: \.self) { Text($0 == "none" ? "No Dither" : $0.capitalized).tag($0) }
                            }
                        }
                    }
                    if format == "jpeg" {
                        StyleSlider(title: "Quality", value: quality, range: 0...100, unit: "", id: "web.quality") { quality = $0 }
                    }
                    if format != "jpeg" {
                        Toggle("Transparency", isOn: $transparency).accessibilityIdentifier("web.transparency")
                    }
                    Section("Image Size") {
                        StyleSlider(title: "Percent", value: percent, range: 1...100, unit: "%", id: "web.percent") { percent = $0 }
                        if let d = model.doc {
                            Text("\(Int((Double(d.width) * percent / 100).rounded())) × \(Int((Double(d.height) * percent / 100).rounded())) px")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if animated {
                        Section("Animation") {
                            Picker("Looping", selection: $loops) {
                                Text("Once").tag(1)
                                Text("3 Times").tag(3)
                                Text("Forever").tag(0)
                            }
                            .accessibilityIdentifier("web.loops")
                            Text("\(model.animation?.count ?? 0) frames").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Save for Web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let file = "\(name.isEmpty ? model.fileStem : name).\(ext)"
                        var p = params
                        p["path"] = AppFolder.url.appendingPathComponent(file).path
                        dismiss()
                        model.runInBackground("file.export.saveForWebLegacy", p) { [weak model] out in
                            if out != nil { model?.toast = "Saved \(file)" }
                        }
                    }
                    .accessibilityIdentifier("web.save")
                }
            }
            .onAppear {
                name = model.fileStem
                loops = model.animation?.loops ?? 0
                if (model.animation?.count ?? 0) <= 1 { format = "png24" }
            }
            .task(id: "\(format)\(colors)\(palette)\(dither)\(transparency)\(quality)\(percent)\(loops)") { await estimateSize() }
        }
    }

    /// The file's size with these settings (the engine optimises without writing).
    private func estimateSize() async {
        estimate = "Working out the size…"
        let editor = model.editor, p = json(params)
        let out = await Task.detached(priority: .utility) { try? editor.execute(id: "file.export.saveForWebLegacy", params: p) }.value
        guard !Task.isCancelled else { return }
        let o = out.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        guard let bytes = o?["bytes"] as? Int else { estimate = nil; return }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        estimate = (o?["frames"] as? Int).map { "\(size) · \($0) frames" } ?? size
    }
}
