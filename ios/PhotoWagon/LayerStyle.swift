import SwiftUI

/// Layer › Layer Style, as Photoshop's dialog: Blending Options (Fill, Blend If, Transparency
/// Shapes Layer) and the effects. Changes show as you make them; Cancel takes them back.
enum LayerStyle {
    /// Effect kinds in Photoshop's order, and whether a layer can have more than one.
    static let kinds: [(kind: String, label: String, many: Bool)] = [
        ("bevelEmboss", "Bevel & Emboss", false), ("stroke", "Stroke", true), ("innerShadow", "Inner Shadow", true),
        ("innerGlow", "Inner Glow", false), ("satin", "Satin", false), ("colorOverlay", "Color Overlay", true),
        ("gradientOverlay", "Gradient Overlay", true), ("patternOverlay", "Pattern Overlay", false),
        ("outerGlow", "Outer Glow", false), ("dropShadow", "Drop Shadow", true),
    ]

    static func label(_ kind: String) -> String { kinds.first { $0.kind == kind }?.label ?? kind }
}

/// One effect of the layer being styled: its settings in its command's params, and the engine's
/// snapshot of it (which keeps what this sheet doesn't show).
struct StyleEffect: Identifiable {
    let id = UUID()
    let kind: String
    var enabled: Bool
    var params: [String: Any]
    var fx: Any?
}

@MainActor
final class LayerStyleState: ObservableObject {
    let model: EditorModel
    let layer: UInt64
    @Published var blending: [String: Any] = [:]
    @Published var effects: [StyleEffect] = []
    /// "blendingOptions" or an effect's id.
    @Published var page = "blendingOptions"
    var light = 120.0
    private let key = UUID().uuidString
    private(set) var changed = false
    /// A shadow drag's starting offset (x, y) in pixels.
    private var dragFrom: (Double, Double)?

    init(model: EditorModel, layer: UInt64, start: String) {
        self.model = model
        self.layer = layer
        if let got = model.query("layer.layerStyle.get", ["layer": layer]) as? [String: Any] {
            blending = got["blending"] as? [String: Any] ?? [:]
            light = (got["globalLight"] as? NSNumber)?.doubleValue ?? 120
            effects = (got["effects"] as? [[String: Any]] ?? []).map {
                StyleEffect(kind: $0["kind"] as? String ?? "", enabled: $0["enabled"] as? Bool ?? true, params: $0["params"] as? [String: Any] ?? [:], fx: $0["fx"])
            }
        }
        if start != "blendingOptions" {
            if let e = effects.first(where: { $0.kind == start }) {
                page = e.id.uuidString
                if !e.enabled { set(e.id, enabled: true) }
            } else {
                add(start)
            }
        }
    }

    var current: StyleEffect? { effects.first { $0.id.uuidString == page } }

    func add(_ kind: String) {
        var p = (model.query("layer.layerStyle.defaultFor", ["kind": kind]) as? [String: Any])?["params"] as? [String: Any] ?? [:]
        if p["useGlobalLight"] as? Bool == true { p["angle"] = light }
        let e = StyleEffect(kind: kind, enabled: true, params: p)
        // Photoshop puts a new copy above the one it copies.
        if let i = effects.firstIndex(where: { $0.kind == kind }) { effects.insert(e, at: i) } else { effects.append(e) }
        page = e.id.uuidString
        applyEffects()
    }

    func delete(_ id: UUID) {
        effects.removeAll { $0.id == id }
        page = "blendingOptions"
        applyEffects()
    }

    func set(_ id: UUID, enabled: Bool) {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return }
        effects[i].enabled = enabled
        applyEffects()
    }

    func set(_ id: UUID, _ key: String, _ value: Any) { set(id, [key: value]) }

    func set(_ id: UUID, _ values: [String: Any]) {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return }
        effects[i].params.merge(values) { _, b in b }
        // Effects lit by the global light share one angle: the document's.
        if let a = values["angle"] as? Double, effects[i].params["useGlobalLight"] as? Bool == true {
            light = a
            for j in effects.indices where effects[j].params["useGlobalLight"] as? Bool == true { effects[j].params["angle"] = a }
            model.run("layer.layerStyle.globalLight", ["angle": a, "coalesce": self.key])
        }
        applyEffects()
    }

    func setBlending(_ key: String, _ value: Any) {
        blending[key] = value
        var p = blending
        p["layer"] = layer
        p["coalesce"] = self.key
        model.run("layer.layerStyle.blendingOptions", p)
        changed = true
    }

    /// Blend If's channels, Gray first, as `layer.layerStyle.blendingOptions` takes them.
    var blendIfChannels: [[String: Any]] {
        let v = blending["blendIf"]
        if let list = v as? [[String: Any]] { return list }
        return (v as? [String: Any])?["channels"] as? [[String: Any]] ?? [["channel": "gray"]]
    }

    /// `thisLayer` or `underlying` of `channel`: [black low, black high, white low, white high].
    func blendIfRange(_ channel: String, _ key: String) -> [Double] {
        let entry = blendIfChannels.first { $0["channel"] as? String == channel }
        return (entry?[key] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 255, 255]
    }

    func setBlendIf(_ channel: String, _ key: String, _ values: [Double]) {
        var list = blendIfChannels
        let v = values.map { $0.rounded() }
        if let i = list.firstIndex(where: { $0["channel"] as? String == channel }) {
            list[i][key] = v
        } else {
            list.append(["channel": channel, key: v])
        }
        setBlending("blendIf", list)
    }

    private func applyEffects() {
        let list: [[String: Any]] = effects.map { e in
            var p = e.params
            p["enabled"] = e.enabled
            var entry: [String: Any] = ["kind": e.kind, "params": p]
            if let fx = e.fx, !(fx is NSNull) { entry["fx"] = fx }
            return entry
        }
        model.run("layer.layerStyle.replace", ["layer": layer, "effects": list, "coalesce": key])
        changed = true
    }

    func cancel() {
        if changed { model.run("edit.undo") }
    }

    /// While a shadow's page is open, dragging in the image moves the shadow, as in Photoshop.
    func updateDrag() {
        guard let e = current, ["dropShadow", "innerShadow"].contains(e.kind) else { model.sheetDrag = nil; return }
        model.sheetDrag = SheetDrag { [weak self] began, from, to in
            guard let self, let e = self.current else { return }
            let num = { (k: String) in (e.params[k] as? NSNumber)?.doubleValue ?? 0 }
            if began {
                // Photoshop's angle is where the light comes from: the shadow falls the other way.
                let a = num("angle") * .pi / 180
                dragFrom = (-cos(a) * num("distance"), sin(a) * num("distance"))
            }
            guard let (x0, y0) = dragFrom else { return }
            let dx = x0 + Double(to.x - from.x), dy = y0 + Double(to.y - from.y)
            var v: [String: Any] = ["distance": hypot(dx, dy).rounded()]
            if hypot(dx, dy) >= 1 { v["angle"] = (atan2(dy, -dx) * 180 / .pi).rounded() }
            set(e.id, v)
        }
    }
}

struct LayerStyleSheet: View {
    @StateObject private var style: LayerStyleState
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePanel) private var closePanel
    @Environment(\.horizontalSizeClass) private var width

    init(model: EditorModel, layer: UInt64, start: String) {
        self.model = model
        _style = StateObject(wrappedValue: LayerStyleState(model: model, layer: layer, start: start))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // A phone's sheet covers the image.
                if width != .regular { PreviewPane(model: model) }
                pages
                if let e = style.current {
                    EffectPage(style: style, effect: e)
                } else {
                    BlendingOptionsPage(style: style)
                }
            }
            .navigationTitle("Layer Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { style.cancel(); close() }.accessibilityIdentifier("style.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { close() }.accessibilityIdentifier("style.ok")
                }
            }
        }
        .onAppear { style.updateDrag() }
        .interactiveDismissDisabled()
        .onChange(of: style.page) { _, _ in style.updateDrag() }
        .onDisappear { model.sheetDrag = nil }
    }

    private func close() { if let closePanel { closePanel() } else { dismiss() } }

    /// Photoshop's list down the dialog's left, as a row of pages.
    private var pages: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    page("Blending Options", id: "blendingOptions", on: nil)
                    ForEach(style.effects) { e in
                        page(LayerStyle.label(e.kind), id: e.id.uuidString, on: e.enabled)
                    }
                    Menu {
                        ForEach(LayerStyle.kinds, id: \.kind) { k in
                            Button(k.label) {
                                if !k.many, let e = style.effects.first(where: { $0.kind == k.kind }) {
                                    style.page = e.id.uuidString
                                    if !e.enabled { style.set(e.id, enabled: true) }
                                } else {
                                    style.add(k.kind)
                                }
                            }
                        }
                    } label: { Label("Add Effect", systemImage: "plus") .font(.caption) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("style.add")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: style.page) { _, p in withAnimation { proxy.scrollTo(p) } }
        }
    }

    private func page(_ title: String, id: String, on: Bool?) -> some View {
        Button { style.page = id } label: {
            HStack(spacing: 4) {
                if let on { Image(systemName: on ? "checkmark.square" : "square") }
                Text(title)
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .tint(style.page == id ? .accentColor : .secondary)
        .id(id)
        .accessibilityIdentifier("style.page.\(title)")
    }
}

/// Fill Opacity, Transparency Shapes Layer and Blend If (Gray or one colour channel), with Photoshop's names.
struct BlendingOptionsPage: View {
    @ObservedObject var style: LayerStyleState

    @State private var channel = "gray"

    private func num(_ k: String) -> Double { (style.blending[k] as? NSNumber)?.doubleValue ?? 100 }

    var body: some View {
        Form {
            Section("General Blending") {
                Picker("Blend Mode", selection: Binding(get: { style.blending["blend"] as? String ?? "Normal" }, set: { style.setBlending("blend", $0) })) {
                    ForEach(blendModes, id: \.self) { section in
                        Section { ForEach(section, id: \.self) { Text($0).tag($0) } }
                    }
                }
                .accessibilityIdentifier("style.blend")
                StyleSlider(title: "Opacity", value: num("opacity"), range: 0...100, unit: "%", id: "style.opacity") { style.setBlending("opacity", $0) }
                StyleSlider(title: "Fill Opacity", value: num("fillOpacity"), range: 0...100, unit: "%", id: "style.fillOpacity") { style.setBlending("fillOpacity", $0) }
            }
            Section("Advanced Blending") {
                Toggle("Transparency Shapes Layer", isOn: Binding(get: { style.blending["transparencyShapesLayer"] as? Bool ?? true },
                                                                 set: { style.setBlending("transparencyShapesLayer", $0) }))
                    .accessibilityIdentifier("style.transparencyShapesLayer")
            }
            Section {
                Picker("Blend If", selection: $channel) {
                    ForEach(style.blendIfChannels.compactMap { $0["channel"] as? String }, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .accessibilityIdentifier("style.blendIf.channel")
                bar("This Layer", "thisLayer")
                bar("Underlying Layer", "underlying")
            } header: {
                Text("Blend If")
            } footer: {
                Text("Drag a slider to fade this layer out where it, or what's under it, is dark or bright. Turn on Split to move each half of a slider on its own, for a smooth fade.")
            }
        }
    }

    private func bar(_ title: String, _ key: String) -> some View {
        BlendIfBar(title: title, values: style.blendIfRange(channel, key), id: "style.blendIf.\(key)") { v in
            style.setBlendIf(channel, key, v)
        }
    }
}

/// A Blend If slider: black and white handles, each of which splits in two for a smooth fade.
struct BlendIfBar: View {
    let title: String
    /// [black low, black high, white low, white high], 0–255.
    let values: [Double]
    let id: String
    let set: ([Double]) -> Void
    @State private var split = false
    @State private var dragging: (handles: [Int], start: [Double])?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(label).font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityIdentifier("\(id).value")
                Toggle("Split", isOn: $split).labelsHidden().accessibilityIdentifier("\(id).split")
                Text("Split").font(.caption)
            }
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .topLeading) {
                    LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                        .frame(height: 14).clipShape(RoundedRectangle(cornerRadius: 3))
                    ForEach(0..<4, id: \.self) { i in
                        Image(systemName: "triangle.fill").font(.system(size: 12))
                            .foregroundStyle(i < 2 ? Color.black : .white)
                            .shadow(color: .gray, radius: 1)
                            .position(x: values[i] / 255 * w, y: 22)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in drag(d, width: w) }.onEnded { _ in dragging = nil })
            }
            .frame(height: 30)
            .accessibilityElement()
            .accessibilityIdentifier(id)
        }
    }

    /// The handles a drag from `at` (0–255) moves: the nearest pair, or with Split the nearest
    /// half. Halves on the same spot go by the drag's direction (`nil` until it has one).
    static func handles(_ values: [Double], at: Double, split: Bool, dx: Double) -> [Int]? {
        let near = (0..<4).min { abs(values[$0] - at) < abs(values[$1] - at) } ?? 0
        guard split else { return near < 2 ? [0, 1] : [2, 3] }
        let twin = near ^ 1
        guard values[twin] == values[near] else { return [near] }
        guard dx != 0 else { return nil }
        return [dx > 0 ? max(near, twin) : min(near, twin)]
    }

    private var label: String {
        let v = values.map { Int($0) }
        let black = v[0] == v[1] ? "\(v[0])" : "\(v[0])/\(v[1])"
        let white = v[2] == v[3] ? "\(v[2])" : "\(v[2])/\(v[3])"
        return "\(black)  \(white)"
    }

    private func drag(_ d: DragGesture.Value, width: Double) {
        guard width > 0 else { return }
        if dragging == nil {
            guard let h = Self.handles(values, at: d.startLocation.x / width * 255, split: split, dx: d.translation.width) else { return }
            dragging = (h, values)
        }
        guard let (handles, start) = dragging, let a = handles.first, let b = handles.last else { return }
        // Handles keep their order and stay on the bar.
        let lo = (a > 0 ? start[a - 1] : 0) - start[a], hi = (b < 3 ? start[b + 1] : 255) - start[b]
        let delta = min(max(d.translation.width / width * 255, lo), hi)
        var v = start
        for i in handles { v[i] = start[i] + delta }
        set(v)
    }
}

/// An effect's settings, with Photoshop's names.
struct EffectPage: View {
    @ObservedObject var style: LayerStyleState
    let effect: StyleEffect

    private enum Field {
        case slider(ClosedRange<Double>, String)
        case toggle
        case color
        case blend
        case choice([String])
    }

    private var fields: [(key: String, label: String, field: Field)] {
        let bevel = effect.kind == "bevelEmboss"
        return [
            ("style", "Style", .choice(bevel ? ["inner", "outer", "emboss", "pillow", "stroke"] : ["linear", "radial", "angle", "reflected", "diamond"])),
            ("technique", "Technique", .choice(bevel ? ["smooth", "chiselHard", "chiselSoft"] : ["softer", "precise"])),
            ("depth", "Depth", .slider(1...1000, "%")),
            ("direction", "Direction", .choice(["up", "down"])),
            ("position", "Position", .choice(["outside", "inside", "center"])),
            ("source", "Source", .choice(["edge", "center"])),
            ("blend", "Blend Mode", .blend),
            ("color", "Color", .color),
            ("from", "From", .color),
            ("to", "To", .color),
            ("opacity", "Opacity", .slider(0...100, "%")),
            ("angle", "Angle", .slider(-180...180, "°")),
            ("useGlobalLight", "Use Global Light", .toggle),
            ("altitude", "Altitude", .slider(0...90, "°")),
            ("distance", "Distance", .slider(0...300, "px")),
            ("spread", "Spread", .slider(0...100, "%")),
            ("choke", "Choke", .slider(0...100, "%")),
            ("size", "Size", .slider(0...250, "px")),
            ("soften", "Soften", .slider(0...16, "px")),
            ("range", "Range", .slider(1...100, "%")),
            ("noise", "Noise", .slider(0...100, "%")),
            ("scale", "Scale", .slider(effect.kind == "gradientOverlay" ? 10...150 : 1...1000, "%")),
            ("reverse", "Reverse", .toggle),
            ("invert", "Invert", .toggle),
            ("knocksOut", "Layer Knocks Out Drop Shadow", .toggle),
        ].filter { effect.params[$0.0] != nil }
    }

    var body: some View {
        Form {
            Section {
                Toggle(LayerStyle.label(effect.kind), isOn: Binding(get: { effect.enabled }, set: { style.set(effect.id, enabled: $0) }))
                    .accessibilityIdentifier("style.enabled")
                ForEach(fields, id: \.key) { f in row(f.key, f.label, f.field) }
            } footer: {
                if ["dropShadow", "innerShadow"].contains(effect.kind) { Text("Drag in the image to move the shadow.") }
            }
            Section {
                if LayerStyle.kinds.first(where: { $0.kind == effect.kind })?.many == true {
                    Button { style.add(effect.kind) } label: { Label("Add Another \(LayerStyle.label(effect.kind))", systemImage: "plus.square.on.square") }
                        .accessibilityIdentifier("style.duplicate")
                }
                Button(role: .destructive) { style.delete(effect.id) } label: { Label("Delete Effect", systemImage: "trash") }
                    .accessibilityIdentifier("style.delete")
            }
        }
    }

    @ViewBuilder
    private func row(_ key: String, _ label: String, _ field: Field) -> some View {
        let id = "style.\(key)"
        switch field {
        case let .slider(range, unit):
            StyleSlider(title: label, value: (effect.params[key] as? NSNumber)?.doubleValue ?? 0, range: range, unit: unit, id: id) { style.set(effect.id, key, $0) }
        case .toggle:
            Toggle(label, isOn: Binding(get: { effect.params[key] as? Bool ?? false }, set: { style.set(effect.id, key, $0) }))
                .accessibilityIdentifier(id)
        case .color:
            let hex = effect.params[key] as? String ?? "#000000"
            Button {
                SystemColorPicker.present(title: label, rgb: Self.rgb(hex)) { rgb in
                    style.set(effect.id, key, String(format: "#%02x%02x%02x", Int(rgb[0] * 255), Int(rgb[1] * 255), Int(rgb[2] * 255)))
                }
            } label: {
                HStack {
                    Text(label).foregroundStyle(.primary)
                    Spacer()
                    RoundedRectangle(cornerRadius: 4).fill(Color(hex: hex)).frame(width: 36, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
                }
            }
            .accessibilityIdentifier(id)
        case .blend:
            Picker(label, selection: Binding(get: { effect.params[key] as? String ?? "Normal" }, set: { style.set(effect.id, key, $0) })) {
                ForEach(blendModes, id: \.self) { section in
                    Section { ForEach(section, id: \.self) { Text($0).tag($0) } }
                }
                // The engine names some modes in lower case.
                let v = effect.params[key] as? String ?? ""
                if !blendModes.joined().contains(v) { Text(v.capitalized).tag(v) }
            }
            .accessibilityIdentifier(id)
        case let .choice(options):
            Picker(label, selection: Binding(get: { effect.params[key] as? String ?? options[0] }, set: { style.set(effect.id, key, $0) })) {
                ForEach(options, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            .accessibilityIdentifier(id)
        }
    }

    static func rgb(_ hex: String) -> [Float] {
        guard let n = UInt32(hex.dropFirst(), radix: 16), hex.count == 7 else { return [] }
        return [Float(n >> 16 & 255) / 255, Float(n >> 8 & 255) / 255, Float(n & 255) / 255]
    }

    /// `chiselHard` → "Chisel Hard".
    static func title(_ s: String) -> String {
        s.reduce(into: "") { out, c in out += c.isUppercase ? " \(c)" : String(c) }.capitalized
    }
}

/// A labelled slider with a field to type its value, as in Photoshop's dialogs.
struct StyleSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let unit: String
    let id: String
    let set: (Double) -> Void
    @State private var text = ""
    @State private var dragged: Double?
    @FocusState private var typing: Bool

    var body: some View {
        HStack {
            Text(title).lineLimit(1).minimumScaleFactor(0.8).frame(width: scaled(92), alignment: .leading)
            // Applied when let go; the field follows the drag.
            Slider(value: Binding(get: { dragged ?? value }, set: { dragged = $0.rounded(); text = "\(Int($0.rounded()))" }), in: range) { editing in
                if !editing, let d = dragged {
                    set(d)
                    dragged = nil
                }
            }
            .accessibilityIdentifier(id)
            TextField("", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: scaled(52))
                .focused($typing)
                .onSubmit { if let v = Double(text) { set(min(max(v.rounded(), range.lowerBound), range.upperBound)) } }
                .accessibilityIdentifier("\(id).value")
            Text(unit).foregroundStyle(.secondary).lineLimit(1).frame(width: scaled(22), alignment: .leading)
        }
        .onAppear { text = "\(Int(value.rounded()))" }
        .onChange(of: value) { _, v in if !typing { text = "\(Int(v.rounded()))" } }
        .onChange(of: typing) { _, t in
            // Leaving the field enters what's typed.
            if !t, let v = Double(text), v.rounded() != value.rounded() { set(min(max(v.rounded(), range.lowerBound), range.upperBound)) }
            if !t { text = "\(Int(value.rounded()))" }
        }
    }
}
