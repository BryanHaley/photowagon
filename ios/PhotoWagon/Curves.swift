import SwiftUI

/// Curves settings in the engine's params. Each channel's curve is under its key ("points" for the
/// composite, Lab's Lightness), as points in 0…255, or with `pencil` as 256 drawn output levels.
struct CurvesValues: Equatable {
    static let identity = [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 255)]
    static let maxPoints = 16

    var pencil = false
    var curves: [String: [CGPoint]] = [:]
    var maps: [String: [Double]] = [:]

    init(curves: [String: [CGPoint]] = [:]) { self.curves = curves }

    init(_ p: [String: Any]) {
        pencil = p["pencil"] as? Bool ?? false
        for (k, v) in p {
            let key = k == "points" ? "" : k
            if pencil, let m = v as? [NSNumber], m.count == 256 {
                maps[key] = m.map(\.doubleValue)
            } else if let a = v as? [[NSNumber]] {
                let pts = a.filter { $0.count == 2 }.map { CGPoint(x: $0[0].doubleValue, y: $0[1].doubleValue) }
                if pts.count >= 2 { curves[key] = pts.sorted { $0.x < $1.x } }
            }
        }
    }

    subscript(key: String) -> [CGPoint] {
        get { curves[key] ?? Self.identity }
        set { curves[key] = newValue }
    }

    func map(_ key: String) -> [Double] { maps[key] ?? Self.spline(self[key]) }

    /// Params for every channel in `keys` ("" = the composite).
    func params(keys: [String]) -> [String: Any] {
        var out: [String: Any] = ["pencil": pencil]
        for k in keys {
            let name = k.isEmpty ? "points" : k
            out[name] = pencil ? map(k) as Any : self[k].map { [Double($0.x), Double($0.y)] } as Any
        }
        return out
    }

    /// The 256 outputs (0…255) of the curve through `points`: a natural cubic spline, flat past
    /// the ends, as the engine draws it.
    static func spline(_ points: [CGPoint]) -> [Double] {
        var pts = points.map { (Double($0.x) / 255, Double($0.y) / 255) }.sorted { $0.0 < $1.0 }
        pts = pts.reduce(into: []) { out, p in if let l = out.last, abs(l.0 - p.0) < 1e-6 { return }; out.append(p) }
        guard pts.count >= 2 else { return (0..<256).map(Double.init) }
        let n = pts.count
        var m2 = [Double](repeating: 0, count: n)
        if n > 2 {
            var c = [Double](repeating: 0, count: n), d = [Double](repeating: 0, count: n)
            for i in 1..<(n - 1) {
                let h0 = pts[i].0 - pts[i - 1].0, h1 = pts[i + 1].0 - pts[i].0
                let r = (pts[i + 1].1 - pts[i].1) / h1 - (pts[i].1 - pts[i - 1].1) / h0
                let denom = (h0 + h1) / 3 - h0 / 6 * c[i - 1]
                c[i] = h1 / 6 / denom
                d[i] = (r - h0 / 6 * d[i - 1]) / denom
            }
            for i in stride(from: n - 2, through: 1, by: -1) { m2[i] = d[i] - c[i] * m2[i + 1] }
        }
        return (0..<256).map { k in
            let x = Double(k) / 255
            if x <= pts[0].0 { return min(max(pts[0].1, 0), 1) * 255 }
            if x >= pts[n - 1].0 { return min(max(pts[n - 1].1, 0), 1) * 255 }
            let i = (0..<(n - 1)).first { x <= pts[$0 + 1].0 } ?? n - 2
            let (x0, y0) = pts[i], (x1, y1) = pts[i + 1]
            let h = x1 - x0, a = (x1 - x) / h, b = (x - x0) / h
            let y = a * y0 + b * y1 + ((a * a * a - a) * m2[i] + (b * b * b - b) * m2[i + 1]) * h * h / 6
            return min(max(y, 0), 1) * 255
        }
    }

    /// `points` with a new one at `p`, kept in order; its index, or `nil` when full or too close
    /// to another point.
    static func insert(_ points: inout [CGPoint], _ p: CGPoint) -> Int? {
        guard points.count < maxPoints, !points.contains(where: { abs($0.x - p.x) < 4 }) else { return nil }
        let i = points.firstIndex { $0.x > p.x } ?? points.count
        points.insert(CGPoint(x: min(max(p.x, 0), 255).rounded(), y: min(max(p.y, 0), 255).rounded()), at: i)
        return i
    }

    /// Point `i` moved to `p`, staying between its neighbours.
    static func move(_ points: inout [CGPoint], _ i: Int, to p: CGPoint) {
        guard points.indices.contains(i) else { return }
        let lo = i > 0 ? points[i - 1].x + 1 : 0
        let hi = i < points.count - 1 ? points[i + 1].x - 1 : 255
        points[i] = CGPoint(x: min(max(p.x, lo), max(lo, hi)).rounded(), y: min(max(p.y, 0), 255).rounded())
    }

    /// One Smooth pass over a drawn curve.
    static func smooth(_ map: [Double]) -> [Double] {
        map.indices.map { i in
            let w = map[max(i - 2, 0)...min(i + 2, map.count - 1)]
            return w.reduce(0, +) / Double(w.count)
        }
    }

    /// Points that follow a drawn curve, for going back from the pencil.
    static func points(fitting map: [Double]) -> [CGPoint] {
        guard map.count == 256 else { return identity }
        return stride(from: 0, through: 255, by: 51).map { CGPoint(x: Double($0), y: map[$0].rounded()) }
    }

    /// Auto's curves: black to white between its levels, through its midtone when it has a gamma.
    init(auto: AutoPixels.Result) {
        for (k, l) in auto.channels {
            var pts = [CGPoint(x: l.black, y: 0), CGPoint(x: l.white, y: 255)]
            if abs(l.gamma - 1) > 0.01 {
                pts.insert(CGPoint(x: (l.black + (l.white - l.black) * pow(0.5, l.gamma)).rounded(), y: 128), at: 1)
            }
            curves[k] = pts
        }
    }

    /// What each input level of channel `key` comes out at (0…255): its own curve, then the
    /// composite's, as the engine applies them.
    func outputs(_ key: String) -> [Double] {
        let master = map("")
        guard !key.isEmpty else { return master }
        return map(key).map { master[Int(min(max($0.rounded(), 0), 255))] }
    }

    static let presets: [(name: String, points: [CGPoint])] = [
        ("Default", identity),
        ("Brighter", [CGPoint(x: 0, y: 0), CGPoint(x: 128, y: 160), CGPoint(x: 255, y: 255)]),
        ("Darker", [CGPoint(x: 0, y: 0), CGPoint(x: 128, y: 96), CGPoint(x: 255, y: 255)]),
        ("More Contrast", [CGPoint(x: 0, y: 0), CGPoint(x: 64, y: 48), CGPoint(x: 192, y: 208), CGPoint(x: 255, y: 255)]),
        ("Strong Contrast", [CGPoint(x: 0, y: 0), CGPoint(x: 64, y: 32), CGPoint(x: 192, y: 224), CGPoint(x: 255, y: 255)]),
        ("Lift Shadows", [CGPoint(x: 0, y: 24), CGPoint(x: 64, y: 84), CGPoint(x: 255, y: 255)]),
        ("Faded", [CGPoint(x: 0, y: 32), CGPoint(x: 255, y: 224)]),
        ("Negative", [CGPoint(x: 0, y: 255), CGPoint(x: 255, y: 0)]),
    ]
}

/// Curves as a Photoshop user expects: preset, channel, the curve over the histogram (drag points,
/// tap to add, drag off to remove, or draw with the pencil), Input/Output of the selected point,
/// Auto and the eyedroppers.
struct CurvesEditor: View {
    @ObservedObject var model: EditorModel
    /// An adjustment layer; `nil` for Image › Adjustments › Curves on the active layer.
    let layer: UInt64?
    let initial: [String: Any]
    var surface = PickSurface.preview
    var runTitle = "OK"
    let change: ([String: Any]) -> Void
    let run: ([String: Any]) -> Void

    @State private var values = CurvesValues()
    @State private var tone: ToneInfo?
    @State private var key = ""
    @State private var selected: Int?
    @State private var picking: String?
    @State private var sampler = PreviewSampler()
    @State private var loaded = false
    @State private var preset = "Default"
    @State private var fineGrid = false
    @State private var pixels = AutoPixels(rgb: [])
    @State private var options = AutoOptions.saved()
    @State private var showClipping = false

    private var keys: [String] { tone?.channels.map(\.key) ?? [""] }

    var body: some View {
        Form {
            Section {
                HStack {
                    PresetPicker(names: CurvesValues.presets.map(\.name), current: preset, id: "curves.preset") { name in
                        guard let p = CurvesValues.presets.first(where: { $0.name == name }) else { return }
                        values = CurvesValues(curves: ["": p.points])
                        selected = nil
                        commit()
                        preset = name
                    }
                    Spacer()
                    AutoRow(id: "curves", options: $options) { o in
                        values = CurvesValues(auto: pixels.auto(o, color: tone?.isRGB ?? false))
                        selected = nil
                        commit()
                        preset = "Auto"
                    }
                }
                if let tone, tone.channels.count > 1 {
                    let picker = Picker("Channel", selection: $key) {
                        ForEach(tone.channels) { Text($0.name).tag($0.key) }
                    }
                    .accessibilityIdentifier("curves.channel")
                    if tone.channels.count <= 4 { picker.pickerStyle(.segmented) } else { picker.pickerStyle(.menu) }
                }
                ClippingToggle(model: model, surface: surface, on: $showClipping, id: "curves")
            }
            Section {
                HStack {
                    Picker("Edit", selection: Binding(get: { values.pencil }, set: { setPencil($0) })) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").tag(false).accessibilityLabel("Points")
                        Image(systemName: "pencil").tag(true).accessibilityLabel("Pencil")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    .accessibilityIdentifier("curves.mode")
                    Spacer()
                    if values.pencil {
                        Button("Smooth") {
                            values.maps[key] = CurvesValues.smooth(values.map(key))
                            commit()
                        }
                        .accessibilityIdentifier("curves.smooth")
                    }
                    Button { fineGrid.toggle() } label: { Image(systemName: fineGrid ? "square.grid.4x3.fill" : "square.grid.2x2") }
                        .accessibilityLabel("Grid Size")
                }
                .buttonStyle(.borderless)
                let bins = tone?.channels.first { $0.key == key }?.bins ?? []
                let clip = showClipping ? ClipStats(bins: bins, outputs: values.outputs(key)) : nil
                CurveGraph(bins: bins, tint: ToneInfo.tint(key), marks: clip, grid: fineGrid ? 10 : 4,
                           points: Binding(get: { values[key] }, set: { values[key] = $0 }),
                           map: values.pencil ? Binding(get: { values.map(key) }, set: { values.maps[key] = $0 }) : nil,
                           overlays: key.isEmpty ? keys.filter { !$0.isEmpty }.map { (ToneInfo.tint($0), values.map($0)) } : [],
                           selected: $selected, ended: commit)
                    .aspectRatio(1, contentMode: .fit)
                if let clip {
                    Text(clip.text).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("curves.clipping")
                }
                if !values.pencil {
                    HStack {
                        Text("Input").foregroundStyle(.secondary)
                        field("curves.input", \.x)
                        Spacer()
                        Text("Output").foregroundStyle(.secondary)
                        field("curves.output", \.y)
                        Button(role: .destructive) { deleteSelected() } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .disabled(!canDelete)
                            .accessibilityLabel("Delete Point")
                            .accessibilityIdentifier("curves.delete")
                    }
                }
            } footer: {
                Text(values.pencil ? "Draw the curve with your finger." : "Tap to add a point; drag a point off the graph to remove it.")
            }
            if let tone, tone.eyedroppers {
                Section {
                    EyedropperRow(model: model, surface: surface, picking: $picking, gray: tone.grayPicker, id: "curves") { point, p in
                        guard let out = sampler.adjust("curves", values.params(keys: keys), point, at: p, model: model) else { return }
                        values = CurvesValues(out)
                        selected = nil
                        commit()
                    }
                }
            }
        }
        .navigationTitle("Curves")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !runTitle.isEmpty {
                ToolbarItem(placement: .confirmationAction) {
                    Button(runTitle) { run(values.params(keys: keys)) }.accessibilityIdentifier("settings.run")
                }
            }
        }
        .onChange(of: key) { selected = nil }
        .onAppear(perform: load)
    }

    private var canDelete: Bool {
        guard let selected else { return false }
        return selected > 0 && selected < values[key].count - 1
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        values = CurvesValues(initial)
        if !initial.isEmpty { preset = "Custom" }
        tone = ToneInfo.load(model, layer: layer)
        sampler = PreviewSampler(model, layer: layer)
        pixels = AutoPixels.load(model, layer: layer)
    }

    private func commit() {
        preset = "Custom"
        change(values.params(keys: keys))
    }

    private func setPencil(_ on: Bool) {
        guard on != values.pencil else { return }
        if on {
            for k in keys { values.maps[k] = values.map(k) }
        } else {
            for k in keys { values.curves[k] = CurvesValues.points(fitting: values.map(k)) }
            values.maps = [:]
        }
        values.pencil = on
        selected = nil
        commit()
    }

    private func deleteSelected() {
        guard canDelete, let i = selected else { return }
        values[key].remove(at: i)
        selected = nil
        commit()
    }

    private func field(_ id: String, _ axis: WritableKeyPath<CGPoint, CGFloat>) -> some View {
        TextField("", value: Binding(get: { selected.flatMap { values[key].indices.contains($0) ? Double(values[key][$0][keyPath: axis]) : nil } ?? 0 },
                                     set: { v in
                                         guard let i = selected else { return }
                                         var p = values[key][i]
                                         p[keyPath: axis] = v
                                         CurvesValues.move(&values[key], i, to: p)
                                         commit()
                                     }),
                  format: .number.precision(.fractionLength(0)))
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .textFieldStyle(.roundedBorder)
            .frame(width: scaled(56))
            .disabled(selected == nil)
            .accessibilityIdentifier(id)
    }
}

/// The curve over its histogram, with the grid, the straight baseline and the points.
struct CurveGraph: View {
    let bins: [Int]
    let tint: Color
    var marks: ClipStats?
    var grid = 4
    @Binding var points: [CGPoint]
    /// The drawn curve in pencil mode.
    var map: Binding<[Double]>?
    /// Other channels' curves, faint (the composite shows them, as Photoshop does).
    var overlays: [(Color, [Double])] = []
    @Binding var selected: Int?
    let ended: () -> Void

    @State private var dragging: Int?
    @State private var lastDraw: CGPoint?

    var body: some View {
        GeometryReader { g in
            let s = g.size
            ZStack {
                LevelsHistogram(bins: bins, tint: .secondary, marks: marks)
                Canvas { ctx, size in
                    let lines = Path { p in
                        for i in 1..<grid {
                            let t = CGFloat(i) / CGFloat(grid)
                            p.move(to: CGPoint(x: t * size.width, y: 0)); p.addLine(to: CGPoint(x: t * size.width, y: size.height))
                            p.move(to: CGPoint(x: 0, y: t * size.height)); p.addLine(to: CGPoint(x: size.width, y: t * size.height))
                        }
                    }
                    ctx.stroke(lines, with: .color(.white.opacity(0.15)), lineWidth: 1)
                    ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: 0)) },
                               with: .color(.white.opacity(0.3)), lineWidth: 1)
                    for (c, m) in overlays where m != (0..<256).map(Double.init) {
                        ctx.stroke(Self.path(m, size), with: .color(c.opacity(0.6)), lineWidth: 1)
                    }
                    let outs = map?.wrappedValue ?? CurvesValues.spline(points)
                    ctx.stroke(Self.path(outs, size), with: .color(tint == .primary ? .white : tint), lineWidth: 2)
                    guard map == nil else { return }
                    for (i, p) in points.enumerated() {
                        let v = view(p, size)
                        let r = CGRect(x: v.x - 6, y: v.y - 6, width: 12, height: 12)
                        if i == selected { ctx.fill(Path(r), with: .color(.white)) } else { ctx.stroke(Path(r), with: .color(.white), lineWidth: 1.5) }
                    }
                }
            }
            .overlay(TouchSurface(mode: map == nil ? 0 : 1) { start, at in drag(start, at, s) } ended: {
                dragging = nil
                lastDraw = nil
                ended()
            })
        }
        .accessibilityElement()
        .accessibilityIdentifier("curves.graph")
        .accessibilityValue(points.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " "))
    }

    private func view(_ p: CGPoint, _ s: CGSize) -> CGPoint { CGPoint(x: p.x / 255 * s.width, y: (1 - p.y / 255) * s.height) }
    private func curve(_ v: CGPoint, _ s: CGSize) -> CGPoint { CGPoint(x: v.x / max(s.width, 1) * 255, y: (1 - v.y / max(s.height, 1)) * 255) }

    private static func path(_ outs: [Double], _ s: CGSize) -> Path {
        Path { p in
            for (i, o) in outs.enumerated() {
                let pt = CGPoint(x: CGFloat(i) / 255 * s.width, y: (1 - o / 255) * s.height)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    private func drag(_ start: CGPoint, _ location: CGPoint, _ s: CGSize) {
        let c = curve(location, s)
        if let map {
            draw(map, from: lastDraw ?? c, to: c)
            lastDraw = c
            return
        }
        if dragging == nil {
            let distance = { (i: Int) in hypot(view(points[i], s).x - start.x, view(points[i], s).y - start.y) }
            if let near = points.indices.min(by: { distance($0) < distance($1) }), distance(near) < 28 {
                dragging = near
            } else {
                dragging = CurvesValues.insert(&points, curve(start, s))
            }
            selected = dragging
        }
        guard let i = dragging else { return }
        // Dragged well off the graph: the point goes, as in Photoshop (not the end points).
        let off = location.x < -30 || location.x > s.width + 30 || location.y < -30 || location.y > s.height + 30
        if off, i > 0, i < points.count - 1 {
            points.remove(at: i)
            dragging = nil
            selected = nil
            return
        }
        CurvesValues.move(&points, i, to: c)
    }

    private func draw(_ map: Binding<[Double]>, from a: CGPoint, to b: CGPoint) {
        var m = map.wrappedValue
        guard m.count == 256 else { return }
        let (x0, x1) = (Int(min(max(a.x, 0), 255)), Int(min(max(b.x, 0), 255)))
        for x in min(x0, x1)...max(x0, x1) {
            let t = x1 == x0 ? 1 : Double(x - x0) / Double(x1 - x0)
            m[x] = min(max(Double(a.y) + (Double(b.y) - Double(a.y)) * t, 0), 255)
        }
        map.wrappedValue = m
    }
}

/// Takes a drag from its first touch, so a form around it doesn't scroll instead (a SwiftUI
/// drag gesture loses vertical drags to the scroll). Reports the start and each location.
struct TouchSurface: UIViewRepresentable {
    /// Changes when what a drag does changes: SwiftUI may skip `updateUIView` for closures
    /// alone, leaving the old ones.
    var mode = 0
    let changed: (CGPoint, CGPoint) -> Void
    let ended: () -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        v.addGestureRecognizer(press)
        return v
    }

    func updateUIView(_ v: UIView, context: Context) { context.coordinator.parent = self }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: TouchSurface
        private var start = CGPoint.zero
        init(_ parent: TouchSurface) { self.parent = parent }

        @objc func pressed(_ g: UILongPressGestureRecognizer) {
            let p = g.location(in: g.view)
            switch g.state {
            case .began:
                start = p
                parent.changed(p, p)
            case .changed: parent.changed(start, p)
            case .ended, .cancelled, .failed: parent.ended()
            default: break
            }
        }
    }
}
