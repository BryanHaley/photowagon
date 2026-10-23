import SwiftUI

/// Levels settings in the engine's params: the top-level keys are the composite (Lab: Lightness),
/// each other channel sits under its key.
struct LevelsValues: Equatable {
    struct Channel: Equatable {
        var inBlack = 0.0, gamma = 1.0, inWhite = 255.0, outBlack = 0.0, outWhite = 255.0
    }

    var channels: [String: Channel] = [:]

    init(channels: [String: Channel] = [:]) { self.channels = channels }

    init(_ p: [String: Any]) {
        channels[""] = Self.channel(p)
        for (k, v) in p {
            if let o = v as? [String: Any] { channels[k] = Self.channel(o) }
        }
    }

    private static func channel(_ o: [String: Any]) -> Channel {
        func n(_ k: String, _ d: Double) -> Double { (o[k] as? NSNumber)?.doubleValue ?? d }
        return Channel(inBlack: n("inBlack", 0), gamma: n("gamma", 1), inWhite: n("inWhite", 255), outBlack: n("outBlack", 0), outWhite: n("outWhite", 255))
    }

    subscript(key: String) -> Channel {
        get { channels[key] ?? Channel() }
        set { channels[key] = newValue }
    }

    /// Params for every channel in `keys`, unset ones at their defaults so old values don't stay.
    func params(keys: [String]) -> [String: Any] {
        func obj(_ c: Channel) -> [String: Any] {
            ["inBlack": c.inBlack, "gamma": c.gamma, "inWhite": c.inWhite, "outBlack": c.outBlack, "outWhite": c.outWhite]
        }
        var out = obj(self[""])
        for k in keys where !k.isEmpty { out[k] = obj(self[k]) }
        return out
    }

    /// Where the midtone handle sits between black and white (0…1) for `gamma`.
    static func midtone(gamma: Double) -> Double { pow(0.5, gamma) }

    /// The gamma that puts the midtone handle at `t` (0…1 between black and white).
    static func gamma(midtone t: Double) -> Double {
        let t = min(max(t, 0.001), 0.999)
        return min(max((log(t) / log(0.5) * 100).rounded() / 100, 0.01), 9.99)
    }

    /// Auto's levels.
    init(auto: AutoPixels.Result) {
        for (k, l) in auto.channels { channels[k] = Channel(inBlack: l.black, gamma: l.gamma, inWhite: l.white) }
    }

    /// What each input level of channel `key` comes out at (0…255): its own levels, then the
    /// composite's, as the engine applies them.
    func outputs(_ key: String) -> [Double] {
        let apply = { (c: Channel, v: Double) -> Double in
            let t = min(max((v - c.inBlack) / max(c.inWhite - c.inBlack, 1), 0), 1)
            return c.outBlack + pow(t, 1 / max(c.gamma, 0.01)) * (c.outWhite - c.outBlack)
        }
        return (0..<256).map { v in apply(self[""], key.isEmpty ? Double(v) : apply(self[key], Double(v))) }
    }

    static let presets: [(name: String, value: Channel)] = [
        ("Default", Channel()),
        ("Brighter", Channel(gamma: 1.3)),
        ("Darker", Channel(gamma: 0.75)),
        ("More Contrast", Channel(inBlack: 20, inWhite: 235)),
        ("Strong Contrast", Channel(inBlack: 40, inWhite: 215)),
        ("Lift Shadows", Channel(gamma: 1.15, outBlack: 25)),
        ("Soften Highlights", Channel(outWhite: 230)),
        ("Faded", Channel(outBlack: 35, outWhite: 225)),
    ]
}

/// What Levels adjusts, from `image.toneHistogram`.
struct ToneInfo {
    struct Channel: Identifiable {
        let name: String
        let key: String
        let bins: [Int]
        var id: String { key }
    }

    let channels: [Channel]
    let eyedroppers: Bool
    /// Auto can work on each colour (RGB); other modes use the composite.
    var isRGB: Bool { channels.contains { $0.key == "red" } }
    let grayPicker: Bool

    @MainActor
    static func load(_ model: EditorModel, layer: UInt64?) -> ToneInfo? {
        ToneInfo(model.query("image.toneHistogram", ["layer": layer ?? model.activeLayer?.id as Any]))
    }

    static func tint(_ key: String) -> Color {
        switch key {
        case "red": .red
        case "green": .green
        case "blue": .blue
        case "cyan": .cyan
        case "magenta": .pink
        case "yellow": .yellow
        default: .primary
        }
    }

    init?(_ out: Any?) {
        guard let o = out as? [String: Any], let list = o["channels"] as? [[String: Any]] else { return nil }
        channels = list.map { c in
            Channel(name: c["name"] as? String ?? "", key: c["key"] as? String ?? "", bins: (c["bins"] as? [NSNumber])?.map(\.intValue) ?? [])
        }
        eyedroppers = o["eyedroppers"] as? Bool ?? false
        grayPicker = o["grayPicker"] as? Bool ?? false
    }
}

/// Levels, laid out as a Photoshop user expects: preset, channel, the histogram with input
/// handles, the output bar, Auto and the black, gray and white point eyedroppers.
struct LevelsEditor: View {
    @ObservedObject var model: EditorModel
    /// An adjustment layer; `nil` for Image › Adjustments › Levels on the active layer.
    let layer: UInt64?
    let initial: [String: Any]
    var surface = PickSurface.preview
    var runTitle = "OK"
    let change: ([String: Any]) -> Void
    let run: ([String: Any]) -> Void

    @State private var values = LevelsValues()
    @State private var tone: ToneInfo?
    @State private var key = ""
    @State private var picking: String?
    @State private var sampler = PreviewSampler()
    @State private var loaded = false
    @State private var preset = "Default"
    @State private var pixels = AutoPixels(rgb: [])
    @State private var options = AutoOptions.saved()
    @State private var showClipping = false

    private var keys: [String] { tone?.channels.map(\.key) ?? [""] }
    private var bins: [Int] { tone?.channels.first { $0.key == key }?.bins ?? [] }
    private var channel: Binding<LevelsValues.Channel> {
        Binding(get: { values[key] }, set: { values[key] = $0; changed() })
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    PresetPicker(names: LevelsValues.presets.map(\.name), current: preset, id: "levels.preset") { name in
                        guard let p = LevelsValues.presets.first(where: { $0.name == name }) else { return }
                        values = LevelsValues(channels: ["": p.value])
                        changed()
                        preset = name
                    }
                    Spacer()
                    AutoRow(id: "levels", options: $options) { o in
                        values = LevelsValues(auto: pixels.auto(o, color: tone?.isRGB ?? false))
                        changed()
                        preset = "Auto"
                    }
                }
                if let tone, tone.channels.count > 1 {
                    let picker = Picker("Channel", selection: $key) {
                        ForEach(tone.channels) { Text($0.name).tag($0.key) }
                    }
                    .accessibilityIdentifier("levels.channel")
                    if tone.channels.count <= 4 { picker.pickerStyle(.segmented) } else { picker.pickerStyle(.menu) }
                }
                ClippingToggle(model: model, surface: surface, on: $showClipping, id: "levels")
            }
            Section("Input Levels") {
                let clip = showClipping ? ClipStats(bins: bins, outputs: values.outputs(key)) : nil
                VStack(spacing: 2) {
                    LevelsHistogram(bins: bins, tint: tint, marks: clip)
                        .frame(height: 120)
                    InputHandles(channel: channel)
                }
                if let clip {
                    Text(clip.text).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("levels.clipping")
                }
                HStack {
                    field("levels.inBlack", channel.inBlack, 0...253, whole: true)
                    Spacer()
                    field("levels.gamma", channel.gamma, 0.01...9.99, whole: false)
                    Spacer()
                    field("levels.inWhite", channel.inWhite, 2...255, whole: true)
                }
            }
            Section("Output Levels") {
                OutputHandles(channel: channel)
                HStack {
                    field("levels.outBlack", channel.outBlack, 0...255, whole: true)
                    Spacer()
                    field("levels.outWhite", channel.outWhite, 0...255, whole: true)
                }
            }
            if let tone, tone.eyedroppers {
                Section {
                    EyedropperRow(model: model, surface: surface, picking: $picking, gray: tone.grayPicker, id: "levels") { point, p in pick(point, at: p) }
                }
            }
        }
        .navigationTitle("Levels")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !runTitle.isEmpty {
                ToolbarItem(placement: .confirmationAction) {
                    Button(runTitle) { run(values.params(keys: keys)) }.accessibilityIdentifier("settings.run")
                }
            }
        }
        .onAppear(perform: load)
    }

    private var tint: Color { ToneInfo.tint(key) }

    private func load() {
        guard !loaded else { return }
        loaded = true
        values = LevelsValues(initial)
        if !initial.isEmpty { preset = "Custom" }
        tone = ToneInfo.load(model, layer: layer)
        sampler = PreviewSampler(model, layer: layer)
        pixels = AutoPixels.load(model, layer: layer)
    }

    private func changed() {
        preset = "Custom"
        change(values.params(keys: keys))
    }

    private func field(_ id: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, whole: Bool) -> some View {
        TextField("", value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }),
                  format: .number.precision(.fractionLength(whole ? 0...0 : 2...2)))
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .textFieldStyle(.roundedBorder)
            .frame(width: scaled(70))
            .accessibilityIdentifier(id)
    }

    /// An eyedropper tap at `p` (0…1 across the image).
    private func pick(_ point: String, at p: CGPoint) {
        guard let out = sampler.adjust("levels", values.params(keys: keys), point, at: p, model: model) else { return }
        values = LevelsValues(out)
        changed()
    }

}

/// Eyedropper taps on a settings screen's preview. Image › Adjustments samples the image as it
/// was before any try; an adjustment layer is sampled by the engine with the layer hidden.
struct PreviewSampler {
    var layer: UInt64?
    var snapshot: CGImage?

    init() {}

    @MainActor
    init(_ model: EditorModel, layer: UInt64?) {
        self.layer = layer
        if layer == nil, let png = try? model.editor.analysisImage(layer: nil, maxSide: 900) { snapshot = UIImage(data: png)?.cgImage }
    }

    /// The document pixel under `p` (0…1 across the image).
    static func docPoint(_ p: CGPoint, _ d: DocInfo) -> [Int] {
        [min(Int(p.x * CGFloat(d.width)), Int(d.width) - 1), min(Int(p.y * CGFloat(d.height)), Int(d.height) - 1)]
    }

    /// The colour under `p` in the snapshot.
    func color(at p: CGPoint) -> [Double]? { snapshot.flatMap { Self.color($0, at: p) } }

    /// Levels or Curves `params` after the `point` eyedropper is tapped at `p`.
    @MainActor
    func adjust(_ kind: String, _ params: [String: Any], _ point: String, at p: CGPoint, model: EditorModel) -> [String: Any]? {
        guard let d = model.doc else { return nil }
        var e: [String: Any] = ["point": point]
        if layer == nil {
            guard let c = color(at: p) else { return nil }
            e["color"] = c
        } else {
            e["at"] = Self.docPoint(p, d)
        }
        var q: [String: Any] = ["kind": kind, "params": params, "eyedropper": e]
        if let layer { q["layer"] = layer }
        return model.run("image.adjustmentEyedropper", q) as? [String: Any]
    }

    /// The colour (0…1) of `image` at `p` (0…1 across it).
    static func color(_ image: CGImage, at p: CGPoint) -> [Double]? {
        guard (0...1).contains(p.x), (0...1).contains(p.y) else { return nil }
        let x = min(Int(p.x * CGFloat(image.width)), image.width - 1), y = min(Int(p.y * CGFloat(image.height)), image.height - 1)
        guard let one = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard px[3] > 0 else { return nil }
        return px.prefix(3).map { Double($0) / Double(px[3]) }
    }
}

/// The histogram behind the input handles.
struct LevelsHistogram: View {
    let bins: [Int]
    let tint: Color
    /// Show Clipping: the levels that clip, in their own colours.
    var marks: ClipStats?

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.15)))
            let top = Double(bins.max() ?? 1).nonZero * 1.1
            let w = size.width / CGFloat(max(bins.count, 1))
            var (path, dark, light) = (Path(), Path(), Path())
            for (i, v) in bins.enumerated() where v > 0 {
                let h = size.height * CGFloat(min(Double(v) / top, 1))
                let r = CGRect(x: CGFloat(i) * w, y: size.height - h, width: max(w, 1), height: h)
                if marks?.dark[safe: i] == true { dark.addRect(r) } else if marks?.light[safe: i] == true { light.addRect(r) } else { path.addRect(r) }
            }
            ctx.fill(path, with: .color(tint.opacity(0.8)))
            ctx.fill(dark, with: .color(.cyan))
            ctx.fill(light, with: .color(.red))
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement()
        .accessibilityIdentifier("levels.histogram")
    }
}

private extension Double {
    var nonZero: Double { self > 0 ? self : 1 }
}

/// A triangle handle under a bar.
private struct Handle: View {
    let fill: Color
    var body: some View {
        Triangle().fill(fill).overlay(Triangle().stroke(Color.secondary, lineWidth: 1)).frame(width: 18, height: 14)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

/// The input black, midtone and white handles; a drag moves the nearest one.
private struct InputHandles: View {
    @Binding var channel: LevelsValues.Channel
    @State private var dragging: Int?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x = { (v: Double) in CGFloat(v / 255) * w }
            let mid = channel.inBlack + (channel.inWhite - channel.inBlack) * LevelsValues.midtone(gamma: channel.gamma)
            ZStack(alignment: .leading) {
                Color.clear
                Handle(fill: .black).position(x: x(channel.inBlack), y: 14)
                Handle(fill: .gray).position(x: x(mid), y: 14)
                Handle(fill: .white).position(x: x(channel.inWhite), y: 14)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let v = min(max(Double(d.location.x / max(w, 1)) * 255, 0), 255)
                if dragging == nil {
                    let dist = [channel.inBlack, mid, channel.inWhite].map { abs($0 - Double(d.startLocation.x / max(w, 1)) * 255) }
                    dragging = dist.firstIndex(of: dist.min() ?? 0)
                }
                switch dragging {
                case 0: channel.inBlack = min(v, channel.inWhite - 2).rounded()
                case 2: channel.inWhite = max(v, channel.inBlack + 2).rounded()
                default:
                    let span = max(channel.inWhite - channel.inBlack, 1)
                    channel.gamma = LevelsValues.gamma(midtone: (v - channel.inBlack) / span)
                }
            }.onEnded { _ in dragging = nil })
            .accessibilityElement()
            .accessibilityIdentifier("levels.input")
        }
        .frame(height: 28)
    }
}

/// The output gradient and its black and white handles.
private struct OutputHandles: View {
    @Binding var channel: LevelsValues.Channel
    @State private var dragging: Int?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x = { (v: Double) in CGFloat(v / 255) * w }
            VStack(spacing: 0) {
                LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                ZStack(alignment: .leading) {
                    Color.clear
                    Handle(fill: .black).position(x: x(channel.outBlack), y: 8)
                    Handle(fill: .white).position(x: x(channel.outWhite), y: 8)
                }
                .frame(height: 18)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let v = (min(max(Double(d.location.x / max(w, 1)) * 255, 0), 255)).rounded()
                if dragging == nil {
                    let s = Double(d.startLocation.x / max(w, 1)) * 255
                    dragging = abs(s - channel.outBlack) <= abs(s - channel.outWhite) ? 0 : 1
                }
                if dragging == 0 { channel.outBlack = v } else { channel.outWhite = v }
            }.onEnded { _ in dragging = nil })
            .accessibilityElement()
            .accessibilityIdentifier("levels.output")
        }
        .frame(height: 36)
    }
}

/// The black, gray and white point eyedroppers; the one picked takes taps on the preview.
struct EyedropperRow: View {
    @ObservedObject var model: EditorModel
    let surface: PickSurface
    @Binding var picking: String?
    var gray = true
    let id: String
    let pick: (String, CGPoint) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                dropper("black", "Set Black Point", .black)
                if gray { dropper("gray", "Set Gray Point", .gray) }
                dropper("white", "Set White Point", .white)
            }
            .frame(maxWidth: .infinity)
            if let picking, surface == .preview {
                Text("Hold on the image, then let go on the \(picking) point.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { model.endPick() }
        // Picked or cancelled on the canvas.
        .onChange(of: model.canvasPick == nil) { _, done in if done, surface == .canvas { picking = nil } }
    }

    private func dropper(_ point: String, _ title: String, _ fill: Color) -> some View {
        Button {
            picking = picking == point ? nil : point
            if picking == nil {
                model.endPick()
            } else {
                model.beginPick(surface, prompt: "Tap the image to set the \(point) point") { pick(point, $0) }
            }
        } label: {
            Image(systemName: "eyedropper.halffull")
                .font(.title3)
                .foregroundStyle(fill == .white ? Color.black : Color.white)
                .frame(width: 44, height: 44)
                .background(fill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(picking == point ? Color.accentColor : .secondary, lineWidth: picking == point ? 3 : 1))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .accessibilityIdentifier("\(id).\(point)Point")
    }
}

/// Preset: the list to start from; the current settings show as Custom (or Auto) when they
/// aren't one of them.
struct PresetPicker: View {
    let names: [String]
    let current: String
    let id: String
    let pick: (String) -> Void

    var body: some View {
        Picker("Preset", selection: Binding(get: { current }, set: { if names.contains($0) { pick($0) } })) {
            ForEach(names, id: \.self) { Text($0).tag($0) }
            if !names.contains(current) { Text(current).tag(current) }
        }
        .accessibilityIdentifier(id)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Auto and its Options…, shared by Levels and Curves.
struct AutoRow: View {
    let id: String
    @Binding var options: AutoOptions
    let auto: (AutoOptions) -> Void
    @State private var showOptions = false

    var body: some View {
        HStack(spacing: 8) {
            Button("Options…") { showOptions = true }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("\(id).options")
            Button("Auto") { auto(options) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(id).auto")
        }
        .sheet(isPresented: $showOptions) {
            AutoOptionsSheet(options: options) { o in
                options = o
                auto(o)
            }
        }
    }
}

/// Show Clipping: marks on the histogram, and outlines of what clips on the preview (on an iPad
/// or in Window › Properties, a small preview here shows them).
struct ClippingToggle: View {
    @ObservedObject var model: EditorModel
    let surface: PickSurface
    @Binding var on: Bool
    let id: String

    var body: some View {
        Toggle("Show Clipping", isOn: $on)
            .accessibilityIdentifier("\(id).showClipping")
            .onChange(of: on) { _, v in model.previewClipping = v }
            .onDisappear { model.previewClipping = false }
        if on, surface == .canvas {
            PreviewPane(model: model).listRowInsets(EdgeInsets())
        }
    }
}
