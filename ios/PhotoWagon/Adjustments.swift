import SwiftUI

/// Adjustments with a screen of their own, for Image › Adjustments and an adjustment layer's
/// Properties alike. The rest use the plain settings form.
struct AdjustmentEditor: View {
    @ObservedObject var model: EditorModel
    let kind: String
    /// An adjustment layer; `nil` for Image › Adjustments on the active layer.
    let layer: UInt64?
    let initial: [String: Any]
    /// Where the eyedroppers pick.
    var surface = PickSurface.preview
    var runTitle = "OK"
    var inPanel = false
    /// Joins a layer's changes into one undo step.
    var key = ""
    let change: ([String: Any]) -> Void
    let run: ([String: Any]) -> Void

    static let kinds: Set<String> = ["levels", "curves", "colorBalance", "channelMixer", "gradientMap", "hueSaturation", "selectiveColor",
                                     "threshold", "photoFilter", "blackWhite", "replaceColor"]

    /// The adjustment `id` runs (`image.adjustments.curves` → `curves`) when it has its own screen.
    static func kind(for id: String) -> String? {
        guard id.hasPrefix("image.adjustments.") else { return nil }
        let k = String(id.dropFirst("image.adjustments.".count))
        return kinds.contains(k) ? k : nil
    }

    var body: some View {
        switch kind {
        case "levels": LevelsEditor(model: model, layer: layer, initial: initial, surface: surface, runTitle: runTitle, change: change, run: run)
        case "curves": CurvesEditor(model: model, layer: layer, initial: initial, surface: surface, runTitle: runTitle, change: change, run: run)
        case "hueSaturation":
            HueSaturationProperties(model: model, layer: layer, key: key, inPanel: inPanel, initial: initial, runTitle: runTitle, change: change, run: run)
        case "colorBalance": ColorBalanceEditor(initial: initial, runTitle: runTitle, change: change, run: run)
        case "channelMixer": ChannelMixerEditor(initial: initial, runTitle: runTitle, change: change, run: run)
        case "selectiveColor": SelectiveColorEditor(initial: initial, runTitle: runTitle, change: change, run: run)
        case "threshold": ThresholdEditor(model: model, layer: layer, initial: initial, runTitle: runTitle, change: change, run: run)
        // Image › Adjustments shows its starting settings at once, as Photoshop does.
        case "photoFilter": PhotoFilterEditor(initial: initial, showNow: layer == nil, runTitle: runTitle, change: change, run: run)
        case "blackWhite": BlackWhiteEditor(model: model, layer: layer, initial: initial, runTitle: runTitle, change: change, run: run)
        case "gradientMap": GradientMapEditor(model: model, initial: initial, runTitle: runTitle, change: change, run: run)
        case "replaceColor": ReplaceColorEditor(model: model, initial: initial, surface: surface, runTitle: runTitle, change: change, run: run)
        default: EmptyView()
        }
    }
}

/// A settings screen of its own: a form with OK (or Done) to finish.
struct EditorForm<Content: View>: View {
    let title: String
    let runTitle: String
    let run: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A layer's Properties have their own Done.
                if !runTitle.isEmpty {
                    ToolbarItem(placement: .confirmationAction) { Button(runTitle, action: run).accessibilityIdentifier("settings.run") }
                }
            }
    }
}

/// Numbers out of params, whether they came from the engine (`NSNumber`) or from us.
func numbers(_ v: Any?) -> [Double]? {
    (v as? [Double]) ?? (v as? [NSNumber])?.map(\.doubleValue)
}

func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

/// A slider between two opposites (Color Balance's Cyan and Red), applied when let go.
struct PairSlider: View {
    let left: String
    let right: String
    let value: Double
    var range: ClosedRange<Double> = -100...100
    let id: String
    let set: (Double) -> Void
    @State private var dragged: Double?

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(left)
                Spacer()
                Text("\(Int(dragged ?? value))").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Text(right)
            }
            .font(.callout)
            Slider(value: Binding(get: { dragged ?? value }, set: { dragged = $0.rounded() }), in: range) { editing in
                if !editing, let d = dragged {
                    set(d)
                    dragged = nil
                }
            }
            .accessibilityIdentifier(id)
        }
    }
}

/// A colour swatch that opens the system colour picker.
struct ColorRow: View {
    let title: String
    /// `#rrggbb`; `nil` shows an empty swatch.
    let hex: String?
    let id: String
    let set: (String) -> Void

    var body: some View {
        Button {
            SystemColorPicker.present(title: title, rgb: hex.map(EffectPage.rgb) ?? []) { set(Self.hex($0)) }
        } label: {
            HStack {
                Text(title)
                Spacer()
                RoundedRectangle(cornerRadius: 6)
                    .fill(hex.map { Color(hex: $0) } ?? Color.gray.opacity(0.25))
                    .frame(width: 44, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary))
            }
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier(id)
    }

    static func hex(_ rgb: [Float]) -> String {
        let c = (0..<3).map { Int((min(max(rgb.indices.contains($0) ? rgb[$0] : 0, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", c[0], c[1], c[2])
    }

    static func hex(_ c: UIColor) -> String {
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return hex([r, g, b].map { Float($0) })
    }
}

// MARK: - Color Balance

struct ColorBalanceEditor: View {
    let initial: [String: Any]
    var runTitle = "OK"
    let change: ([String: Any]) -> Void
    let run: ([String: Any]) -> Void
    @State private var p: [String: Any] = [:]
    @State private var tone = "midtones"

    var body: some View {
        EditorForm(title: "Color Balance", runTitle: runTitle, run: { run(p) }) {
            Section {
                Picker("Tone", selection: $tone) {
                    Text("Shadows").tag("shadows")
                    Text("Midtones").tag("midtones")
                    Text("Highlights").tag("highlights")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("balance.tone")
                let v = numbers(p[tone]) ?? [0, 0, 0]
                ForEach(0..<3, id: \.self) { i in
                    PairSlider(left: ["Cyan", "Magenta", "Yellow"][i], right: ["Red", "Green", "Blue"][i], value: v.indices.contains(i) ? v[i] : 0,
                               id: "balance.\(i)") { x in
                        var w = numbers(p[tone]) ?? [0, 0, 0]
                        if w.count == 3 { w[i] = x }
                        set([tone: w])
                    }
                }
            }
            Toggle("Preserve Luminosity", isOn: Binding(get: { p["preserveLuminosity"] as? Bool ?? true }, set: { set(["preserveLuminosity": $0]) }))
                .accessibilityIdentifier("balance.preserve")
        }
        .onAppear { if p.isEmpty { p = initial } }
    }

    private func set(_ q: [String: Any]) {
        p.merge(q) { _, b in b }
        change(p)
    }
}

// MARK: - Channel Mixer

struct ChannelMixerEditor: View {
    let initial: [String: Any]
    var runTitle = "OK"
    let change: ([String: Any]) -> Void
    let run: ([String: Any]) -> Void
    @State private var p: [String: Any] = [:]
    @State private var output = "red"
    @State private var preset = "Default"

    static let defaults: [String: [Double]] = ["red": [100, 0, 0, 0], "green": [0, 100, 0, 0], "blue": [0, 0, 100, 0], "gray": [40, 40, 20, 0]]
    static let presets: [(name: String, params: [String: Any])] = [
        ("Default", ["monochrome": false, "red": defaults["red"]!, "green": defaults["green"]!, "blue": defaults["blue"]!]),
        ("Monochrome", ["monochrome": true, "gray": [40.0, 40, 20, 0]]),
        ("Monochrome, Red Filter", ["monochrome": true, "gray": [100.0, 0, 0, 0]]),
        ("Monochrome, Green Filter", ["monochrome": true, "gray": [0.0, 100, 0, 0]]),
        ("Monochrome, Blue Filter", ["monochrome": true, "gray": [0.0, 0, 100, 0]]),
        ("Swap Red and Blue", ["monochrome": false, "red": [0.0, 0, 100, 0], "green": [0.0, 100, 0, 0], "blue": [100.0, 0, 0, 0]]),
    ]

    private var mono: Bool { p["monochrome"] as? Bool ?? false }
    private var key: String { mono ? "gray" : output }
    private var mix: [Double] { numbers(p[key]).flatMap { $0.count == 4 ? $0 : nil } ?? Self.defaults[key] ?? [0, 0, 0, 0] }

    /// The sum of the source channels, as Photoshop's Total shows it.
    static func total(_ mix: [Double]) -> Double { mix.prefix(3).reduce(0, +) }

    var body: some View {
        EditorForm(title: "Channel Mixer", runTitle: runTitle, run: { run(p) }) {
            Section {
                PresetPicker(names: Self.presets.map(\.name), current: preset, id: "mixer.preset") { name in
                    guard let pr = Self.presets.first(where: { $0.name == name }) else { return }
                    set(pr.params)
                    preset = name
                }
                if !mono {
                    Picker("Output Channel", selection: $output) {
                        Text("Red").tag("red")
                        Text("Green").tag("green")
                        Text("Blue").tag("blue")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("mixer.output")
                }
                Toggle("Monochrome", isOn: Binding(get: { mono }, set: { set(["monochrome": $0]); preset = "Custom" }))
                    .accessibilityIdentifier("mixer.monochrome")
            }
            Section {
                ForEach(0..<3, id: \.self) { i in
                    StyleSlider(title: ["Red", "Green", "Blue"][i], value: mix[i], range: -200...200, unit: "%", id: "mixer.\(i)") { setMix(i, $0) }
                }
                let total = Self.total(mix)
                HStack {
                    Text("Total")
                    Spacer()
                    if total > 100 { Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow) }
                    Text("\(Int(total))%").monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("mixer.total")
                StyleSlider(title: "Constant", value: mix[3], range: -200...200, unit: "%", id: "mixer.3") { setMix(3, $0) }
            } header: {
                Text(mono ? "Gray" : output.capitalized)
            }
        }
        .onAppear {
            guard p.isEmpty else { return }
            p = initial
            if !initial.isEmpty { preset = "Custom" }
        }
    }

    private func setMix(_ i: Int, _ v: Double) {
        var m = mix
        m[i] = v
        set([key: m])
        preset = "Custom"
    }

    private func set(_ q: [String: Any]) {
        p.merge(q) { _, b in b }
        change(p)
    }
}

// MARK: - Selective Color

struct SelectiveColorEditor: View {
    let initial: [String: Any]
    var runTitle = "OK"
    let change: ([String: Any]) -> Void
    let run: ([String: Any]) -> Void
    @State private var p: [String: Any] = [:]
    @State private var range = "reds"

    static let ranges = ["reds", "yellows", "greens", "cyans", "blues", "magentas", "whites", "neutrals", "blacks"]

    private var cmyk: [Double] { numbers(p[range]).flatMap { $0.count == 4 ? $0 : nil } ?? [0, 0, 0, 0] }

    var body: some View {
        EditorForm(title: "Selective Color", runTitle: runTitle, run: { run(params) }) {
            Section {
                Picker("Colors", selection: $range) {
                    ForEach(Self.ranges, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .accessibilityIdentifier("selective.colors")
                ForEach(0..<4, id: \.self) { i in
                    StyleSlider(title: ["Cyan", "Magenta", "Yellow", "Black"][i], value: cmyk[i], range: -100...100, unit: "%", id: "selective.\(i)") { v in
                        var c = cmyk
                        c[i] = v
                        p[range] = c
                        change(params)
                    }
                }
            }
            Picker("Method", selection: Binding(get: { p["method"] as? String ?? "relative" }, set: { p["method"] = $0; change(params) })) {
                Text("Relative").tag("relative")
                Text("Absolute").tag("absolute")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("selective.method")
        }
        .onAppear { if p.isEmpty { p = initial } }
    }

    /// Every range's values, so switching colours keeps the others.
    private var params: [String: Any] {
        var out: [String: Any] = ["method": p["method"] as? String ?? "relative"]
        for r in Self.ranges { out[r] = numbers(p[r]) ?? [0, 0, 0, 0] }
        return out
    }
}

// MARK: - Threshold

struct ThresholdEditor: View {
    @ObservedObject var model: EditorModel
    let layer: UInt64?
    let initial: [String: Any]
    var runTitle = "OK"
    let change: ([String: Any]) -> Void
    let run: ([String: Any]) -> Void
    @State private var level = 128.0
    @State private var bins: [Int] = []

    var body: some View {
        EditorForm(title: "Threshold", runTitle: runTitle, run: { run(["level": level]) }) {
            Section("Threshold Level") {
                VStack(spacing: 2) {
                    LevelsHistogram(bins: bins, tint: .primary).frame(height: 120)
                    GeometryReader { g in
                        ThresholdHandle().position(x: CGFloat(level / 255) * g.size.width, y: 10)
                    }
                    .frame(height: 20)
                }
                .overlay {
                    GeometryReader { g in
                        Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0)
                            .onChanged { d in level = min(max((Double(d.location.x / max(g.size.width, 1)) * 255).rounded(), 1), 255) }
                            .onEnded { _ in change(["level": level]) })
                    }
                }
                .accessibilityElement()
                .accessibilityIdentifier("threshold.graph")
                StyleSlider(title: "Level", value: level, range: 1...255, unit: "", id: "threshold.level") { level = $0; change(["level": $0]) }
            }
        }
        .onAppear {
            if let l = number(initial["level"]) { level = l }
            bins = ToneInfo.load(model, layer: layer)?.channels.first?.bins ?? []
            if layer == nil { change(["level": level]) }
        }
    }
}

private struct ThresholdHandle: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 9, y: 0)); p.addLine(to: CGPoint(x: 18, y: 14)); p.addLine(to: CGPoint(x: 0, y: 14)); p.closeSubpath()
        }
        .fill(Color.white)
        .frame(width: 18, height: 14)
    }
}

// MARK: - Photo Filter

struct PhotoFilterEditor: View {
    let initial: [String: Any]
    var showNow = false
    var runTitle = "OK"
    let change: ([String: Any]) -> Void
    let run: ([String: Any]) -> Void
    @State private var p: [String: Any] = [:]
    @State private var useColor = false

    static let filters: [(key: String, name: String)] = [
        ("warming85", "Warming Filter (85)"), ("warmingLBA", "Warming Filter (LBA)"), ("warming81", "Warming Filter (81)"),
        ("cooling80", "Cooling Filter (80)"), ("coolingLBB", "Cooling Filter (LBB)"), ("cooling82", "Cooling Filter (82)"),
        ("red", "Red"), ("orange", "Orange"), ("yellow", "Yellow"), ("green", "Green"), ("cyan", "Cyan"), ("blue", "Blue"),
        ("violet", "Violet"), ("magenta", "Magenta"), ("sepia", "Sepia"), ("deepRed", "Deep Red"), ("deepBlue", "Deep Blue"),
        ("deepEmerald", "Deep Emerald"), ("deepYellow", "Deep Yellow"), ("underwater", "Underwater"),
    ]

    var body: some View {
        EditorForm(title: "Photo Filter", runTitle: runTitle, run: { run(params) }) {
            Section {
                Picker("Use", selection: Binding(get: { useColor }, set: { useColor = $0; change(params) })) {
                    Text("Filter").tag(false)
                    Text("Color").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("photoFilter.use")
                if useColor {
                    ColorRow(title: "Color", hex: p["color"] as? String ?? "#ec8a00", id: "photoFilter.color") { p["color"] = $0; change(params) }
                } else {
                    Picker("Filter", selection: Binding(get: { p["filter"] as? String ?? "warming85" }, set: { p["filter"] = $0; change(params) })) {
                        ForEach(Self.filters, id: \.key) { Text($0.name).tag($0.key) }
                    }
                    .accessibilityIdentifier("photoFilter.filter")
                }
            }
            Section {
                StyleSlider(title: "Density", value: number(p["density"]) ?? 25, range: 0...100, unit: "%", id: "photoFilter.density") { p["density"] = $0; change(params) }
                Toggle("Preserve Luminosity", isOn: Binding(get: { p["preserveLuminosity"] as? Bool ?? true }, set: { p["preserveLuminosity"] = $0; change(params) }))
                    .accessibilityIdentifier("photoFilter.preserve")
            }
        }
        .onAppear {
            guard p.isEmpty else { return }
            p = initial
            // An adjustment layer keeps the colour, not the filter's name.
            useColor = initial["color"] != nil && initial["filter"] == nil
            if showNow { change(params) }
        }
    }

    private var params: [String: Any] {
        var out = p
        if useColor {
            out["filter"] = nil
            if out["color"] == nil { out["color"] = "#ec8a00" }
        } else {
            out["color"] = nil
            if out["filter"] == nil { out["filter"] = "warming85" }
        }
        return out
    }
}

// MARK: - Black & White

struct BlackWhiteEditor: View {
    @ObservedObject var model: EditorModel
    let layer: UInt64?
    let initial: [String: Any]
    var runTitle = "OK"
    let change: ([String: Any]) -> Void
    let run: ([String: Any]) -> Void
    @State private var p: [String: Any] = [:]
    @State private var presets: [(name: String, weights: [String: Any])] = []
    @State private var auto: String?
    @State private var preset = "Default"

    static let ranges: [(key: String, name: String, color: Color, value: Double)] = [
        ("reds", "Reds", .red, 40), ("yellows", "Yellows", .yellow, 60), ("greens", "Greens", .green, 40),
        ("cyans", "Cyans", .cyan, 60), ("blues", "Blues", .blue, 20), ("magentas", "Magentas", .pink, 80),
    ]

    var body: some View {
        EditorForm(title: "Black & White", runTitle: runTitle, run: { run(p) }) {
            Section {
                HStack {
                    PresetPicker(names: presets.map(\.name), current: preset, id: "bw.preset") { name in
                        guard let w = presets.first(where: { $0.name == name })?.weights else { return }
                        set(w)
                        preset = name
                    }
                    Spacer()
                    Button("Auto") {
                        if let auto, let w = presets.first(where: { $0.name == auto })?.weights { set(w); preset = "Auto" }
                    }
                    .buttonStyle(.bordered)
                    .disabled(auto == nil)
                    .accessibilityIdentifier("bw.auto")
                }
            }
            Section {
                ForEach(Self.ranges, id: \.key) { r in
                    HStack(spacing: 6) {
                        Circle().fill(r.color).frame(width: 10, height: 10)
                        StyleSlider(title: r.name, value: number(p[r.key]) ?? r.value, range: -200...300, unit: "%", id: "bw.\(r.key)") { set([r.key: $0]) }
                    }
                }
            }
            Section {
                Toggle("Tint", isOn: Binding(get: { p["tint"] as? Bool ?? false }, set: { set(["tint": $0]) }))
                    .accessibilityIdentifier("bw.tint")
                if p["tint"] as? Bool == true {
                    ColorRow(title: "Tint Color", hex: p["tintColor"] as? String ?? "#e1d3b3", id: "bw.tintColor") { set(["tintColor": $0]) }
                }
            }
        }
        .onAppear {
            guard p.isEmpty else { return }
            p = initial
            if !initial.isEmpty { preset = "Custom" }
            let out = model.query("image.blackWhiteAuto", layer.map { ["layer": $0] } ?? [:]) as? [String: Any]
            auto = out?["auto"] as? String
            presets = (out?["presets"] as? [[String: Any]] ?? []).compactMap { d in
                guard let n = d["name"] as? String, let w = d["weights"] as? [String: Any] else { return nil }
                return (n, w)
            }
            if layer == nil { change(p) }
        }
    }

    private func set(_ q: [String: Any]) {
        p.merge(q) { _, b in b }
        preset = "Custom"
        change(p)
    }
}

// MARK: - Gradient Map

struct GradientMapEditor: View {
    @ObservedObject var model: EditorModel
    let initial: [String: Any]
    var runTitle = "OK"
    let change: ([String: Any]) -> Void
    let run: ([String: Any]) -> Void
    @State private var p: [String: Any] = [:]
    @State private var presets: [GradientPreset] = []

    private var stops: [[Any]] { p["stops"] as? [[Any]] ?? [] }

    var body: some View {
        EditorForm(title: "Gradient Map", runTitle: runTitle, run: { run(p) }) {
            Section {
                GradientSwatch(stops: stops).frame(height: 28).accessibilityIdentifier("gmap.swatch")
                Toggle("Reverse", isOn: Binding(get: { p["reverse"] as? Bool ?? false }, set: { set(["reverse": $0]) }))
                    .accessibilityIdentifier("gmap.reverse")
                Toggle("Dither", isOn: Binding(get: { p["dither"] as? Bool ?? false }, set: { set(["dither": $0]) }))
                    .accessibilityIdentifier("gmap.dither")
            }
            GradientStopsSections(stops: stops, presets: presets, id: "gmap") { set(["stops": $0]) }
        }
        .onAppear {
            guard p.isEmpty else { return }
            p = initial
            if stops.count < 2 {
                p["stops"] = [[0.0, ColorRow.hex(model.foreground)], [1.0, ColorRow.hex(model.backgroundColor)]]
                change(p)
            }
            presets = GradientPreset.load(model)
        }
    }

    private func set(_ q: [String: Any]) {
        p.merge(q) { _, b in b }
        change(p)
    }
}

/// A gradient from the presets: its group, name and colour stops.
struct GradientPreset {
    let group: String
    let name: String
    let stops: [[Any]]

    @MainActor
    static func load(_ model: EditorModel) -> [GradientPreset] {
        guard let list = model.query("gradient.presets.list") as? [String: Any], let groups = list["groups"] as? [[String: Any]] else { return [] }
        return groups.flatMap { g in
            (g["presets"] as? [[String: Any]] ?? []).compactMap { p in
                guard let name = p["name"] as? String, let stops = p["stops"] as? [[Any]],
                      stops.allSatisfy({ ($0.last as? String)?.hasPrefix("#") == true }) else { return nil }
                return GradientPreset(group: g["name"] as? String ?? "", name: name, stops: stops)
            }
        }
    }
}

/// A gradient's colour stops (colour and location each) and the presets to start from.
struct GradientStopsSections: View {
    let stops: [[Any]]
    let presets: [GradientPreset]
    let id: String
    let set: ([[Any]]) -> Void

    var body: some View {
        Section("Color Stops") {
            ForEach(Array(stops.enumerated()), id: \.offset) { i, s in
                HStack {
                    Button { pick(i) } label: {
                        RoundedRectangle(cornerRadius: 4).fill(Color(hex: s.last as? String ?? "#000000")).frame(width: 36, height: 24)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("\(id).stop.\(i)")
                    Slider(value: Binding(get: { number(s.first) ?? 0 }, set: { move(i, $0) }), in: 0...1)
                    Text("\(Int((number(s.first) ?? 0) * 100))%").monospacedDigit().lineLimit(1).frame(width: scaled(52))
                }
            }
            .onDelete { idx in
                var s = stops
                s.remove(atOffsets: idx)
                // A gradient needs two stops.
                if s.count >= 2 { set(s) }
            }
            Button("Add Stop") {
                var s = stops
                s.append([0.5, "#ffffff"])
                s.sort { (number($0.first) ?? 0) < (number($1.first) ?? 0) }
                set(s)
            }
            .accessibilityIdentifier("\(id).addStop")
        }
        Section("Presets") {
            ForEach(presets, id: \.name) { p in
                Button { set(p.stops) } label: {
                    HStack {
                        GradientSwatch(stops: p.stops).frame(width: 80, height: 18)
                        Text(p.name)
                    }
                }
                .accessibilityIdentifier("\(id).preset.\(p.name)")
            }
        }
    }

    private func pick(_ i: Int) {
        SystemColorPicker.present(title: "Stop Color", rgb: EffectPage.rgb(stops.indices.contains(i) ? stops[i].last as? String ?? "" : "")) { rgb in
            var s = stops
            guard s.indices.contains(i), let t = s[i].first else { return }
            s[i] = [t, ColorRow.hex(rgb)]
            set(s)
        }
    }

    private func move(_ i: Int, _ t: Double) {
        var s = stops
        guard s.indices.contains(i), let c = s[i].last else { return }
        s[i] = [t, c]
        set(s)
    }
}

// MARK: - Replace Color

/// Replace Color: pick the colour in the preview, how far it spreads, and what it becomes.
struct ReplaceColorEditor: View {
    @ObservedObject var model: EditorModel
    let initial: [String: Any]
    var surface = PickSurface.preview
    var runTitle = "OK"
    let change: ([String: Any]) -> Void
    let run: ([String: Any]) -> Void
    @State private var p: [String: Any] = [:]
    @State private var sampler = PreviewSampler()
    @State private var picking: String?

    private var color: String { p["color"] as? String ?? ColorRow.hex(model.foreground) }

    var body: some View {
        EditorForm(title: "Replace Color", runTitle: runTitle, run: { run(p) }) {
            Section {
                HStack(spacing: 12) {
                    pickButton("pick", "eyedropper", "Pick the Color")
                    pickButton("add", "eyedropper.full", "Add to the Color")
                    Spacer()
                    RoundedRectangle(cornerRadius: 6).fill(Color(hex: color)).frame(width: 44, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary))
                        .accessibilityIdentifier("replace.sample")
                }
                if picking != nil, surface == .preview {
                    Text("Hold on the image, then let go on the color.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Localized Color Clusters", isOn: Binding(get: { p["localized"] as? Bool ?? false }, set: { set(["localized": $0]) }))
                    .accessibilityIdentifier("replace.localized")
                StyleSlider(title: "Fuzziness", value: number(p["fuzziness"]) ?? 40, range: 0...200, unit: "", id: "replace.fuzziness") { set(["fuzziness": $0]) }
                if p["localized"] as? Bool == true {
                    StyleSlider(title: "Range", value: number(p["range"]) ?? 100, range: 0...100, unit: "%", id: "replace.range") { set(["range": $0]) }
                }
            }
            Section("Replacement") {
                StyleSlider(title: "Hue", value: number(p["hue"]) ?? 0, range: -180...180, unit: "°", id: "replace.hue") { set(["hue": $0]) }
                StyleSlider(title: "Saturation", value: number(p["saturation"]) ?? 0, range: -100...100, unit: "", id: "replace.saturation") { set(["saturation": $0]) }
                StyleSlider(title: "Lightness", value: number(p["lightness"]) ?? 0, range: -100...100, unit: "", id: "replace.lightness") { set(["lightness": $0]) }
                HStack {
                    Text("Result")
                    Spacer()
                    RoundedRectangle(cornerRadius: 6).fill(Color(hex: Self.result(color, hue: number(p["hue"]) ?? 0, saturation: number(p["saturation"]) ?? 0,
                                                                                lightness: number(p["lightness"]) ?? 0)))
                        .frame(width: 44, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary))
                }
            }
        }
        .onAppear {
            guard p.isEmpty else { return }
            p = initial
            sampler = PreviewSampler(model, layer: nil)
        }
        .onDisappear { model.endPick() }
        .onChange(of: model.canvasPick == nil) { _, done in if done, surface == .canvas { picking = nil } }
    }

    private func pickButton(_ mode: String, _ symbol: String, _ title: String) -> some View {
        Button {
            picking = picking == mode ? nil : mode
            if picking == nil {
                model.endPick()
            } else {
                model.beginPick(surface, prompt: "Tap the color to replace") { pick(mode, $0) }
            }
        } label: {
            Image(systemName: symbol).font(.title3).frame(width: 44, height: 44)
                .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(picking == mode ? Color.accentColor : .secondary, lineWidth: picking == mode ? 3 : 1))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .accessibilityIdentifier("replace.\(mode)")
    }

    private func pick(_ mode: String, _ at: CGPoint) {
        guard let d = model.doc, let c = sampler.color(at: at) else { return }
        let pt = PreviewSampler.docPoint(at, d)
        var points = mode == "add" ? (p["points"] as? [[Int]] ?? []) : []
        points.append(pt)
        var q: [String: Any] = ["points": points]
        if mode == "pick" { q["color"] = ColorRow.hex(c.map { Float($0) }) }
        set(q)
    }

    /// The picked colour shifted by Hue, Saturation and Lightness, for the Result swatch.
    static func result(_ hex: String, hue: Double, saturation: Double, lightness: Double) -> String {
        let rgb = EffectPage.rgb(hex)
        guard rgb.count == 3 else { return hex }
        var (h, s, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        UIColor(red: CGFloat(rgb[0]), green: CGFloat(rgb[1]), blue: CGFloat(rgb[2]), alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        h = (h + CGFloat(hue / 360)).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        s = min(max(s * CGFloat(1 + saturation / 100), 0), 1)
        let c = UIColor(hue: h, saturation: s, brightness: b, alpha: 1)
        var (r, g, bl) = (CGFloat(0), CGFloat(0), CGFloat(0))
        c.getRed(&r, green: &g, blue: &bl, alpha: &a)
        let l = CGFloat(lightness / 100)
        let mix = { (v: CGFloat) in l >= 0 ? v + (1 - v) * l : v * (1 + l) }
        return ColorRow.hex([mix(r), mix(g), mix(bl)].map { Float($0) })
    }

    private func set(_ q: [String: Any]) {
        p.merge(q) { _, b in b }
        change(p)
    }
}
