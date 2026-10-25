import SwiftUI

/// A layer's Properties, as Photoshop shows them for adjustment, fill and shape layers, and a
/// smart filter's settings. Changes apply as you make them (one undo step per sheet).
struct LayerPropertiesSheet: View {
    @ObservedObject var model: EditorModel
    let edit: LayerEdit

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Over the Layers sheet, the image is covered on any device.
                PreviewPane(model: model)
                LayerPropertiesContent(model: model, edit: edit, inPanel: false)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { DoneButton() } }
        }
    }
}

struct LayerPropertiesContent: View {
    @ObservedObject var model: EditorModel
    let edit: LayerEdit
    /// In Window › Properties (the canvas takes touches beside it), not a sheet over Layers.
    let inPanel: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var width
    @State private var key = UUID().uuidString
    /// Bumped by Reset, so the settings start again from the layer's.
    @State private var resets = 0

    private var row: LayerRow? { model.layers.first { $0.id == edit.layer } }

    var body: some View {
        if let row {
            content(row)
                .id(resets)
                .safeAreaInset(edge: .bottom) { if case .layer = edit.part, row.adjustment != nil || row.kind == "Fill" { footer(row) } }
                .onAppear { if case .smartFilter = edit.part { model.liveBegin() } }
                .onDisappear { if case .smartFilter = edit.part { model.liveKeep() } }
        } else {
            Text("The layer is gone").foregroundStyle(.secondary)
        }
    }

    /// Photoshop's buttons under Properties: clip to the layer below, reset, visibility.
    private func footer(_ row: LayerRow) -> some View {
        HStack(spacing: 28) {
            Button { model.toggleClip(row.id) } label: {
                Image(systemName: "arrow.turn.left.down").foregroundStyle(row.clipped ? Color.accentColor : Color.primary)
            }
                .accessibilityLabel(row.clipped ? "Release Clipping Mask" : "Clip to Layer Below")
                .accessibilityValue(row.clipped ? "clipped" : "")
                .accessibilityIdentifier("properties.clip")
            if row.adjustment != nil {
                Button {
                    model.run("layer.setAdjustment", ["layer": row.id])
                    resets += 1
                } label: { Image(systemName: "arrow.counterclockwise") }
                .accessibilityLabel("Reset to Defaults")
                .accessibilityIdentifier("properties.reset")
            }
            Button { model.run("layer.setProps", ["layer": row.id, "visible": !row.visible]) } label: { Image(systemName: row.visible ? "eye" : "eye.slash") }
                .accessibilityLabel("Visibility")
                .accessibilityIdentifier("properties.visible")
        }
        .font(.title3)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func content(_ row: LayerRow) -> some View {
        switch edit.part {
        case .mask:
            MaskProperties(model: model, layer: row.id)
        case let .filterBlending(i):
            if let f = row.smartFilters.first(where: { $0.index == i }) {
                FilterBlending(model: model, layer: row.id, filter: f)
            }
        case let .smartFilter(i):
            if let f = row.smartFilters.first(where: { $0.index == i }), f.command == "filter.cameraRaw" {
                CameraRawView(model: model, initial: f.params, change: { p in
                    model.live("layer.smartFilter.setParams", ["layer": row.id, "index": i, "params": p])
                }, cancel: { model.liveCancel() }) { p in
                    model.liveFinish("layer.smartFilter.setParams", ["layer": row.id, "index": i, "params": p])
                }
            } else if let f = row.smartFilters.first(where: { $0.index == i }) {
                CommandSettings(title: f.name, fields: model.editor.commandFields(id: f.command), initial: f.params, runTitle: "OK", change: { p in
                    model.live("layer.smartFilter.setParams", ["layer": row.id, "index": i, "params": p])
                }) { p in
                    model.liveFinish("layer.smartFilter.setParams", ["layer": row.id, "index": i, "params": p])
                    dismiss()
                }
            }
        case .layer:
            if let a = row.adjustment, AdjustmentEditor.kinds.contains(a.kind) {
                AdjustmentEditor(model: model, kind: a.kind, layer: row.id, initial: a.params, surface: inPanel && width == .regular ? .canvas : .preview, runTitle: "", inPanel: inPanel, key: key,
                                 change: { p in model.run("layer.setAdjustment", p.merging(["layer": row.id, "coalesce": key]) { a, _ in a }) },
                                 run: { _ in dismiss() })
            } else if let a = row.adjustment {
                CommandSettings(title: AdjustmentKinds.label(a.kind), fields: fields(a.kind), initial: a.params, change: { p in
                    model.run("layer.setAdjustment", p.merging(["layer": row.id, "coalesce": key]) { a, _ in a })
                }) { _ in dismiss() }
            } else if row.kind == "Fill" {
                FillProperties(model: model, layer: row.id, inPanel: inPanel)
            } else if row.kind == "Shape" {
                ShapeProperties(model: model, layer: row.id)
            } else {
                Form { Text("\(row.kind) layer “\(row.name)” has no properties to set here.").foregroundStyle(.secondary) }
                    .navigationTitle("Properties")
            }
        }
    }

    /// An adjustment's settings: those its New Adjustment Layer command takes.
    private func fields(_ kind: String) -> [ParamField] {
        model.editor.commandFields(id: "layer.newAdjustmentLayer.\(kind)")
    }
}

/// A Solid Color or Gradient fill layer: its colour, or its gradient (a preset, or your own stops).
struct FillProperties: View {
    @ObservedObject var model: EditorModel
    let layer: UInt64
    let inPanel: Bool
    @Environment(\.horizontalSizeClass) private var width
    @State private var gradient: [String: Any]?
    /// A drag's starting handles.
    @State private var dragFrom: [[Double]]?
    @State private var presets: [GradientPreset] = []
    @State private var key = UUID().uuidString

    private var stops: [[Any]] { gradient?["stops"] as? [[Any]] ?? [] }
    /// Opacity stops; a gradient without any is opaque from end to end.
    private var transparency: [[Double]] {
        let t = (gradient?["transparency"] as? [[NSNumber]])?.map { $0.map(\.doubleValue) } ?? []
        return t.isEmpty ? [[0, 100], [1, 100]] : t
    }

    var body: some View {
        Form {
            if let g = gradient {
                Section("Gradient") {
                    GradientSwatch(stops: stops).frame(height: 28).accessibilityIdentifier("fill.swatch")
                    Picker("Style", selection: Binding(get: { g["style"] as? String ?? "linear" }, set: { set(["style": $0]) })) {
                        ForEach(["linear", "radial", "angle", "reflected", "diamond"], id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .accessibilityIdentifier("fill.style")
                    HStack {
                        Text("Angle")
                        Slider(value: Binding(get: { (g["angle"] as? NSNumber)?.doubleValue ?? 90 }, set: { set(["angle": $0.rounded()]) }), in: -180...180)
                        Text("\(Int((g["angle"] as? NSNumber)?.doubleValue ?? 90))°").monospacedDigit().lineLimit(1).frame(width: scaled(52))
                    }
                    HStack {
                        Text("Scale")
                        Slider(value: Binding(get: { (g["scale"] as? NSNumber)?.doubleValue ?? 100 }, set: { set(["scale": $0.rounded()]) }), in: 10...150)
                            .accessibilityIdentifier("fill.scale")
                        Text("\(Int((g["scale"] as? NSNumber)?.doubleValue ?? 100))%").monospacedDigit().lineLimit(1).frame(width: scaled(52))
                    }
                    Toggle("Reverse", isOn: Binding(get: { g["reverse"] as? Bool ?? false }, set: { set(["reverse": $0]) }))
                        .accessibilityIdentifier("fill.reverse")
                    if inPanel {
                        Text("Drag in the image to move the gradient.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        // Dragging in the image needs the canvas: Properties lets it take touches.
                        Button("Move It in the Image") { model.request = .panel(.properties) }.accessibilityIdentifier("fill.move")
                    }
                }
                GradientStopsSections(stops: stops, presets: presets, id: "fill") { set(["stops": $0]) }
                Section {
                    ForEach(Array(transparency.enumerated()), id: \.offset) { i, t in
                        StyleSlider(title: "Opacity", value: t.count > 1 ? t[1] : 100, range: 0...100, unit: "%", id: "fill.opacity.\(i)") { setOpacity(i, at: nil, $0) }
                        StyleSlider(title: "Location", value: (t.first ?? 0) * 100, range: 0...100, unit: "%", id: "fill.opacityAt.\(i)") { setOpacity(i, at: $0 / 100, nil) }
                    }
                } header: {
                    Text("Opacity Stops")
                } footer: {
                    Text("Each stop's opacity, and where it is along the gradient.")
                }
            } else {
                Section {
                    Button("Pick Color…") {
                        SystemColorPicker.present(title: "Color Fill", rgb: []) { rgb in
                            model.run("layer.fill.solidColor.set", ["layer": layer, "color": rgb + [1], "coalesce": key])
                        }
                    }
                    .accessibilityIdentifier("fill.color")
                    Button {
                        // Over the Layers sheet the preview takes the pick; beside the iPad canvas, the canvas.
                        model.beginPick(inPanel && width == .regular ? .canvas : .preview, prompt: "Tap the color to fill with") { model.setFillColor(layer, from: $0) }
                    } label: { Label("Pick from Image", systemImage: "eyedropper") }
                    .accessibilityIdentifier("fill.pick")
                } header: {
                    Text("Color")
                } footer: {
                    Text("Pick from Image samples as the Eyedropper's Sample Size and Sample are set.")
                }
            }
        }
        .navigationTitle(gradient == nil ? "Color Fill" : "Gradient Fill")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onDisappear { model.sheetDrag = nil }
    }

    /// Beside the canvas, dragging in the image moves the gradient, as in Photoshop.
    private func takeDrags() {
        guard inPanel, gradient != nil else { return }
        model.sheetDrag = SheetDrag { began, from, to in
            let h = { (k: String) in (gradient?[k] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0] }
            if began { dragFrom = [h("from"), h("to")] }
            guard let f = dragFrom, f.allSatisfy({ $0.count == 2 }) else { return }
            let dx = Double(to.x - from.x), dy = Double(to.y - from.y)
            set(["from": [f[0][0] + dx, f[0][1] + dy], "to": [f[1][0] + dx, f[1][1] + dy]])
        }
    }

    private func setOpacity(_ i: Int, at t: Double?, _ opacity: Double?) {
        var list = transparency
        guard list.indices.contains(i), list[i].count > 1 else { return }
        if let t { list[i][0] = t }
        if let opacity { list[i][1] = opacity }
        set(["transparency": list])
    }

    private func load() {
        gradient = model.query("gradient.fill.get", ["layer": layer]) as? [String: Any]
        takeDrags()
        if gradient != nil { presets = GradientPreset.load(model) }
    }

    private func set(_ p: [String: Any]) {
        if let out = model.run("gradient.fill.set", p.merging(["layer": layer, "coalesce": key]) { a, _ in a }) as? [String: Any] { gradient = out }
    }
}

/// A shape layer's fill colour and, for rectangles, its corner radius.
struct ShapeProperties: View {
    @ObservedObject var model: EditorModel
    let layer: UInt64
    @State private var info: [String: Any] = [:]
    @State private var radius: Double = 0
    @State private var key = UUID().uuidString

    private var live: [String: Any]? { info["live"] as? [String: Any] }
    private var isRect: Bool { ["rect", "roundedRect"].contains(live?["kind"] as? String ?? "") }

    var body: some View {
        Form {
            Section("Fill") {
                Button("Pick Color…") {
                    SystemColorPicker.present(title: "Shape Fill", rgb: []) { rgb in
                        model.run("shape.edit", ["layer": layer, "fill": rgb + [1], "coalesce": key])
                    }
                }
                .accessibilityIdentifier("shape.fill")
            }
            if isRect {
                Section("Corners") {
                    HStack {
                        Slider(value: Binding(get: { radius }, set: { r in
                            radius = r.rounded()
                            model.run("shape.edit", ["layer": layer, "kind": "roundedRect", "radii": radius, "coalesce": key])
                        }), in: 0...maxRadius)
                        .accessibilityIdentifier("shape.radius")
                        Text("\(Int(radius)) px").monospacedDigit().lineLimit(1).frame(width: scaled(72))
                    }
                }
            }
        }
        .navigationTitle("Shape")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            info = model.query("shape.info", ["layer": layer]) as? [String: Any] ?? [:]
            let r = live?["radii"]
            radius = (r as? NSNumber)?.doubleValue ?? ((r as? [NSNumber])?.first?.doubleValue ?? 0)
        }
    }

    private var maxRadius: Double {
        let b = (info["bounds"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 200, 200]
        return max(1, min(b.count == 4 ? min(b[2], b[3]) / 2 : 100, 2000))
    }
}

/// A gradient's colour stops as a bar.
struct GradientSwatch: View {
    let stops: [[Any]]

    var body: some View {
        let s = stops.compactMap { st -> Gradient.Stop? in
            guard let t = (st.first as? NSNumber)?.doubleValue, let c = st.last as? String, c.hasPrefix("#") else { return nil }
            return Gradient.Stop(color: Color(hex: c), location: t)
        }
        LinearGradient(stops: s.isEmpty ? [.init(color: .black, location: 0), .init(color: .white, location: 1)] : s, startPoint: .leading, endPoint: .trailing)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

extension Color {
    /// `#rrggbb` (or `#rrggbbaa`).
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(h.prefix(6), radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

/// Hue/Saturation's Properties: Master or one colour range, its sliders and its range, and the
/// targeted adjustment (drag in the image: sideways changes the saturation, or the hue, of the
/// colours under your finger).
struct HueSaturationProperties: View {
    @ObservedObject var model: EditorModel
    /// An adjustment layer; `nil` for Image › Adjustments › Hue/Saturation (kept here, applied
    /// through `change`).
    let layer: UInt64?
    let key: String
    let inPanel: Bool
    var initial: [String: Any] = [:]
    var runTitle = "Done"
    var change: ([String: Any]) -> Void = { _ in }
    var run: ([String: Any]) -> Void = { _ in }
    @State private var part = "master"
    @State private var local: [String: Any] = [:]

    static let ranges = ["reds", "yellows", "greens", "cyans", "blues", "magentas"]

    private var params: [String: Any] {
        guard let layer else { return local }
        return model.layers.first { $0.id == layer }?.adjustment?.params ?? [:]
    }
    private var current: [String: Any] { part == "master" ? params : params[part] as? [String: Any] ?? [:] }
    private func value(_ k: String) -> Double { (current[k] as? NSNumber)?.doubleValue ?? 0 }

    var body: some View {
        EditorForm(title: "Hue/Saturation", runTitle: runTitle, run: { run(params) }) {
            Section {
                Picker("Edit", selection: $part) {
                    Text("Master").tag("master")
                    ForEach(Self.ranges, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .accessibilityIdentifier("hs.part")
                if let layer {
                    Toggle("Drag in the image to adjust", isOn: Binding(get: { model.targetedAdjust?.layer == layer }, set: { on in
                        model.targetedAdjust = on ? TargetedAdjust(layer: layer, key: key, hue: model.targetedAdjust?.hue ?? false) : nil
                        // Dragging in the image needs the canvas: Properties lets it take touches.
                        if on, !inPanel { model.request = .panel(.properties) }
                    }))
                    .accessibilityIdentifier("hs.targeted")
                    if model.targetedAdjust?.layer == layer {
                        Picker("Dragging changes", selection: Binding(get: { model.targetedAdjust?.hue ?? false }, set: { model.targetedAdjust?.hue = $0 })) {
                            Text("Saturation").tag(false)
                            Text("Hue").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("hs.dragHue")
                    }
                }
            }
            Section {
                slider("Hue", "hue", -180...180)
                slider("Saturation", "saturation", -100...100)
                slider("Lightness", "lightness", -100...100)
                if part == "master" {
                    Toggle("Colorize", isOn: Binding(get: { params["colorize"] as? Bool ?? false }, set: { set(["colorize": $0]) }))
                        .accessibilityIdentifier("hs.colorize")
                }
            }
            if part != "master", let r = current["range"] as? [NSNumber], r.count == 4 {
                Section("Range") {
                    ForEach(0..<4, id: \.self) { i in
                        HStack {
                            Text(["Fade from", "From", "To", "Fade to"][i]).lineLimit(1).minimumScaleFactor(0.8).frame(width: scaled(84), alignment: .leading)
                            Slider(value: Binding(get: { r[i].doubleValue }, set: { v in
                                var range = r.map(\.doubleValue)
                                range[i] = v.rounded()
                                // Keep them in order.
                                for j in 0..<4 where j != i { range[j] = j < i ? min(range[j], range[i]) : max(range[j], range[i]) }
                                setPart(["range": range])
                            }), in: -90...450)
                            .accessibilityIdentifier("hs.range.\(i)")
                            Text("\(r[i].intValue)°").monospacedDigit().lineLimit(1).frame(width: scaled(52))
                        }
                    }
                }
            }
        }
        .onAppear {
            guard layer == nil, local.isEmpty else { return }
            local = initial
            for (i, r) in Self.ranges.enumerated() where local[r] == nil {
                // The engine's default span: 30° around the colour, fading over 30° each side.
                let c = Double(i * 60)
                local[r] = ["range": [c - 45, c - 15, c + 15, c + 45]]
            }
        }
    }

    private func slider(_ title: String, _ k: String, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                ValueLabel(text: "\(Int(value(k)))", width: 44, font: .body)
            }
            Slider(value: Binding(get: { value(k) }, set: { v in part == "master" ? set([k: v.rounded()]) : setPart([k: v.rounded()]) }), in: range)
                .accessibilityIdentifier("hs.\(k)")
        }
    }

    private func set(_ p: [String: Any]) {
        if let layer {
            model.run("layer.setAdjustment", p.merging(["layer": layer, "coalesce": key]) { a, _ in a })
        } else {
            local.merge(p) { _, b in b }
            change(local)
        }
    }

    private func setPart(_ p: [String: Any]) {
        set([part: current.merging(p) { _, b in b }])
    }
}

/// Hue/Saturation's targeted adjustment while its Properties are open.
struct TargetedAdjust: Equatable {
    let layer: UInt64
    let key: String
    var hue: Bool
}
