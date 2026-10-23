import SwiftUI

/// Commands with a screen of their own beyond the plain settings form: blur and light handles on
/// the preview, Shear's curve, Displace's map, Color Range, Duotone, Color Table and the Filter
/// Gallery.
struct CommandEditor: View {
    @ObservedObject var model: EditorModel
    let command: CommandInfo
    /// Where eyedroppers pick.
    var surface = PickSurface.preview
    /// Applies each change (a live preview); `nil` when the command only runs on OK.
    let change: (([String: Any]) -> Void)?
    let run: ([String: Any]) -> Void

    static let handled: Set<String> = [
        "filter.blurGallery.irisBlur", "filter.blurGallery.spinBlur", "filter.blurGallery.pathBlur", "filter.blurGallery.tiltShift",
        "filter.render.lightingEffects", "filter.distort.shear", "filter.distort.displace", "select.colorRange",
        "image.mode.duotone", "image.mode.colorTable", "filter.filterGallery",
    ]

    /// Screens that show the image themselves (with handles, or the selection).
    static let ownPreview: Set<String> = [
        "filter.blurGallery.irisBlur", "filter.blurGallery.spinBlur", "filter.blurGallery.pathBlur", "filter.blurGallery.tiltShift",
        "filter.render.lightingEffects", "select.colorRange",
    ]

    private var title: String { command.label.replacingOccurrences(of: "…", with: "") }

    var body: some View {
        switch command.id {
        case "filter.distort.shear": ShearEditor(change: change ?? { _ in }, run: run)
        case "filter.distort.displace": DisplaceEditor(model: model, command: command, change: change, run: run)
        case "select.colorRange": ColorRangeEditor(model: model, surface: surface, change: change ?? { _ in }, run: run)
        case "image.mode.duotone": DuotoneEditor(model: model, run: run)
        case "image.mode.colorTable": ColorTableEditor(model: model, run: run)
        case "filter.filterGallery": FilterGalleryEditor(model: model, change: change ?? { _ in }, run: run)
        default:
            if let kind = PreviewHandles.Kind(command.id) {
                HandlesEditor(model: model, command: command, kind: kind, change: change, run: run)
            }
        }
    }
}

// MARK: - Handles on the preview

/// A blur or light filter: its centre, radii or ends dragged on the preview; the rest in a form.
struct HandlesEditor: View {
    @ObservedObject var model: EditorModel
    let command: CommandInfo
    let kind: PreviewHandles.Kind
    let change: (([String: Any]) -> Void)?
    let run: ([String: Any]) -> Void
    @State private var handles: [String: Double] = [:]
    @State private var last: [String: Any] = [:]

    var body: some View {
        let fields = model.editor.commandFields(id: command.id)
        VStack(spacing: 0) {
            PreviewPane(model: model, overlay: { rect in
                AnyView(PreviewHandles(kind: kind, values: $handles, params: last, rect: rect) { change?(last.merging(handles) { _, b in b }) })
            })
            CommandSettings(title: command.label.replacingOccurrences(of: "…", with: ""), fields: fields.filter { !kind.keys.contains($0.name) },
                            initial: model.startingValues(fields), runTitle: "OK",
                            change: { p in last = p; change?(p) }, changeOnAppear: change != nil, extra: handles, run: run)
        }
        .onAppear {
            guard handles.isEmpty else { return }
            for f in fields where kind.keys.contains(f.name) {
                if case let .number(_, _, value, _) = f.kind { handles[f.name] = value }
            }
        }
    }
}

/// Handles over the preview for a filter's centre, radii, ends or light. Values are fractions of
/// the image (radii of its shorter side), as the filters take them.
struct PreviewHandles: View {
    enum Kind {
        case iris, spin, path, tiltShift, light

        init?(_ id: String) {
            switch id {
            case "filter.blurGallery.irisBlur": self = .iris
            case "filter.blurGallery.spinBlur": self = .spin
            case "filter.blurGallery.pathBlur": self = .path
            case "filter.blurGallery.tiltShift": self = .tiltShift
            case "filter.render.lightingEffects": self = .light
            default: return nil
            }
        }

        var keys: Set<String> {
            switch self {
            case .iris, .spin: ["centerX", "centerY", "radiusX", "radiusY"]
            case .path: ["startX", "startY", "endX", "endY"]
            case .tiltShift: ["centerX", "centerY"]
            case .light: ["lightX", "lightY", "targetX", "targetY"]
            }
        }
    }

    let kind: Kind
    @Binding var values: [String: Double]
    /// The form's settings (angle, focus…), for drawing.
    let params: [String: Any]
    let rect: CGRect
    let ended: () -> Void

    private var ss: CGFloat { min(rect.width, rect.height) }
    private func v(_ k: String, _ d: Double = 0.5) -> Double { values[k] ?? d }
    private func point(_ x: String, _ y: String) -> CGPoint { CGPoint(x: rect.minX + v(x) * rect.width, y: rect.minY + v(y) * rect.height) }
    private var angle: Double { (number(params["angle"]) ?? 0) * .pi / 180 }

    var body: some View {
        ZStack {
            Canvas { ctx, _ in draw(ctx) }.allowsHitTesting(false)
            switch kind {
            case .iris, .spin:
                let c = point("centerX", "centerY")
                let (s, co) = (CGFloat(sin(angle)), CGFloat(cos(angle)))
                let rx = v("radiusX", 0.3) * ss, ry = v("radiusY", 0.3) * ss
                handle("centerX", "centerY", at: c)
                handle(at: CGPoint(x: c.x + rx * co, y: c.y + rx * s), id: "handle.radiusX") { p in
                    values["radiusX"] = Self.clamp(abs((p.x - c.x) * co + (p.y - c.y) * s) / ss, 0.01, 1)
                }
                handle(at: CGPoint(x: c.x + ry * s, y: c.y - ry * co), id: "handle.radiusY") { p in
                    values["radiusY"] = Self.clamp(abs(-(p.x - c.x) * s + (p.y - c.y) * co) / ss, 0.01, 1)
                }
            case .path:
                handle("startX", "startY", at: point("startX", "startY"))
                handle("endX", "endY", at: point("endX", "endY"))
            case .tiltShift:
                handle("centerX", "centerY", at: point("centerX", "centerY"))
            case .light:
                handle("lightX", "lightY", at: point("lightX", "lightY"), fill: .yellow)
                handle("targetX", "targetY", at: point("targetX", "targetY"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "handles")
    }

    static func clamp(_ x: CGFloat, _ lo: Double, _ hi: Double) -> Double { min(max(Double(x), lo), hi) }

    private func handle(_ x: String, _ y: String, at p: CGPoint, fill: Color = .white) -> some View {
        handle(at: p, id: "handle.\(x)", fill: fill) { q in
            values[x] = Self.clamp((q.x - rect.minX) / max(rect.width, 1), 0, 1)
            values[y] = Self.clamp((q.y - rect.minY) / max(rect.height, 1), 0, 1)
        }
    }

    private func handle(at p: CGPoint, id: String, fill: Color = .white, moved: @escaping (CGPoint) -> Void) -> some View {
        Circle().fill(fill.opacity(0.85)).overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
            .frame(width: 18, height: 18)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(p)
            .gesture(DragGesture(coordinateSpace: .named("handles")).onChanged { moved($0.location) }.onEnded { _ in ended() })
            .accessibilityElement()
            .accessibilityIdentifier(id)
    }

    private func draw(_ ctx: GraphicsContext) {
        let line = GraphicsContext.Shading.color(.white.opacity(0.9))
        switch kind {
        case .iris, .spin:
            let c = point("centerX", "centerY")
            let rx = v("radiusX", 0.3) * ss, ry = v("radiusY", 0.3) * ss
            let e = Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
                .applying(CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
            ctx.stroke(e, with: line, lineWidth: 1.5)
        case .path:
            let a = point("startX", "startY"), b = point("endX", "endY")
            ctx.stroke(Path { p in p.move(to: a); p.addLine(to: b) }, with: line, lineWidth: 2)
        case .tiltShift:
            let c = point("centerX", "centerY")
            // The band runs along the angle; its normal is (sin, cos) as the filter measures it.
            let n = CGPoint(x: sin(angle), y: cos(angle)), d = CGPoint(x: n.y, y: -n.x)
            let len = rect.width + rect.height
            let focus = (number(params["focus"]) ?? 0.1) * ss, edge = focus + (number(params["transition"]) ?? 0.15) * ss
            for (off, dashed) in [(focus, false), (-focus, false), (edge, true), (-edge, true)] {
                let o = CGPoint(x: c.x + n.x * off, y: c.y + n.y * off)
                let path = Path { p in
                    p.move(to: CGPoint(x: o.x - d.x * len, y: o.y - d.y * len))
                    p.addLine(to: CGPoint(x: o.x + d.x * len, y: o.y + d.y * len))
                }
                ctx.stroke(path, with: line, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [6, 4] : []))
            }
        case .light:
            let a = point("lightX", "lightY"), b = point("targetX", "targetY")
            ctx.stroke(Path { p in p.move(to: a); p.addLine(to: b) }, with: line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
    }
}

// MARK: - Shear

/// Filter › Distort › Shear: bend the vertical line; each row moves by the line's offset.
struct ShearEditor: View {
    let change: ([String: Any]) -> Void
    let run: ([String: Any]) -> Void
    static let straight = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1)]
    /// Points as (offset −1…1 of half the width, position 0…1 down the image).
    @State private var points = straight
    @State private var undefined = "wrap"

    private var params: [String: Any] {
        ["points": points.map { [Double($0.y), Double($0.x)] }, "undefinedAreas": undefined]
    }

    var body: some View {
        EditorForm(title: "Shear", runTitle: "OK", run: { run(params) }) {
            Section {
                ShearGraph(points: $points) { change(params) }
                    .aspectRatio(1, contentMode: .fit)
                Button("Reset") { points = Self.straight; change(params) }
                    .accessibilityIdentifier("shear.reset")
            } footer: {
                Text("Drag the line sideways; tap it to add a point.")
            }
            Picker("Undefined Areas", selection: Binding(get: { undefined }, set: { undefined = $0; change(params) })) {
                Text("Wrap Around").tag("wrap")
                Text("Repeat Edge Pixels").tag("repeat")
            }
            .accessibilityIdentifier("shear.undefined")
        }
        .onAppear { change(params) }
    }

    /// The offset at `t` down the line: the filter's curve (Catmull–Rom through the points).
    static func offset(_ pts: [CGPoint], at t: CGFloat) -> CGFloat {
        let p = pts.sorted { $0.y < $1.y }
        guard let first = p.first, let last = p.last else { return 0 }
        if p.count == 1 || t <= first.y { return first.x }
        if t >= last.y { return last.x }
        let i = (0..<(p.count - 1)).first { t >= p[$0].y && t <= p[$0 + 1].y } ?? 0
        let p1 = p[i], p2 = p[i + 1]
        let p0 = i > 0 ? p[i - 1] : p1, p3 = i + 2 < p.count ? p[i + 2] : p2
        let span = max(p2.y - p1.y, 1e-6), s = (t - p1.y) / span
        let m1 = i > 0 ? (p2.x - p0.x) / max(p2.y - p0.y, 1e-6) * span : p2.x - p1.x
        let m2 = i + 2 < p.count ? (p3.x - p1.x) / max(p3.y - p1.y, 1e-6) * span : p2.x - p1.x
        let (s2, s3) = (s * s, s * s * s)
        return (2 * s3 - 3 * s2 + 1) * p1.x + (s3 - 2 * s2 + s) * m1 + (-2 * s3 + 3 * s2) * p2.x + (s3 - s2) * m2
    }
}

struct ShearGraph: View {
    @Binding var points: [CGPoint]
    let ended: () -> Void
    @State private var dragging: Int?

    var body: some View {
        GeometryReader { g in
            let s = g.size
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.15)))
                let grid = Path { p in
                    for i in 1..<4 {
                        let t = CGFloat(i) / 4
                        p.move(to: CGPoint(x: t * size.width, y: 0)); p.addLine(to: CGPoint(x: t * size.width, y: size.height))
                        p.move(to: CGPoint(x: 0, y: t * size.height)); p.addLine(to: CGPoint(x: size.width, y: t * size.height))
                    }
                }
                ctx.stroke(grid, with: .color(.white.opacity(0.15)))
                let curve = Path { p in
                    for k in 0...100 {
                        let t = CGFloat(k) / 100
                        let pt = CGPoint(x: (ShearEditor.offset(points, at: t) + 1) / 2 * size.width, y: t * size.height)
                        if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                ctx.stroke(curve, with: .color(.white), lineWidth: 2)
                for p in points {
                    let v = view(p, size)
                    ctx.stroke(Path(CGRect(x: v.x - 6, y: v.y - 6, width: 12, height: 12)), with: .color(.white), lineWidth: 1.5)
                }
            }
            .overlay(TouchSurface { start, at in drag(start, at, s) } ended: {
                dragging = nil
                ended()
            })
        }
        .accessibilityElement()
        .accessibilityIdentifier("shear.graph")
    }

    private func drag(_ start: CGPoint, _ location: CGPoint, _ s: CGSize) {
        if dragging == nil {
            let distance = { (i: Int) in hypot(view(points[i], s).x - start.x, view(points[i], s).y - start.y) }
            if let near = points.indices.min(by: { distance($0) < distance($1) }), distance(near) < 28 {
                dragging = near
            } else if points.count < 16 {
                let m = model(start, s)
                points.append(m)
                points.sort { $0.y < $1.y }
                dragging = points.firstIndex(of: m)
            }
        }
        guard let i = dragging, points.indices.contains(i) else { return }
        let m = model(location, s)
        // The ends stay at the top and bottom.
        let lo = i == 0 ? 0 : points[i - 1].y + 0.01, hi = i == points.count - 1 ? 1 : points[i + 1].y - 0.01
        points[i] = CGPoint(x: m.x, y: i == 0 ? 0 : i == points.count - 1 ? 1 : min(max(m.y, lo), hi))
    }

    private func view(_ p: CGPoint, _ s: CGSize) -> CGPoint { CGPoint(x: (p.x + 1) / 2 * s.width, y: p.y * s.height) }
    private func model(_ v: CGPoint, _ s: CGSize) -> CGPoint {
        CGPoint(x: min(max(v.x / max(s.width, 1) * 2 - 1, -1), 1), y: min(max(v.y / max(s.height, 1), 0), 1))
    }
}

// MARK: - Displace

/// Filter › Distort › Displace: the displacement map is one of the open documents.
struct DisplaceEditor: View {
    @ObservedObject var model: EditorModel
    let command: CommandInfo
    let change: (([String: Any]) -> Void)?
    let run: ([String: Any]) -> Void
    @State private var map = 0
    @State private var last: [String: Any] = [:]

    var body: some View {
        // A file path means nothing on iOS: the map is an open document.
        let fields = model.editor.commandFields(id: command.id).filter { $0.name != "mapPath" }
        CommandSettings(title: "Displace", fields: fields, initial: model.startingValues(fields), runTitle: "OK",
                        change: change.map { c in { p in last = p; c(p) } }, changeOnAppear: change != nil, extra: ["mapDocument": map],
                        header: AnyView(Section {
                            Picker("Displacement Map", selection: Binding(get: { map }, set: { m in
                                map = m
                                change?(last.merging(["mapDocument": m]) { _, b in b })
                            })) {
                                ForEach(Array(model.documents.enumerated()), id: \.offset) { i, d in Text(d.name).tag(i) }
                            }
                            .accessibilityIdentifier("displace.map")
                        } footer: {
                            Text("Its brightness moves each pixel: open the map as a document first.")
                        }),
                        run: run)
            .onAppear {
                // Another open document by default: displacing by itself is rarely wanted.
                let current = model.documents.firstIndex { $0.id == model.doc?.id } ?? 0
                if model.documents.count > 1 { map = current == 0 ? 1 : 0 } else { map = current }
            }
    }
}

// MARK: - Color Range

/// Select › Color Range: pick colours in the preview (add or subtract more), with the
/// selection shown in black and white.
struct ColorRangeEditor: View {
    @ObservedObject var model: EditorModel
    var surface = PickSurface.preview
    let change: ([String: Any]) -> Void
    let run: ([String: Any]) -> Void
    @State private var p: [String: Any] = ["select": "sampledColors", "fuzziness": 40]
    @State private var picker = "pick"
    @State private var showSelection = true

    static let selects: [(key: String, name: String)] = [
        ("sampledColors", "Sampled Colors"), ("reds", "Reds"), ("yellows", "Yellows"), ("greens", "Greens"), ("cyans", "Cyans"),
        ("blues", "Blues"), ("magentas", "Magentas"), ("highlights", "Highlights"), ("midtones", "Midtones"), ("shadows", "Shadows"),
        ("skinTones", "Skin Tones"), ("outOfGamut", "Out of Gamut"),
    ]

    private var select: String { p["select"] as? String ?? "sampledColors" }
    private var tones: Bool { ["highlights", "midtones", "shadows"].contains(select) }

    var body: some View {
        VStack(spacing: 0) {
            PreviewPane(model: model, selection: showSelection)
            EditorForm(title: "Color Range", runTitle: "OK", run: { run(p) }) {
                Section {
                    Picker("Select", selection: Binding(get: { select }, set: { set(["select": $0]) })) {
                        ForEach(Self.selects, id: \.key) { Text($0.name).tag($0.key) }
                    }
                    .accessibilityIdentifier("range.select")
                    if select == "sampledColors" {
                        Picker("Eyedropper", selection: $picker) {
                            Image(systemName: "eyedropper").tag("pick").accessibilityLabel("Pick")
                            Image(systemName: "plus").tag("add").accessibilityLabel("Add to Sample")
                            Image(systemName: "minus").tag("subtract").accessibilityLabel("Subtract from Sample")
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("range.picker")
                        if surface == .canvas {
                            Button("Pick in the Image") { model.beginPick(.canvas, prompt: "Tap a colour to select") { tap($0) } }
                                .accessibilityIdentifier("range.pickCanvas")
                        } else {
                            Text("Hold on the image, then let go on a colour.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    StyleSlider(title: "Fuzziness", value: number(p["fuzziness"]) ?? (tones ? 20 : 40), range: tones ? 0...100 : 0...200,
                                unit: tones ? "%" : "", id: "range.fuzziness") { set(["fuzziness": $0]) }
                    if select == "sampledColors" {
                        Toggle("Localized Color Clusters", isOn: Binding(get: { p["localized"] as? Bool ?? false }, set: { set(["localized": $0]) }))
                            .accessibilityIdentifier("range.localized")
                        if p["localized"] as? Bool == true {
                            StyleSlider(title: "Range", value: number(p["range"]) ?? 100, range: 0...100, unit: "%", id: "range.range") { set(["range": $0]) }
                        }
                    }
                    Toggle("Invert", isOn: Binding(get: { p["invert"] as? Bool ?? false }, set: { set(["invert": $0]) }))
                        .accessibilityIdentifier("range.invert")
                }
                Section {
                    Picker("Preview", selection: $showSelection) {
                        Text("Selection").tag(true)
                        Text("Image").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("range.preview")
                    Picker("Selection", selection: Binding(get: { p["mode"] as? String ?? "replace" }, set: { set(["mode": $0]) })) {
                        Text("New").tag("replace")
                        Text("Add").tag("add")
                        Text("Subtract").tag("subtract")
                        Text("Intersect").tag("intersect")
                    }
                    .accessibilityIdentifier("range.mode")
                }
            }
        }
        .onAppear {
            if surface == .preview { model.beginPick(.preview, prompt: "") { tap($0) } }
            change(p)
        }
        .onDisappear { model.endPick() }
    }

    private func tap(_ at: CGPoint) {
        guard select == "sampledColors", let d = model.doc else { return }
        let pt = PreviewSampler.docPoint(at, d)
        var points = p["points"] as? [[Int]] ?? [], minus = p["subtractPoints"] as? [[Int]] ?? [], order = p["order"] as? [String] ?? []
        switch picker {
        case "add": points.append(pt); order.append("+")
        case "subtract": minus.append(pt); order.append("-")
        default: (points, minus, order) = ([pt], [], ["+"])
        }
        set(["points": points, "subtractPoints": minus, "order": order])
    }

    private func set(_ q: [String: Any]) {
        p.merge(q) { _, b in b }
        change(p)
    }
}

// MARK: - Duotone

/// Image › Mode › Duotone: how many inks, and each ink's name, colour and curve.
struct DuotoneEditor: View {
    @ObservedObject var model: EditorModel
    let run: ([String: Any]) -> Void
    @State private var type = "duotone"
    @State private var inks: [Ink] = []

    struct Ink {
        var name: String
        var color: String
        /// 0…100 in, 0…100 out.
        var curve: [CGPoint]
    }

    static let types = ["monotone", "duotone", "tritone", "quadtone"]
    private var count: Int { (Self.types.firstIndex(of: type) ?? 1) + 1 }

    var body: some View {
        EditorForm(title: "Duotone", runTitle: "OK", run: { run(params) }) {
            Picker("Type", selection: $type) {
                ForEach(Self.types, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .accessibilityIdentifier("duotone.type")
            ForEach(0..<min(count, inks.count), id: \.self) { i in
                Section("Ink \(i + 1)") {
                    TextField("Name", text: $inks[i].name).accessibilityIdentifier("duotone.name.\(i)")
                    ColorRow(title: "Colour", hex: inks[i].color, id: "duotone.color.\(i)") { inks[i].color = $0 }
                    DisclosureGroup("Curve") {
                        CurveGraph(bins: [], tint: Color(hex: inks[i].color), points: Binding(
                            get: { inks[i].curve.map { CGPoint(x: $0.x * 2.55, y: $0.y * 2.55) } },
                            set: { inks[i].curve = $0.map { CGPoint(x: ($0.x / 2.55).rounded(), y: ($0.y / 2.55).rounded()) } }),
                                   selected: .constant(nil), ended: {})
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .accessibilityIdentifier("duotone.curve.\(i)")
                }
            }
        }
        .onAppear {
            guard inks.isEmpty, let out = model.query("image.mode.duotoneInks") as? [String: Any] else { return }
            inks = (out["inks"] as? [[String: Any]] ?? []).map { d in
                Ink(name: d["name"] as? String ?? "", color: d["color"] as? String ?? "#000000",
                    curve: (d["curve"] as? [[NSNumber]] ?? []).filter { $0.count == 2 }.map { CGPoint(x: $0[0].doubleValue, y: $0[1].doubleValue) })
            }
            if out["current"] as? Bool == true, (1...4).contains(inks.count) { type = Self.types[inks.count - 1] }
        }
    }

    private var params: [String: Any] {
        ["type": type, "inks": inks.prefix(count).map { ["name": $0.name, "color": $0.color, "curve": $0.curve.map { [Double($0.x), Double($0.y)] }] as [String: Any] }]
    }
}

// MARK: - Color Table

/// Image › Mode › Color Table: the indexed image's colours; tap one to change it.
struct ColorTableEditor: View {
    @ObservedObject var model: EditorModel
    let run: ([String: Any]) -> Void
    @State private var colors: [String] = []
    @State private var entries: [String: String] = [:]
    @State private var table = "custom"

    static let tables = ["custom", "blackBody", "grayscale", "spectrum", "systemMac", "systemWindows", "web"]

    var body: some View {
        EditorForm(title: "Color Table", runTitle: "OK", run: { run(["table": table, "entries": entries]) }) {
            Picker("Table", selection: $table) {
                ForEach(Self.tables, id: \.self) { Text(EffectPage.title($0)).tag($0) }
            }
            .accessibilityIdentifier("colorTable.table")
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 16), spacing: 2) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { i, c in
                        Rectangle().fill(Color(hex: entries["\(i)"] ?? c)).aspectRatio(1, contentMode: .fit)
                            .onTapGesture {
                                SystemColorPicker.present(title: "Colour \(i)", rgb: EffectPage.rgb(entries["\(i)"] ?? c)) { entries["\(i)"] = ColorRow.hex($0) }
                            }
                            .accessibilityIdentifier("colorTable.\(i)")
                    }
                }
                .opacity(table == "custom" ? 1 : 0.4)
            } footer: {
                Text(table == "custom" ? "Tap a colour to change it; the pixels that use it follow." : "The table is replaced when you tap OK.")
            }
        }
        .onAppear {
            guard colors.isEmpty else { return }
            colors = (model.query("image.mode.colorTable") as? [String: Any])?["colors"] as? [String] ?? []
        }
    }
}

// MARK: - Filter Gallery

/// Filter › Filter Gallery: a stack of effects, each with its own settings, applied in order.
struct FilterGalleryEditor: View {
    @ObservedObject var model: EditorModel
    let change: ([String: Any]) -> Void
    let run: ([String: Any]) -> Void
    @State private var catalogue: [Filter] = []
    @State private var effects: [Effect] = []

    struct Filter {
        let key: String
        let name: String
        let category: String
        let command: String
    }

    struct Effect {
        var filter: String
        var params: [String: Any] = [:]
        var visible = true
    }

    private var params: [String: Any] {
        ["effects": effects.map { ["filter": $0.filter, "params": $0.params, "visible": $0.visible] as [String: Any] }]
    }

    var body: some View {
        EditorForm(title: "Filter Gallery", runTitle: "OK", run: { run(params) }) {
            Section {
                ForEach(Array(effects.enumerated()), id: \.offset) { i, e in
                    let f = catalogue.first { $0.key == e.filter }
                    HStack {
                        Button { effects[i].visible.toggle(); change(params) } label: {
                            Image(systemName: e.visible ? "eye" : "eye.slash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("gallery.visible.\(i)")
                        NavigationLink {
                            CommandSettings(title: f?.name ?? e.filter, fields: model.editor.commandFields(id: f?.command ?? ""), initial: e.params, runTitle: "",
                                            change: { p in
                                                guard effects.indices.contains(i) else { return }
                                                effects[i].params = p
                                                change(params)
                                            }, run: { _ in })
                        } label: {
                            VStack(alignment: .leading) {
                                Text(f?.name ?? e.filter)
                                Text(f?.category ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("gallery.effect.\(i)")
                    }
                    .contextMenu {
                        if i > 0 { Button("Move Up") { effects.swapAt(i, i - 1); change(params) } }
                        if i < effects.count - 1 { Button("Move Down") { effects.swapAt(i, i + 1); change(params) } }
                    }
                }
                .onDelete { idx in
                    effects.remove(atOffsets: idx)
                    if !effects.isEmpty { change(params) }
                }
                Picker("Add Effect", selection: Binding(get: { "" }, set: { key in
                    guard !key.isEmpty else { return }
                    effects.append(Effect(filter: key))
                    change(params)
                })) {
                    Text("Choose…").tag("")
                    ForEach(categories, id: \.self) { cat in
                        Section(cat) {
                            ForEach(catalogue.filter { $0.category == cat }, id: \.key) { Text($0.name).tag($0.key) }
                        }
                    }
                }
                .accessibilityIdentifier("gallery.add")
            } header: {
                Text("Effects")
            } footer: {
                Text("Applied top to bottom. Tap an effect for its settings; swipe to remove it.")
            }
        }
        .onAppear {
            guard catalogue.isEmpty, let out = model.query("filter.filterGallery", ["list": true]) as? [String: Any] else { return }
            catalogue = (out["filters"] as? [[String: Any]] ?? []).compactMap { d in
                guard let k = d["key"] as? String, let n = d["name"] as? String, let c = d["command"] as? String else { return nil }
                return Filter(key: k, name: n, category: d["category"] as? String ?? "", command: c)
            }
            if let first = catalogue.first { effects = [Effect(filter: first.key)] }
            change(params)
        }
    }

    private var categories: [String] { catalogue.map(\.category).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
}
