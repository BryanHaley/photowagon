import SwiftUI

/// Filter › Develop (the engine's Camera Raw Filter): Profile and Auto, presets, the panels
/// (Light, Color, Effects, Curve, Color Mixer, Detail) and snapshots, with the result shown as you
/// let go of each control. `opening` is a file just opened: Done, Open and Open as Object instead
/// of OK, and the Workflow's colour space and depth.
struct CameraRawView: View {
    @ObservedObject var model: EditorModel
    /// The settings to start from (a live filter being edited).
    var initial: [String: Any] = [:]
    var opening = false
    /// Settings tried as they change (a slider let go).
    var change: (([String: Any]) -> Void)?
    var cancel: (() -> Void)?
    let done: ([String: Any]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var settings = DevelopSettings()
    @State private var last = DevelopSettings()
    @State private var undo: [DevelopSettings] = []
    @State private var redo: [DevelopSettings] = []
    @State private var loaded = false
    @State private var naming = false
    @State private var presetName = ""
    @State private var preset: [String: Double]?
    @State private var presetAmount = 100.0
    @State private var namingSnapshot = false
    @State private var snapshotName = ""
    @State private var expanded: Set<String> = ["Light"]
    @State private var mixerKind = "hslSat"
    @State private var curveKey = "pointCurve"
    @State private var curvePoint: Int?
    @State private var autoWB = false
    @State private var pickingWB = false
    @State private var showClipping = false
    /// The image as it opened, for Auto and the White Balance Tool.
    @State private var pixels = AutoPixels(rgb: [])
    @State private var sampler = PreviewSampler()
    @State private var space = ""
    @State private var depth = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PreviewPane(model: model)
                Form {
                    Section {
                        Picker("Profile", selection: Binding(get: { settings.monochrome }, set: { settings.monochrome = $0; tried() })) {
                            Text("Color").tag(false)
                            Text("Monochrome").tag(true)
                        }
                        .accessibilityIdentifier("raw.profile")
                        Button("Auto") { applyAuto(DevelopSettings.light.map(\.key)) }.accessibilityIdentifier("raw.auto")
                        ClippingToggle(model: model, surface: .preview, on: $showClipping, id: "raw")
                    }
                    Section("Presets") {
                        ForEach(EditorModel.developLooks + model.developPresets, id: \.name) { p in
                            Button(p.name) {
                                (preset, presetAmount) = (p.values, 100)
                                settings.apply(p.values)
                                tried()
                            }
                            .accessibilityIdentifier("raw.preset.\(p.name)")
                        }
                        if let preset {
                            sliderRow("Amount", value: "\(Int(presetAmount))%", key: "presetAmount") {
                                Slider(value: $presetAmount, in: 0...200, step: 1) { editing in
                                    if !editing { settings.apply(preset, amount: presetAmount); tried() }
                                }
                            }
                        }
                        Button { presetName = ""; naming = true } label: { Label("Save Preset…", systemImage: "plus") }
                            .accessibilityIdentifier("raw.savePreset")
                    }
                    ForEach(DevelopSettings.panels, id: \.name) { panel in
                        Section {
                            if expanded.contains(panel.name) { content(panel) }
                        } header: {
                            header(panel.name)
                        }
                    }
                    Section("Snapshots") {
                        ForEach(settings.snapshots, id: \.name) { s in
                            Button(s.name) { settings.restore(s); tried() }.accessibilityIdentifier("raw.snapshot.\(s.name)")
                        }
                        Button { snapshotName = ""; namingSnapshot = true } label: { Label("Save Snapshot…", systemImage: "camera") }
                            .accessibilityIdentifier("raw.saveSnapshot")
                    }
                    if opening {
                        Section {
                            Picker("Color Space", selection: $space) {
                                ForEach(EditorModel.workflowSpaces, id: \.0) { Text($0.1).tag($0.0) }
                            }
                            .accessibilityIdentifier("raw.space")
                            Picker("Depth", selection: $depth) {
                                Text("As Opened").tag(0)
                                Text("8 Bits/Channel").tag(8)
                                Text("16 Bits/Channel").tag(16)
                            }
                            .accessibilityIdentifier("raw.depth")
                        } header: {
                            Text("Workflow")
                        } footer: {
                            Text("Applied when you tap Open.")
                        }
                    }
                }
            }
            .navigationTitle("Develop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .alert("Save Preset", isPresented: $naming) {
                TextField("Name", text: $presetName).accessibilityIdentifier("raw.presetName")
                Button("Cancel", role: .cancel) {}
                Button("Save") { model.saveDevelopPreset(presetName, settings.values) }.accessibilityIdentifier("raw.presetSave")
            }
            .alert("Save Snapshot", isPresented: $namingSnapshot) {
                TextField("Name", text: $snapshotName)
                Button("Cancel", role: .cancel) {}
                Button("Save") { settings.saveSnapshot(snapshotName); tried() }
            }
            .onAppear(perform: load)
            .onAppear { model.liveBegin() }
            .onDisappear {
                model.endPick()
                model.liveKeep()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                if opening { model.developCancel() } else { cancel?() }
                dismiss()
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            // Before and after, as P toggles in Photoshop.
            Button { model.setLivePreview(!model.livePreview) } label: {
                Image(systemName: model.livePreview ? "eye" : "eye.slash")
            }
            .accessibilityLabel("Preview")
            .accessibilityValue(model.livePreview ? "on" : "off")
            .accessibilityIdentifier("raw.preview")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { step(back: true) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(undo.isEmpty).accessibilityIdentifier("raw.undo")
                Button { step(back: false) } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(redo.isEmpty).accessibilityIdentifier("raw.redo")
                Button(role: .destructive) {
                    settings.reset()
                    preset = nil
                    tried()
                } label: { Label("Reset to Default", systemImage: "arrow.counterclockwise") }
                    .accessibilityIdentifier("raw.reset")
                if opening {
                    Button {
                        model.developDone(settings.params())
                        dismiss()
                    } label: { Label("Done (Keep Settings, Don't Open)", systemImage: "checkmark") }
                        .accessibilityIdentifier("raw.done")
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More")
                .accessibilityIdentifier("raw.more")
        }
        if opening {
            ToolbarItem(placement: .confirmationAction) {
                // Tap to open; hold for Open as Object.
                Menu {
                    Button("Open as Object") { open(asObject: true) }
                } label: {
                    Text("Open").bold()
                } primaryAction: {
                    open(asObject: false)
                }
                .accessibilityIdentifier("raw.open")
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                Button("OK") {
                    done(settings.params())
                    dismiss()
                }
                .accessibilityIdentifier("raw.ok")
            }
        }
    }

    private func header(_ name: String) -> some View {
        let off = settings.hidden.contains(name)
        return HStack {
            Button {
                if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
            } label: {
                Label(name, systemImage: expanded.contains(name) ? "chevron.down" : "chevron.right")
            }
            .accessibilityIdentifier("raw.panel.\(name)")
            Spacer()
            // This panel's settings off and on, to compare.
            Button {
                if off { settings.hidden.remove(name) } else { settings.hidden.insert(name) }
                tried()
            } label: {
                Image(systemName: off ? "eye.slash" : "eye")
            }
            .accessibilityLabel("Show \(name)")
            .accessibilityValue(off ? "off" : "on")
            .accessibilityIdentifier("raw.panel.\(name).eye")
        }
        .textCase(nil)
        .font(.subheadline.weight(.semibold))
    }

    @ViewBuilder
    private func content(_ panel: DevelopSettings.Panel) -> some View {
        switch panel.name {
        case "Color":
            Picker("White Balance", selection: Binding(get: { autoWB ? "auto" : settings.asShot ? "asShot" : "custom" }, set: setWhiteBalance)) {
                Text("As Shot").tag("asShot")
                Text("Auto").tag("auto")
                Text("Custom").tag("custom")
            }
            .accessibilityIdentifier("raw.whiteBalance")
            Button {
                pickingWB.toggle()
                if pickingWB { model.beginPick(.preview, prompt: "Tap something that should be gray") { pickWhiteBalance($0) } } else { model.endPick() }
            } label: {
                Label(pickingWB ? "Hold on the image, then let go on something that should be gray" : "White Balance Tool", systemImage: "eyedropper")
            }
            .accessibilityIdentifier("raw.wbPicker")
            ForEach(panel.sliders, id: \.key) { slider($0) }
        case "Curve":
            Picker("Channel", selection: $curveKey) {
                ForEach(DevelopSettings.curveKeys, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("raw.curve.channel")
            CurveGraph(bins: bins, tint: curveTint, points: Binding(get: { settings.curve(curveKey) }, set: { settings.setCurve(curveKey, $0) }),
                       selected: $curvePoint, ended: tried)
                .frame(height: 220)
        case "Color Mixer":
            Picker("Adjust", selection: $mixerKind) {
                ForEach(DevelopSettings.mixerKinds, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("raw.mixer.kind")
            ForEach(DevelopSettings.mixer(mixerKind), id: \.key) { slider($0) }
        default:
            ForEach(panel.sliders, id: \.key) { slider($0) }
        }
    }

    private func slider(_ s: DevelopSlider) -> some View {
        let v = settings[s.key]
        let reset = { settings[s.key] = s.initial; tried() }
        var actions: [(String, () -> Void)] = []
        if autoValue(s.key) != nil { actions.append(("Auto \(s.title)", { applyAuto([s.key]) })) }
        actions.append(("Reset \(s.title)", reset))
        return sliderRow(s.title, value: s.fine ? String(format: "%.2f", v) : "\(Int(v))", key: s.key, reset: reset, actions: actions) {
            Slider(value: Binding(get: { settings[s.key] }, set: { settings[s.key] = $0 }), in: s.range) { editing in
                if !editing { tried() }
            }
        }
    }

    /// A slider under its name and value. Double-tap the name to reset; hold it for `actions`.
    private func sliderRow(_ title: String, value: String, key: String, reset: (() -> Void)? = nil,
                           actions: [(String, () -> Void)] = [], @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                ValueLabel(text: value, width: 48, font: .body)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { reset?() }
            .contextMenu {
                ForEach(actions.indices, id: \.self) { i in Button(actions[i].0, action: actions[i].1) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(value)
            .accessibilityIdentifier("raw.\(key).name")
            control().accessibilityIdentifier("raw.\(key)")
        }
    }

    private var bins: [Int] {
        var b = [Int](repeating: 0, count: 256)
        let c = DevelopSettings.curveKeys.firstIndex { $0.0 == curveKey } ?? 0
        for p in pixels.rgb {
            let v = c == 0 ? 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z : p[c - 1]
            b[min(max(Int(v), 0), 255)] += 1
        }
        return b
    }

    private var curveTint: Color {
        switch curveKey {
        case "pointCurveRed": .red
        case "pointCurveGreen": .green
        case "pointCurveBlue": .blue
        default: .primary
        }
    }

    private func autoValue(_ key: String) -> Double? {
        if key == "temperature" || key == "tint" {
            return DevelopSettings.autoWhiteBalance(pixels.rgb).map { key == "temperature" ? $0.temperature : $0.tint }
        }
        return DevelopSettings.light.contains { $0.key == key } ? DevelopSettings.auto(pixels.rgb)[key] : nil
    }

    private func applyAuto(_ keys: [String]) {
        for k in keys { if let v = autoValue(k) { settings[k] = v } }
        tried()
    }

    private func setWhiteBalance(_ mode: String) {
        switch mode {
        case "asShot":
            settings["temperature"] = 0
            settings["tint"] = 0
        case "auto":
            guard let wb = DevelopSettings.autoWhiteBalance(pixels.rgb) else { return }
            settings["temperature"] = wb.temperature
            settings["tint"] = wb.tint
        default: return
        }
        tried()
        autoWB = mode == "auto"
    }

    /// The colour picked, as the image opened, made gray.
    private func pickWhiteBalance(_ p: CGPoint) {
        pickingWB = false
        guard let image = sampler.snapshot else { return }
        // A 5 by 5 average, so one grain of texture doesn't decide it.
        let (dx, dy) = (1 / CGFloat(max(image.width, 1)), 1 / CGFloat(max(image.height, 1)))
        let around = (-2...2).flatMap { i in (-2...2).compactMap { j in sampler.color(at: CGPoint(x: p.x + CGFloat(i) * dx, y: p.y + CGFloat(j) * dy)) } }
        guard !around.isEmpty, let wb = DevelopSettings.whiteBalance((0..<3).map { c in around.map { $0[c] }.reduce(0, +) / Double(around.count) }) else { return }
        settings["temperature"] = wb.temperature
        settings["tint"] = wb.tint
        tried()
    }

    private func tried() {
        guard loaded else { return }
        if settings != last {
            undo.append(last)
            redo = []
            last = settings
            autoWB = false
        }
        change?(settings.params())
    }

    private func step(back: Bool) {
        guard let s = back ? undo.popLast() : redo.popLast() else { return }
        if back { redo.append(settings) } else { undo.append(settings) }
        (settings, last) = (s, s)
        change?(settings.params())
    }

    private func open(asObject: Bool) {
        model.developOpenImage(settings.params(), asObject: asObject, space: space, depth: depth)
        dismiss()
    }

    private func load() {
        guard !loaded else { return }
        pixels = AutoPixels.load(model, layer: nil)
        sampler = PreviewSampler(model, layer: nil)
        settings = DevelopSettings(initial)
        last = settings
        loaded = true
        // Settings kept from the last time this file opened show at once.
        if opening, !initial.isEmpty { change?(settings.params()) }
    }
}
