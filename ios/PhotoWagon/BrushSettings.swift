import SwiftUI

/// Dotted paths into the engine's brush JSON (`shapeDynamics.size.jitter`).
enum BrushPaths {
    /// The nested patch `tools.setBrush` deep-merges: `a.b` = v → `{"a": {"b": v}}`.
    static func patch(_ path: String, _ value: Any) -> [String: Any] {
        path.split(separator: ".").reversed().reduce(value) { inner, key in [String(key): inner] } as? [String: Any] ?? [:]
    }

    static func get(_ brush: [String: Any], _ path: String) -> Any? {
        path.split(separator: ".").reduce(brush as Any?) { v, key in (v as? [String: Any])?[String(key)] }
    }

    /// What a dynamic setting follows (Photoshop's Control pop-ups). No stylus wheel on a Pencil.
    static let controls = [("off", "Off"), ("fade", "Fade"), ("penPressure", "Pen Pressure"), ("penTilt", "Pen Tilt"),
                           ("rotation", "Pencil Rotation"), ("initialDirection", "Initial Direction"), ("direction", "Direction")]
}

/// Window › Brush Settings: the brush tip's shape, Shape Dynamics, Scattering, Transfer and
/// Smoothing, with a stroke preview; New Brush Preset saves it.
struct BrushSettingsSheet: View {
    @ObservedObject var model: EditorModel
    @State private var brush: [String: Any] = [:]
    @State private var preview: UIImage?
    @State private var naming = false
    @State private var presetName = ""
    @State private var toolSettings = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color(white: 0.12)
                    if let preview { Image(uiImage: preview).resizable().scaledToFit() }
                }
                .frame(height: 90)
                .accessibilityElement()
                .accessibilityIdentifier("brushSettings.preview")
                Form {
                    Section("Brush Tip Shape") {
                        number("Size", "size", 1...5000, unit: " px", log: true)
                        percent("Hardness", "hardness")
                        number("Angle", "angle", -180...180, unit: "°")
                        percent("Roundness", "roundness")
                        flag("Flip X", "flipX")
                        flag("Flip Y", "flipY")
                        flag("Spacing", "spacingEnabled")
                        if bool("spacingEnabled") { percent("Spacing", "spacing", 0.01...10) }
                    }
                    section("Shape Dynamics", "shapeDynamics") {
                        dynamic("Size Jitter", "shapeDynamics.size", minimum: "Minimum Diameter")
                        percent("Tilt Scale", "shapeDynamics.tiltScale", 0...2)
                        dynamic("Angle Jitter", "shapeDynamics.angle")
                        dynamic("Roundness Jitter", "shapeDynamics.roundness", minimum: "Minimum Roundness")
                        flag("Flip X Jitter", "shapeDynamics.flipXJitter")
                        flag("Flip Y Jitter", "shapeDynamics.flipYJitter")
                    }
                    section("Scattering", "scattering") {
                        dynamic("Scatter", "scattering.scatter", range: 0...10)
                        flag("Both Axes", "scattering.bothAxes")
                        number("Count", "scattering.count", 1...16)
                        dynamic("Count Jitter", "scattering.countJitter")
                    }
                    section("Transfer", "transfer") {
                        dynamic("Opacity Jitter", "transfer.opacity", minimum: "Minimum")
                        dynamic("Flow Jitter", "transfer.flow", minimum: "Minimum")
                    }
                    Section("Flow and Smoothing") {
                        percent("Flow", "flow", 0.01...1)
                        percent("Smoothing", "smoothing.amount")
                        flag("Pulled String Mode", "smoothing.pulledString")
                        flag("Stroke Catch-up", "smoothing.catchUp")
                        flag("Catch-up on Stroke End", "smoothing.catchUpOnEnd")
                        flag("Adjust for Zoom", "smoothing.adjustForZoom")
                    }
                    Section {
                        flag("Noise", "noise")
                        flag("Wet Edges", "wetEdges")
                        flag("Build-up", "buildUp")
                    }
                    Section {
                        Toggle("Include Tool Settings", isOn: $toolSettings).accessibilityIdentifier("brushSettings.toolSettings")
                        Button { presetName = ""; naming = true } label: { Label("New Brush Preset…", systemImage: "plus") }
                            .accessibilityIdentifier("brushSettings.newPreset")
                    } footer: {
                        Text("Tool settings: the mode, opacity, flow and the pressure buttons go with the preset.")
                    }
                }
            }
            .navigationTitle("Brush Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DoneButton() } }
            .alert("New Brush Preset", isPresented: $naming) {
                TextField("Name", text: $presetName)
                Button("Cancel", role: .cancel) {}
                Button("OK") {
                    let name = presetName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    model.run("brush.presets.save", ["name": name, "toolSettings": toolSettings])
                    model.reloadBrushPresets()
                }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        brush = model.query("brush.get") as? [String: Any] ?? [:]
        preview = (try? model.editor.brushPreview(width: 600, height: 180)).flatMap { UIImage(data: $0) }
    }

    private func set(_ path: String, _ value: Any) {
        model.setBrush(path: path, value)
        reload()
    }

    private func double(_ path: String) -> Double { (BrushPaths.get(brush, path) as? NSNumber)?.doubleValue ?? 0 }
    private func bool(_ path: String) -> Bool { BrushPaths.get(brush, path) as? Bool ?? false }

    /// A section with its on switch, as Photoshop's checkboxes beside each name.
    private func section(_ title: String, _ key: String, @ViewBuilder content: () -> some View) -> some View {
        Section {
            Toggle(title, isOn: Binding(get: { bool("\(key).enabled") }, set: { set("\(key).enabled", $0) }))
                .font(.headline)
                .accessibilityIdentifier("brushSettings.\(key)")
            if bool("\(key).enabled") { content() }
        }
    }

    private func flag(_ title: String, _ path: String) -> some View {
        Toggle(title, isOn: Binding(get: { bool(path) }, set: { set(path, $0) }))
            .accessibilityIdentifier("brushSettings.\(path)")
    }

    private func percent(_ title: String, _ path: String, _ range: ClosedRange<Double> = 0...1) -> some View {
        row(title, "\(Int((double(path) * 100).rounded()))%", path: path, value: double(path), range: range) { $0 }
    }

    private func number(_ title: String, _ path: String, _ range: ClosedRange<Double>, unit: String = "", log: Bool = false) -> some View {
        // Size on a curve, so small brushes get most of the slider.
        let to = { (v: Double) in log ? pow((v - range.lowerBound) / (range.upperBound - range.lowerBound), 1 / 2.2) : v }
        let from = { (t: Double) in (log ? range.lowerBound + pow(t, 2.2) * (range.upperBound - range.lowerBound) : t).rounded() }
        return row(title, "\(Int(double(path)))\(unit)", path: path, value: to(double(path)), range: log ? 0...1 : range, map: from)
    }

    private func row(_ title: String, _ text: String, path: String, value: Double, range: ClosedRange<Double>, map: @escaping (Double) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                ValueLabel(text: text, width: 64, font: .body)
            }
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { brush = merged(path, map($0)) }), in: range) { editing in
                if !editing { set(path, double(path)) }
            }
            .accessibilityIdentifier("brushSettings.\(path)")
        }
    }

    /// A jitter amount, what it follows and (for size and roundness) its minimum.
    @ViewBuilder
    private func dynamic(_ title: String, _ path: String, minimum: String? = nil, range: ClosedRange<Double> = 0...1) -> some View {
        percent(title, "\(path).jitter", range)
        Picker("Control", selection: Binding(get: { BrushPaths.get(brush, "\(path).control") as? String ?? "off" }, set: { set("\(path).control", $0) })) {
            ForEach(BrushPaths.controls, id: \.0) { Text($0.1).tag($0.0) }
        }
        .accessibilityIdentifier("brushSettings.\(path).control")
        if let minimum { percent(minimum, "\(path).minimum") }
    }

    /// `brush` with `value` at `path`, for the slider to show while dragging.
    private func merged(_ path: String, _ value: Any) -> [String: Any] {
        func put(_ d: [String: Any], _ keys: ArraySlice<Substring>) -> [String: Any] {
            guard let k = keys.first.map(String.init) else { return d }
            var d = d
            d[k] = keys.count == 1 ? value : put(d[k] as? [String: Any] ?? [:], keys.dropFirst())
            return d
        }
        return put(brush, path.split(separator: ".")[...])
    }
}

extension Tool {
    /// Has Flow, Smoothing, the pressure buttons and Brush Settings.
    var brushOptions: Bool { [.brush, .pencil, .eraser, .clone, .patternStamp, .historyBrush, .mixerBrush].contains(self) }
}

/// The brush's mode and painting symmetry.
extension EditorModel {
    /// The engine's name for a blend mode menu title (`Linear Dodge (Add)` → `LinearDodge`).
    static func engineMode(_ title: String) -> String {
        title.replacingOccurrences(of: " (Add)", with: "").replacingOccurrences(of: " ", with: "")
    }

    static func modeTitle(_ engine: String) -> String {
        blendModes.flatMap { $0 }.first { engineMode($0) == engine } ?? engine
    }

    /// ← and → turn the brush tip a degree (⇧: 15°), → clockwise as in Photoshop.
    func rotateBrush(clockwise: Bool, shift: Bool) {
        run("tools.rotateBrush", ["degrees": (clockwise ? -1 : 1) * (shift ? 15 : 1)])
    }

    /// Mirror symmetry only: radial copies are left out (`docs/patent-guardrails.md`).
    static let symmetryModes = [("vertical", "Vertical"), ("horizontal", "Horizontal"), ("dual", "Dual Axis"), ("diagonal", "Diagonal")]

    /// Paint mirrored across the canvas's middle; "" turns it off.
    func setSymmetry(_ mode: String) {
        if mode.isEmpty { run("paint.symmetryDisable") } else { run("paint.setSymmetry", ["mode": mode]) }
    }
}

/// The brush tip's angle by touch: drag round the dial, or turn it 15° at a time.
struct BrushAngleDial: View {
    @ObservedObject var model: EditorModel
    @State private var angle = 0.0
    @State private var roundness = 1.0

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { g in
                let side = min(g.size.width, g.size.height)
                let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                    // The tip's shape at its angle (degrees anticlockwise, as the engine has them).
                    Ellipse().fill(Color.primary.opacity(0.25))
                        .frame(width: side * 0.7, height: side * 0.7 * max(roundness, 0.05))
                        .rotationEffect(.degrees(-angle))
                    Path { p in
                        p.move(to: c)
                        let r = side / 2, a = angle * .pi / 180
                        p.addLine(to: CGPoint(x: c.x + r * cos(a), y: c.y - r * sin(a)))
                    }
                    .stroke(Color.accentColor, lineWidth: 2)
                }
                .frame(width: side, height: side)
                .position(c)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { set(Self.angle(at: $0.location, center: c)) })
            }
            .frame(width: 150, height: 150)
            .accessibilityElement()
            .accessibilityIdentifier("brushAngle.dial")
            .accessibilityValue("\(Int(angle))°")
            HStack(spacing: 14) {
                Button { set(angle + 15) } label: { Image(systemName: "rotate.left") }
                    .accessibilityLabel("Turn 15° Anticlockwise").accessibilityIdentifier("brushAngle.left")
                Text("\(Int(angle))°").monospacedDigit().frame(width: 48)
                Button { set(angle - 15) } label: { Image(systemName: "rotate.right") }
                    .accessibilityLabel("Turn 15° Clockwise").accessibilityIdentifier("brushAngle.right")
                Button("Reset") { set(0) }.accessibilityIdentifier("brushAngle.reset")
            }
            .font(.title3)
        }
        .padding(16)
        .onAppear(perform: load)
    }

    private func load() {
        let b = model.query("brush.get") as? [String: Any] ?? [:]
        angle = (b["angle"] as? NSNumber)?.doubleValue ?? 0
        roundness = (b["roundness"] as? NSNumber)?.doubleValue ?? 1
    }

    private func set(_ a: Double) {
        angle = Self.wrapped(a)
        model.setBrush("angle", angle)
    }

    /// Degrees anticlockwise from the right of `center` to `p` (screen y runs down), whole degrees.
    static func angle(at p: CGPoint, center c: CGPoint) -> Double {
        wrapped((atan2(Double(c.y - p.y), Double(p.x - c.x)) * 180 / .pi).rounded())
    }

    /// Into −180…180.
    static func wrapped(_ a: Double) -> Double {
        let w = (a + 180).truncatingRemainder(dividingBy: 360)
        return (w < 0 ? w + 360 : w) - 180
    }
}
