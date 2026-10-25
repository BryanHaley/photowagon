import SwiftUI

// MARK: - Tool bar

/// Tools grouped like Photoshop's toolbox. Tapping a group picks its current tool and lists the
/// group's tools in the context bar; touch and hold for their names and descriptions. Scrolls
/// sideways on a phone.
struct ToolBar: View {
    @ObservedObject var model: EditorModel
    /// A column down the left (landscape), as Photoshop's Tools panel.
    var vertical = false
    /// The tool each group shows (the last one picked in it).
    @State private var shown: [Int: Tool] = [:]
    /// The tool whose long-press tip is showing.
    @State private var tip: Tool?

    var body: some View {
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        let tools = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        stack {
            ScrollViewReader { reader in
                ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
                    tools {
                        ForEach(Tool.groups.indices, id: \.self) { i in
                            group(i).id(i)
                        }
                    }
                    .padding(vertical ? .vertical : .horizontal, 8)
                }
                .accessibilityIdentifier("toolbar")
                .onAppear {
                    if let i = Tool.groups.firstIndex(where: { $0.contains(model.tool) }) { reader.scrollTo(i) }
                }
                .onChange(of: model.tool) { _, t in
                    // Keep the current tool in view (keyboard tool changes too).
                    if let i = Tool.groups.firstIndex(where: { $0.contains(t) }) {
                        shown[i] = t
                        withAnimation { reader.scrollTo(i) }
                    }
                }
            }
            ColorWell(model: model).tutorialTarget(.colors).padding(vertical ? .vertical : .horizontal, 8)
        }
        .padding(vertical ? .horizontal : .top, vertical ? 4 : 6)
        .padding(vertical ? .vertical : .bottom, 4)
        .background(Color(white: 0.11))
        .tutorialTarget(.toolbar)
    }

    @ViewBuilder
    private func group(_ i: Int) -> some View {
        let tools = Tool.groups[i]
        let current = tools.contains(model.tool) ? model.tool : shown[i] ?? tools[0]
        if tools.count == 1 {
            ToolIcon(tool: current, selected: model.tool == current, more: false)
                .contentShape(Rectangle())
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("group.\(tools[0].title)")
                .onTapGesture {
                    model.tool = current
                    model.pickingGroup = nil
                }
                .onLongPressGesture(minimumDuration: 0.4) { tip = current }
                .popover(isPresented: Binding(get: { tip == current }, set: { if !$0 { tip = nil } })) {
                    ToolTip(tool: current)
                }
        } else {
            Menu { items(tools) } label: {
                ToolIcon(tool: current, selected: tools.contains(model.tool), more: true)
            } primaryAction: {
                model.tool = current
                // A second tap closes the list.
                model.pickingGroup = model.pickingGroup == i ? nil : i
            }
            .accessibilityLabel(current.title)
            .accessibilityIdentifier("group.\(tools[0].title)")
        }
    }

    @ViewBuilder
    private func items(_ tools: [Tool]) -> some View {
        ForEach(tools) { t in
            Button {
                model.tool = t
                model.pickingGroup = nil
            } label: {
                Label(t.title, systemImage: t.symbol)
                Text(t.help)
            }
        }
        if tools.contains(.hand) {
            Divider()
            ForEach(model.viewActions) { a in
                Button(action: a.run) {
                    Label(a.title, systemImage: a.symbol)
                    Text(a.help)
                }
            }
        }
        if tools.contains(.quickSelect) {
            Divider()
            Button { model.selectSubject(mode: model.selectionMode.rawValue) } label: {
                Label("Select Subject", systemImage: "person.crop.rectangle")
            }
        }
    }
}

/// Closes the sheet it is in.
struct DoneButton: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePanel) private var closePanel
    var body: some View { Button("Done") { closePanel?() ?? dismiss() }.accessibilityIdentifier("sheet.done") }
}

extension EnvironmentValues {
    /// Closes a panel shown beside the canvas (an iPad inspector column); sheets use `dismiss`.
    @Entry var closePanel: (() -> Void)?
}

/// A view shortcut listed with the view tools.
struct ViewAction: Identifiable {
    let title: String
    let symbol: String
    let help: String
    let run: () -> Void
    var id: String { title }
}

extension EditorModel {
    var viewActions: [ViewAction] {
        [
            ViewAction(title: "Fit on Screen", symbol: "viewfinder.rectangular", help: "Show the whole image.") { self.fit() },
            ViewAction(title: "Actual Size", symbol: "1.magnifyingglass", help: "One image pixel per screen pixel.") { self.zoom(by: 1 / self.view.zoom) },
            ViewAction(title: "Straighten View", symbol: "level", help: "Undo the view's rotation.") { self.straighten() },
        ]
    }
}

/// A tool's name and how to use it.
struct ToolTip: View {
    let tool: Tool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(tool.title, systemImage: tool.symbol).font(.headline)
            Text(tool.help).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }
}

struct ToolIcon: View {
    let tool: Tool
    let selected: Bool
    let more: Bool
    var body: some View {
        Image(systemName: tool.symbol)
            .font(.system(size: 19, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.black : Color.white)
            .frame(width: 42, height: 42)
            .background(selected ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            .overlay(alignment: .bottomTrailing) {
                if more {
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(selected ? Color.black : Color.gray)
                        .padding(5)
                }
            }
            .accessibilityLabel(tool.title)
    }
}

struct ColorWell: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color(model.backgroundColor))
                .frame(width: 24, height: 24).overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray, lineWidth: 1))
                .offset(x: 12, y: 12)
                .accessibilityHidden(true)
            ColorPicker("Foreground", selection: Binding(get: { Color(model.foreground) }, set: { model.setForeground(UIColor($0)) }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 28, height: 28)
            // The swap's tap area goes above the picker: iOS 27 grows the picker's touch area over
            // the background swatch.
            Color.clear
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .offset(x: 24, y: 24)
                .onTapGesture { model.swapColors() }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Swap Colors")
                .accessibilityIdentifier("colors.swap")
                .accessibilityAction { model.swapColors() }
        }
        .frame(width: 40, height: 40)
    }
}

// MARK: - Context bar

/// What you can do now: finish work in progress, act on the selection, or the current tool's
/// options.
struct ContextBar: View {
    @ObservedObject var model: EditorModel
    @State private var showAngle = false

    var body: some View {
        Group {
            // A sideways scroll would take a slider's drag: rows with sliders fit without one.
            if hasSlider {
                HStack(spacing: 10) { content }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { content }
                        .padding(.horizontal, 10)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(height: hasSlider ? 56 : 48)
        .background(Color(white: 0.11))
    }

    @ViewBuilder
    private var content: some View {
        // Work in progress (a transform, crop, polygon) comes first: it needs Commit or Cancel.
        if model.hasPending {
            chip("Commit", "checkmark") { model.commitPending() }
            chip("Cancel", "xmark") { model.cancelPending() }
            if !model.quad.isEmpty {
                chip("Undo Last Point", "arrow.uturn.backward") { model.undoLastPoint() }
            }
            if model.fluidWarp != nil {
                fluidWarpOptions
            } else if model.transform != nil {
                transformOptions
            } else if model.puppet != nil {
                puppetOptions
            } else if model.tool == .crop {
                cropOptions
            } else {
                Text(pendingHint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if let g = model.pickingGroup, Tool.groups.indices.contains(g) {
            toolRow(Tool.groups[g])
        } else if model.tool.pathTool {
            chip("Make Selection", "rectangle.dashed") { model.run("path.toSelection", ["name": "work", "mode": model.selectionMode.rawValue]) }
            chip("Fill Path", "drop.fill") { model.run("path.fill", ["name": "work"]) }
            chip("Stroke Path", "pencil.line") { model.run("path.stroke", ["name": "work", "tool": "brush"]) }
            chip("Shape Layer", "square.on.circle") { pathToShape() }
            chip("Delete Path", "trash") {
                model.run("path.delete", ["name": "work"])
                model.loadWorkPath()
            }
        } else if model.doc?.hasSelection == true, model.tool.selects || model.tool.typeTool || [.move, .patch, .contentAwareMove].contains(model.tool) {
            chip("Deselect", "xmark") { model.run("select.deselect") }
            chip("Invert", "arrow.left.arrow.right") { model.run("select.inverse") }
            chip("Fill", "drop.fill") { model.run("edit.fill", ["contents": "foreground"]) }
            chip("Quick Fill", Tool.remove.symbol) { model.runInBackground("edit.deleteAndFillSelection") }
            chip("AI Remove", Tool.aiRemove.symbol) { model.aiRemove(.selection) }
            chip("Delete", "trash") { model.run("edit.clear") }
            chip("Copy", "doc.on.doc") { model.run("edit.copy") }
            pasteChip
            chip("Select All", "rectangle.fill") { model.run("select.all") }
            chip("Copy to Layer", "square.on.square") { model.run("layer.new.layerViaCopy") }
            chip("Mask", "circle.lefthalf.filled") { model.addMask() }
            chip("Transform", "arrow.up.left.and.arrow.down.right") { model.beginTransform() }
            if model.marqueeBox != nil { marqueeFields }
        } else if model.tool.selects {
            Picker("Mode", selection: $model.selectionMode) {
                ForEach(SelectionMode.allCases) { m in Image(systemName: m.symbol).tag(m) }
            }
            .pickerStyle(.segmented)
            .frame(width: [.quickSelect, .magicWand].contains(model.tool) ? 105 : 140)
            chip("Select All", "rectangle.fill") { model.run("select.all") }
            pasteChip
            if model.tool == .magicWand {
                tolerance
            } else if model.tool == .quickSelect {
                sizeSlider
                toggle("Sample All Layers", "square.3.layers.3d", $model.sampleAllLayers)
                toggle("Enhance Edge", "scribble.variable", $model.enhanceEdge)
                chip("Subject", "person.crop.rectangle") { model.selectSubject(mode: model.selectionMode.rawValue) }
            } else if [.marquee, .ellipse, .lasso, .polygonLasso].contains(model.tool) {
                edgeOptions
            } else {
                if model.tool == .objectSelect {
                    toggle("Object Finder", "sparkle.magnifyingglass", $model.objectFinder)
                    toggle("Show All Objects", "square.dashed.inset.filled", $model.showAllObjects).disabled(!model.objectFinder)
                }
                chip("Subject", "person.crop.rectangle") { model.selectSubject(mode: model.selectionMode.rawValue) }
            }
        } else if model.tool.hasTolerance {
            tolerance
        } else if model.tool == .gradient {
            gradientOptions
        } else if model.tool == .polygon {
            Text("Sides").font(.caption).foregroundStyle(.secondary)
            ValueLabel(text: "\(model.polygonSides)", width: 26)
            Stepper("Sides", value: $model.polygonSides, in: 3...100).labelsHidden()
        } else if model.tool == .ruler, let (a, b) = model.ruler {
            let (dx, dy) = (Double(b.x - a.x), Double(b.y - a.y))
            Text(String(format: "W %6.0f  H %6.0f  L %7.1f px  A %6.1f°", dx, dy, hypot(dx, dy), -atan2(dy, dx) * 180 / .pi))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        } else if model.tool == .zoomIn {
            toggle("Scrubby Zoom", "arrow.left.and.right.square", $model.scrubbyZoom)
            Text(model.scrubbyZoom ? "Drag right to zoom in, left to zoom out" : "Drag a box to zoom to it")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if model.tool == .eyedropper {
            eyedropperOptions
        } else if Tool.groups[0].contains(model.tool) {
            Text(model.tool.help).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if model.tool == .move {
            moveOptions
        } else if model.tool.typeTool {
            TypeOptions(model: model)
        } else if model.tool.brushOptions {
            // As much as the row has room for; the rest under "…".
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { brushRow(.all) }
                HStack(spacing: 10) { brushRow(.sliders) }
                HStack(spacing: 10) { brushRow(.fewest) }
            }
            .popover(isPresented: $showAngle) {
                BrushAngleDial(model: model).presentationCompactAdaptation(.popover)
            }
        } else if model.tool.sized {
            sizeSlider
            if model.tool.hasOpacity {
                PropSlider(title: model.tool.opacityTitle, value: "\(Int((model.opacity * 100).rounded()))%",
                           position: Binding(get: { model.opacity }, set: { model.setBrush("opacity", max($0, 0.01)) }))
            }
            if model.tool.hasHardness {
                PropSlider(title: "Hardness", value: "\(Int((model.hardness * 100).rounded()))%",
                           position: Binding(get: { model.hardness }, set: { model.setBrush("hardness", $0) }))
            }
            if [.spotHeal, .remove, .aiRemove].contains(model.tool) {
                toggle("Sample All Layers", "square.3.layers.3d", $model.sampleAllLayers)
            }
            if [.remove, .aiRemove].contains(model.tool) {
                toggle("Remove After Each Stroke", "checkmark.circle", $model.removeEachStroke)
            }
            if model.tool == .aiRemove {
                toggle("Match Colour", "paintpalette", $model.aiMatchColor)
                if model.doc?.hasSelection == true {
                    chip("Remove Selection", Tool.aiRemove.symbol) { model.aiRemove(.selection) }
                }
            }
            toggle("Straight Line", "line.diagonal", $model.straightLine)
        } else if model.tool == .crop {
            cropOptions
        } else if let hint = hint {
            Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// Fluid Warp: its tool, brush size and pressure; Amount and Restore All under "…".
    @ViewBuilder
    private var fluidWarpOptions: some View {
        if let w = model.fluidWarp {
            let tool = FluidWarp.tools.first { $0.id == w.tool } ?? FluidWarp.tools[0]
        Menu {
                Picker("Tool", selection: Binding(get: { w.tool }, set: { model.fluidWarp?.tool = $0 })) {
                    ForEach(FluidWarp.tools, id: \.id) { t in Label(t.title, systemImage: t.symbol).tag(t.id) }
                }
            } label: { chipLabel(tool.title, tool.symbol) }
            .accessibilityIdentifier("warp.tool")
            PropSlider(title: "Size", value: "\(Int(w.size))",
                       position: Binding(get: { sqrt((w.size - 10) / 990) }, set: { model.fluidWarp?.size = (10 + $0 * $0 * 990).rounded() }))
            PropSlider(title: "Pressure", value: "\(Int(w.pressure))%",
                       position: Binding(get: { w.pressure / 100 }, set: { model.fluidWarp?.pressure = max(($0 * 100).rounded(), 1) }))
        Menu {
                Picker("Amount", selection: Binding(get: { w.amount }, set: { model.fluidWarp?.amount = $0 })) {
                    ForEach([100.0, 90, 75, 50, 25, 0], id: \.self) { Text("Amount \(Int($0))%").tag($0) }
                }
                Button("Restore All", role: .destructive) {
                    model.fluidWarp?.strokes = []
                    model.fluidWarp?.amount = 100
                }
            } label: { chipLabel("More", "ellipsis") }
            .accessibilityIdentifier("warp.more")
        }
    }

    /// Crop: Straighten (draw a line along what should be level) and Delete Cropped Pixels.
    @ViewBuilder
    private var cropOptions: some View {
        toggle("Straighten", "level", $model.straightening)
        toggle("Delete Cropped Pixels", "trash.square", $model.deleteCroppedPixels)
        if model.straightening {
            Text("Draw a line along what should be level").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if model.cropAngle != 0 {
            Text(String(format: "%.1f°", model.cropAngle)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        } else {
            Text(model.cropRect == nil ? "Drag the crop area, or tap for the whole image" : "Drag a corner or edge, past the image to add canvas")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: Tool options

    /// Puppet Warp: mode, density, expansion, the mesh, and the selected pin's rotation.
    @ViewBuilder
    private var puppetOptions: some View {
        if let p = model.puppet {
        Menu {
                Picker("Mode", selection: Binding(get: { p.mode }, set: { model.puppet?.mode = $0 })) {
                    ForEach(["rigid", "normal", "distort"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                Picker("Density", selection: Binding(get: { p.density }, set: { model.puppet?.density = $0 })) {
                    ForEach(["fewer", "normal", "more"], id: \.self) { Text("\($0.capitalized) Points").tag($0) }
                }
            } label: {
                Text("\(p.mode.capitalized) · \(p.density.capitalized)").font(.caption)
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityIdentifier("puppet.mode")
            Text("Expansion").font(.caption).foregroundStyle(.secondary)
            ValueLabel(text: "\(Int(p.expansion)) px", width: 44)
            Stepper("Expansion", value: Binding(get: { p.expansion }, set: { model.puppet?.expansion = $0 }), in: -20...50).labelsHidden()
                .accessibilityIdentifier("puppet.expansion")
            toggle("Show Mesh", "circle.grid.cross", Binding(get: { p.showMesh }, set: { model.puppet?.showMesh = $0 }))
            if let i = p.selected, p.pins.indices.contains(i) {
                PropSlider(title: "Rotate", value: p.pins[i].rotate.map { "\(Int($0))°" } ?? "Auto",
                           position: Binding(get: { ((p.pins[i].rotate ?? 0) + 180) / 360 },
                                             set: { model.puppet?.pins[i].rotate = ($0 * 360 - 180).rounded() }))
                chip("Delete Pin", "pin.slash") {
                    model.puppet?.pins.remove(at: i)
                    model.puppet?.selected = nil
                }
            } else {
                Text(p.pins.isEmpty ? "Tap to add pins, then drag one" : "Tap a pin to select it").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var moveOptions: some View {
        Group {
            toggle("Auto-Select", "cursorarrow.rays", $model.autoSelect)
            toggle("Copy While Moving", "plus.square.on.square", $model.moveCopies)
        Menu {
                Section("Align to Canvas") {
                    align("Left Edges", "align.horizontal.left", "leftEdges")
                    align("Horizontal Centers", "align.horizontal.center", "horizontalCenters")
                    align("Right Edges", "align.horizontal.right", "rightEdges")
                    align("Top Edges", "align.vertical.top", "topEdges")
                    align("Vertical Centers", "align.vertical.center", "verticalCenters")
                    align("Bottom Edges", "align.vertical.bottom", "bottomEdges")
                }
            } label: { chipLabel("Align", "align.horizontal.center") }
            .accessibilityIdentifier("move.align")
            chip("Free Transform", "arrow.up.left.and.arrow.down.right") { model.beginTransform() }
        }
    }

    private func align(_ title: String, _ symbol: String, _ edge: String) -> some View {
        Button { model.run("layer.align.\(edge)", ["to": model.doc?.hasSelection == true ? "auto" : "canvas"]) } label: { Label(title, systemImage: symbol) }
    }

    private var transformOptions: some View {
        Group {
            toggle("Keep Proportions", "link", $model.keepProportions)
        Menu {
                ForEach(0..<3) { row in
                    Section {
                        ForEach(0..<3) { col in
                            Button("\(["Top", "Middle", "Bottom"][row]) \(["Left", "Centre", "Right"][col])") {
                                if var t = model.transform { t.setPivot(t.gridPoint(col, row)); model.transform = t }
                            }
                        }
                    }
                }
            } label: { chipLabel("Reference Point", "smallcircle.filled.circle") }
            toggle("Scale From Reference Point", "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", $model.scaleFromPivot)
            toggle("Snap Rotation to 15°", "angle", $model.snapRotation)
            chip("Rotate 90° Left", "rotate.left") { model.rotateTransform(by: -90) }
            chip("Rotate 90° Right", "rotate.right") { model.rotateTransform(by: 90) }
            angleField
            chip("Flip Horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                if var t = model.transform { t.sx = -t.sx; model.transform = t }
            }
            chip("Flip Vertical", "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                if var t = model.transform { t.sy = -t.sy; model.transform = t }
            }
        }
    }

    /// The marquee box's X, Y, W, H in whole pixels, typed, and its ratio lock.
    private var marqueeFields: some View {
        HStack(spacing: 6) {
            toggle("Lock Ratio", "lock.rectangle", $model.marqueeLockRatio)
            ForEach([("X", \MarqueeBox.x), ("Y", \MarqueeBox.y), ("W", \MarqueeBox.w), ("H", \MarqueeBox.h)], id: \.0) { name, field in
                Text(name).font(.caption).foregroundStyle(.secondary)
                TextField(name, value: Binding(get: { model.marqueeBox?[keyPath: field] ?? 0 }, set: { model.setMarquee(field, $0) }),
                          format: .number.grouping(.never))
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(width: scaled(56))
                    .accessibilityIdentifier("marquee.\(name)")
            }
        }
        .font(.callout.monospacedDigit())
    }

    /// The box's angle in degrees, typed.
    private var angleField: some View {
        let degrees = Binding<Double>(
            get: { Double((model.transform?.angle ?? 0) * 180 / .pi).rounded() },
            set: { v in if var t = model.transform { t.angle = Float(v) * .pi / 180; model.transform = t } })
        return HStack(spacing: 2) {
            TextField("", value: degrees, format: .number.precision(.fractionLength(0)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(width: scaled(48))
                .accessibilityIdentifier("transform.angle")
            Text("°").foregroundStyle(.secondary)
        }
        .font(.callout.monospacedDigit())
    }

    private var gradientOptions: some View {
        Group {
        Menu {
                ForEach(model.gradientPresets, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1, id: \.self) { name in
                            Button { model.gradientPreset = name } label: {
                                if name == model.gradientPreset { Label(name, systemImage: "checkmark") } else { Text(name) }
                            }
                        }
                    }
                }
            } label: { chipLabel("Gradient: \(model.gradientPreset)", "square.tophalf.filled", wide: true) }
            .accessibilityIdentifier("gradient.preset")
            Picker("Style", selection: $model.gradientStyle) {
                ForEach(GradientStyle.allCases) { Image(systemName: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            toggle("Reverse", "arrow.left.arrow.right", $model.gradientReverse)
        }
    }

    /// How much of a brush tool's options its row shows.
    enum BrushRow { case all, sliders, fewest }

    /// The brush tools' row: every option when there's room, else the sliders that fit with the
    /// rest under "…" (Flow, Smoothing and Hardness are in Brush Settings).
    @ViewBuilder
    private func brushRow(_ row: BrushRow) -> some View {
        if [.brush, .pencil, .eraser].contains(model.tool) { brushTips }
        if row == .all, [.brush, .pencil].contains(model.tool) { brushMode }
        sizeSlider.fitted
        if model.tool.hasOpacity {
            PropSlider(title: model.tool.opacityTitle, value: "\(Int((model.opacity * 100).rounded()))%",
                       position: Binding(get: { model.opacity }, set: { model.setBrush("opacity", max($0, 0.01)) })).fitted
        }
        if row != .fewest, model.tool.hasHardness {
            PropSlider(title: "Hardness", value: "\(Int((model.hardness * 100).rounded()))%",
                       position: Binding(get: { model.hardness }, set: { model.setBrush("hardness", $0) })).fitted
        }
        if row == .all {
            if model.tool != .pencil {
                PropSlider(title: "Flow", value: "\(Int((model.flow * 100).rounded()))%",
                           position: Binding(get: { model.flow }, set: { model.setBrush("flow", max($0, 0.01)) })).fitted
            }
            PropSlider(title: "Smoothing", value: "\(Int((model.smoothing * 100).rounded()))%",
                       position: Binding(get: { model.smoothing }, set: { model.setBrush(path: "smoothing.amount", $0) })).fitted
            toggle("Pressure for Size", "pencil.tip", pressureSize)
            toggle("Pressure for Opacity", "circle.dotted", pressureOpacity)
            if [.brush, .pencil, .eraser].contains(model.tool) {
                Menu { symmetryPicker } label: { chipLabel("Symmetry", "square.split.2x1", wide: !model.symmetry.isEmpty) }
                    .accessibilityIdentifier("brush.symmetry")
            }
            Button { showAngle = true } label: { chipLabel("Brush Angle", "dial.low") }
                .accessibilityIdentifier("brush.angle")
            Button { model.showBrushSettings = true } label: { chipLabel("Brush Settings", "slider.horizontal.3") }
                .accessibilityIdentifier("brush.settings")
        }
        if row == .all { toggle("Straight Line", "line.diagonal", $model.straightLine) }
        if row != .all {
            Menu {
                if [.brush, .pencil].contains(model.tool) { Menu("Mode: \(EditorModel.modeTitle(model.brushMode))") { modeItems } }
                Toggle("Pressure for Size", isOn: pressureSize)
                Toggle("Pressure for Opacity", isOn: pressureOpacity)
                if [.brush, .pencil, .eraser].contains(model.tool) { Menu("Symmetry") { symmetryPicker } }
                Toggle("Straight Line", isOn: $model.straightLine)
                Button { showAngle = true } label: { Label("Brush Angle…", systemImage: "dial.low") }
                Button { model.showBrushSettings = true } label: { Label("Brush Settings…", systemImage: "slider.horizontal.3") }
            } label: { chipLabel("Brush Options", "ellipsis") }
            .accessibilityIdentifier("brush.more")
        }
    }

    private var pressureSize: Binding<Bool> { Binding(get: { model.pressureSize }, set: { model.setBrush(path: "pressureSize", $0) }) }
    private var pressureOpacity: Binding<Bool> { Binding(get: { model.pressureOpacity }, set: { model.setBrush(path: "pressureOpacity", $0) }) }

    private var symmetryPicker: some View {
        Picker("Symmetry", selection: Binding(get: { model.symmetry }, set: { model.setSymmetry($0) })) {
            Text("Off").tag("")
            ForEach(EditorModel.symmetryModes, id: \.0) { Text($0.1).tag($0.0) }
        }
    }

    @ViewBuilder
    private var modeItems: some View {
        ForEach(blendModes, id: \.self) { group in
            Section {
                ForEach(group, id: \.self) { m in
                    Button { model.setBrush(path: "mode", EditorModel.engineMode(m)) } label: {
                        if EditorModel.engineMode(m) == model.brushMode { Label(m, systemImage: "checkmark") } else { Text(m) }
                    }
                }
            }
        }
    }

    /// The brush's blend mode.
    private var brushMode: some View {
        Menu { modeItems
        } label: { chipLabel("Mode: \(EditorModel.modeTitle(model.brushMode))", "circle.lefthalf.filled", wide: true) }
        .accessibilityIdentifier("brush.mode")
    }

    private var brushTips: some View {
        Menu {
            ForEach(model.brushGroups, id: \.name) { g in
                Menu(g.name) {
                    ForEach(g.presets, id: \.self) { name in
                        Button(name) { model.run("tools.setBrush", ["preset": name]) }
                    }
                }
            }
            Divider()
            Button { model.request = .importBrushTips } label: { Label("Import Brush Tips…", systemImage: "square.and.arrow.down") }
        } label: { chipLabel("Brush Tip", "paintbrush.pointed") }
        .accessibilityIdentifier("brush.tips")
    }

    private func toggle(_ title: String, _ symbol: String, _ value: Binding<Bool>) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15))
            .foregroundStyle(value.wrappedValue ? Color.black : Color.white)
            .frame(width: 40, height: 32)
            .background(value.wrappedValue ? Color.white : Color(white: 0.2), in: RoundedRectangle(cornerRadius: 8))
            .namedButton(title, model: model) { value.wrappedValue.toggle() }
            .accessibilityValue(value.wrappedValue ? "on" : "off")
    }

    private func chipLabel(_ title: String, _ symbol: String, wide: Bool = false) -> some View {
        Group {
            if wide {
                Label(title, systemImage: symbol).font(.caption).lineLimit(1).padding(.horizontal, 10)
            } else {
                Image(systemName: symbol).font(.system(size: 16)).frame(width: 40)
            }
        }
        .frame(height: 32)
        .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(title)
    }

    /// The group's tools; picking one shows its options.
    private func toolRow(_ tools: [Tool]) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(tools) { t in
                    Image(systemName: t.symbol)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 32)
                        .background(t == model.tool ? Color(white: 0.38) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .namedButton(t.title, model: model) {
                            model.tool = t
                            model.pickingGroup = nil
                        }
                        .accessibilityIdentifier("row.\(t.title)")
                }
            }
            .padding(2)
            .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 9))
            if tools.contains(.hand) {
                ForEach(model.viewActions) { a in chip(a.title, a.symbol, action: a.run) }
            } else {
                Text(model.tool.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Brush size, with small sizes given more travel.
    private var sizeSlider: some View {
        PropSlider(title: "Size", value: "\(Int(model.brushSize))",
                   position: Binding(get: { pow((model.brushSize - 1) / 499, 1 / 2.2) },
                                     set: {
                                         model.setBrush("size", (1 + pow($0, 2.2) * 499).rounded())
                                         model.sizePreview(editing: true)
                                     })) { editing in
            model.sizePreview(editing: editing)
        }
    }

    /// The bar shows a slider now.
    private var hasSlider: Bool {
        if model.fluidWarp != nil { return true }
        if model.pickingGroup != nil || model.hasPending || model.tool.pathTool { return false }
        let selectionBar = model.doc?.hasSelection == true
            && (model.tool.selects || model.tool.typeTool || [.move, .patch, .contentAwareMove].contains(model.tool))
        return !selectionBar && (model.tool.hasTolerance || model.tool.sized)
    }

    /// The Marquee and Lasso tools' Feather and Anti-alias.
    private var edgeOptions: some View {
        HStack(spacing: 6) {
            Text("Feather").font(.caption).foregroundStyle(.secondary)
            TextField("", value: $model.selectionFeather, format: .number.precision(.fractionLength(0)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(width: scaled(40))
                .font(.callout.monospacedDigit())
                .accessibilityIdentifier("option.feather")
            Text("px").font(.caption).foregroundStyle(.secondary)
            toggle("Anti-alias", "circle.dotted.circle", $model.antiAlias)
        }
    }

    /// Photoshop's Sample Size and Sample (also used where a colour is picked from the image).
    private var eyedropperOptions: some View {
        HStack(spacing: 8) {
            Picker("Sample Size", selection: $model.sampleSize) {
                ForEach(EditorModel.sampleSizes, id: \.value) { Text($0.label).tag($0.value) }
            }
            .accessibilityIdentifier("option.sampleSize")
            Picker("Sample", selection: $model.sampleLayers) {
                ForEach(EditorModel.sampleLayerChoices, id: \.value) { Text($0.label).tag($0.value) }
            }
            .accessibilityIdentifier("option.sampleLayers")
        }
        .font(.caption)
    }

    private var tolerance: some View {
        HStack(spacing: 6) {
            Text("Tolerance").font(.caption).foregroundStyle(.secondary)
            ValueLabel(text: "\(Int(model.tolerance))", width: 26)
            Slider(value: $model.tolerance, in: 0...255).frame(minWidth: 70, maxWidth: 110).accessibilityIdentifier("option.Tolerance")
            Toggle(isOn: $model.contiguous) { Image(systemName: "point.3.connected.trianglepath.dotted") }
                .toggleStyle(.button).accessibilityLabel("Contiguous")
            Toggle(isOn: $model.sampleAllLayers) { Image(systemName: "square.3.layers.3d") }
                .toggleStyle(.button).accessibilityLabel("Sample All Layers")
        }
    }

    private var pendingHint: String {
        if model.fluidWarp != nil { return "Drag to warp; two fingers zoom and pan" }
        if model.transform != nil { return "Drag inside to move, a corner to scale, the round handle or outside to rotate" }
        if model.tool == .perspectiveCrop { return "Tap the four corners" }
        if model.tool == .polygonLasso { return "Tap points; tap the first to close; drag a point to move it" }
        if !model.removeStrokes.isEmpty { return "Paint more, then Commit to remove it all" }
        return "Drag to set or move the crop"
    }

    private var hint: String? {
        switch model.tool {
        case .perspectiveCrop: "Tap the four corners of the area"
        case .crop: "Drag the crop area, or tap for the whole image"
        case .slice, .frame, .artboard: "Drag an area"
        case .sliceSelect: "Tap a slice"
        case .colorSampler: "Tap to add a sampler"
        case .note: "Tap to add a note"
        case .count: "Tap to count"
        case .redEye: "Tap a red eye"
        case .patch, .contentAwareMove: "Select an area, then drag where to take it from"
        case .eyedropper: "Tap or drag to pick a colour"
        case .ruler: "Drag to measure"
        case _ where model.tool.typeTool: "Tap for a line of text, drag for a text box"
        case _ where model.tool.shapeTool: "Drag to draw the shape"
        default: nil
        }
    }

    /// The work path as a new shape layer.
    private func pathToShape() {
        guard let out = try? model.editor.execute(id: "path.info", params: json(["name": "work"])),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let path = obj["path"]
        else { return }
        model.run("shape.create", ["kind": "path", "path": path, "fill": model.foreground.hex])
    }

    /// Paste, once something is copied (from this image or another open one).
    @ViewBuilder private var pasteChip: some View {
        if model.editor.commandEnabled(id: "edit.paste") {
            chip("Paste", "doc.on.clipboard") { model.run("edit.paste") }
        }
    }

    private func chip(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .frame(width: 40, height: 32)
            .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 8))
            .namedButton(title, model: model, action)
    }
}

extension View {
    /// An icon that acts as a button: a tap runs `action`, touch and hold shows `title`.
    func namedButton(_ title: String, model: EditorModel, _ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .gesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in model.hint = title }
                .exclusively(before: TapGesture().onEnded { action() }))
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
            .accessibilityAction { action() }
    }
}

// MARK: - Layers

/// A layer's name or text being edited in the Layers panel.
struct LayerTextEdit: Identifiable {
    let layer: UInt64
    let title: String
    var text: String
    let apply: (String) -> Void
    var id: UInt64 { layer }
}

/// Layers panel › Thumbnail Size, as in Photoshop's Panel Options.
enum ThumbnailSize: String, CaseIterable, Identifiable {
    case none = "None", small = "Small", medium = "Medium", large = "Large"
    var id: String { rawValue }
    var side: CGFloat {
        switch self {
        case .none: 0
        case .small: 24
        case .medium: 36
        case .large: 64
        }
    }
}

// MARK: - History

/// Every step so far; tap one to go back to it (the later ones stay, greyed, until you do
/// something new).
struct HistoryPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        NavigationStack {
            List {
                let past = model.history.past
                ForEach(Array(past.enumerated()), id: \.offset) { i, name in
                    row(name, index: i, current: i == past.count - 1, redo: false)
                }
                ForEach(Array(model.history.redo.enumerated()), id: \.offset) { i, name in
                    row(name, index: past.count + i, current: false, redo: true)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { DoneButton() } }
        }
    }

    private func row(_ name: String, index: Int, current: Bool, redo: Bool) -> some View {
        Button { model.run("history.selectState", ["state": index]) } label: {
            HStack {
                Text(name).foregroundStyle(redo ? .secondary : .primary)
                Spacer()
                if current { Image(systemName: "arrowtriangle.left.fill").font(.caption) }
            }
        }
        .listRowBackground(current ? Color.accentColor.opacity(0.25) : nil)
        .accessibilityIdentifier("history.\(index)")
    }
}

// MARK: - Properties

/// The active layer's properties and quick actions.
struct PropertiesPanel: View {
    @ObservedObject var model: EditorModel
    @Environment(\.horizontalSizeClass) private var width

    var body: some View {
        Group {
            if let a = model.activeLayer, a.hasMask, model.maskTarget {
                NavigationStack {
                    MaskProperties(model: model, layer: a.id)
                        .toolbar { ToolbarItem(placement: .topBarLeading) { DoneButton() } }
                }
            } else if let a = model.activeLayer, a.adjustment != nil || ["Fill", "Shape"].contains(a.kind) {
                NavigationStack {
                    VStack(spacing: 0) {
                        if width != .regular { PreviewPane(model: model) }
                        LayerPropertiesContent(model: model, edit: LayerEdit(layer: a.id), inPanel: true)
                            .id(a.id)
                    }
                    .toolbar { ToolbarItem(placement: .topBarLeading) { DoneButton() } }
                }
            } else {
                layerInfo
            }
        }
        // Dragging in the image adjusts only while Properties is open.
        .onDisappear { model.targetedAdjust = nil }
    }

    private var layerInfo: some View {
        NavigationStack {
            Form {
                if let a = model.activeLayer {
                    Section(a.kind + " Layer") {
                        Text(a.name)
                        if let d = model.doc { Text("Document: \(d.width) × \(d.height) px").foregroundStyle(.secondary) }
                    }
                    Section("Quick Actions") {
                        Button { model.removeBackground() } label: { Label("Remove Background", systemImage: "person.crop.rectangle.badge.xmark") }
                            .accessibilityIdentifier("properties.removeBackground")
                        Button { model.selectSubject(mode: "replace") } label: { Label("Select Subject", systemImage: "person.crop.rectangle") }
                    }
                    if a.hasMask {
                        Section("Mask") {
                            Button { model.targetLayer(a.id, mask: true) } label: { Label("Mask Properties", systemImage: "slider.horizontal.3") }
                            Button { model.run("layer.layerMask.enabled") } label: { Label("Disable / Enable Mask", systemImage: "eye.slash") }
                            Button { model.run("layer.layerMask.apply") } label: { Label("Apply Mask", systemImage: "checkmark.circle") }
                            Button(role: .destructive) { model.run("layer.layerMask.delete") } label: { Label("Delete Mask", systemImage: "trash") }
                        }
                    }
                } else {
                    Text("No layer selected").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Properties")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { DoneButton() } }
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 6
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color(white: 0.8)))
                }
            }
        }
        .background(Color.white)
    }
}

// MARK: - Adjustments

/// Adjustment layers with live sliders: the first change adds the layer, later changes edit it
/// (one undo step). Cancel takes it out again.
struct AdjustPanel: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case brightnessContrast = "Brightness/Contrast", hueSaturation = "Hue/Saturation"
        var id: String { rawValue }
        var command: String {
            self == .brightnessContrast ? "layer.newAdjustmentLayer.brightnessContrast" : "layer.newAdjustmentLayer.hueSaturation"
        }
    }

    @State private var kind = Kind.brightnessContrast
    @State private var values: [String: Double] = [:]
    @State private var steps = 0
    @State private var key = UUID().uuidString

    var body: some View {
        NavigationStack {
            Form {
                Picker("Adjustment", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .disabled(steps > 0)
                switch kind {
                case .brightnessContrast:
                    slider("Brightness", "brightness", -150...150)
                    slider("Contrast", "contrast", -50...100)
                case .hueSaturation:
                    slider("Hue", "hue", -180...180)
                    slider("Saturation", "saturation", -100...100)
                    slider("Lightness", "lightness", -100...100)
                }
            }
            .navigationTitle(kind.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        for _ in 0..<steps { model.run("edit.undo") }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func slider(_ title: String, _ name: String, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                ValueLabel(text: "\(Int(values[name] ?? 0))", width: 40, font: .body)
            }
            Slider(value: Binding(get: { values[name] ?? 0 }, set: { v in
                values[name] = v.rounded()
                apply()
            }), in: range)
        }
    }

    private func apply() {
        if steps == 0 {
            if model.run(kind.command, values) != nil { steps = 1 }
        } else {
            var p: [String: Any] = values
            p["coalesce"] = key
            if model.run("layer.setAdjustment", p) != nil, steps == 1 { steps = 2 }
        }
    }
}

// MARK: - Command search

/// Every engine command with a menu item, by name: what has no button yet is still one search away.
struct CommandSearch: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var commands: [CommandInfo] = []
    @State private var searching = true
    @State private var settings: CommandInfo?

    private var shown: [CommandInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.filter { "\($0.menu) \($0.label)".lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List(shown, id: \.id) { c in
                Button {
                    // A "…" command asks for its settings first, as in Photoshop.
                    if c.label.hasSuffix("…"), !model.editor.commandFields(id: c.id).isEmpty {
                        settings = c
                    } else {
                        dismiss()
                        model.runInBackground(c.id)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.label.replacingOccurrences(of: "…", with: ""))
                        Text(c.menu).font(.caption).foregroundStyle(.secondary)
                        if let reason = c.reason {
                            Text(reason).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                        }
                    }
                }
                .disabled(!c.enabled)
            }
            .foregroundStyle(.primary)
            .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always), prompt: "Commands")
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .navigationDestination(item: $settings) { c in
                CommandSettings(command: c, fields: model.editor.commandFields(id: c.id)) { params in
                    dismiss()
                    model.runInBackground(c.id, params)
                }
            }
        }
        .onAppear { commands = model.editor.commands() }
    }
}

/// A command's settings, filled in before it runs. With `change`, every change applies at once
/// (a layer's Properties).
struct CommandSettings: View {
    let title: String
    let fields: [ParamField]
    var initial: [String: Any] = [:]
    var runTitle = "Run"
    /// Called when a setting is committed: a slider let go, a number entered, a choice made.
    var change: (([String: Any]) -> Void)?
    /// Also call `change` with the starting settings (a filter's first preview).
    var changeOnAppear = false
    /// Params set elsewhere on the screen (handles on the preview), sent with the form's.
    var extra: [String: Any] = [:]
    /// Settings of the screen's own, shown first.
    var header: AnyView?
    let run: ([String: Any]) -> Void
    @State private var numbers: [String: Double] = [:]
    @FocusState private var typing: String?
    @State private var finished = false
    @State private var choices: [String: String] = [:]
    @State private var toggles: [String: Bool] = [:]
    @State private var texts: [String: String] = [:]
    @State private var loaded = false

    init(command: CommandInfo, fields: [ParamField], run: @escaping ([String: Any]) -> Void) {
        self.title = command.label.replacingOccurrences(of: "…", with: "")
        self.fields = fields
        self.run = run
    }

    init(title: String, fields: [ParamField], initial: [String: Any], runTitle: String = "Done",
         change: (([String: Any]) -> Void)? = nil, changeOnAppear: Bool = false, extra: [String: Any] = [:], header: AnyView? = nil,
         run: @escaping ([String: Any]) -> Void) {
        (self.title, self.fields, self.initial, self.runTitle, self.change, self.run) = (title, fields, initial, runTitle, change, run)
        (self.changeOnAppear, self.extra, self.header) = (changeOnAppear, extra, header)
    }

    var body: some View {
        Form {
            if let header { header }
            ForEach(fields, id: \.name) { f in row(f) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !runTitle.isEmpty {
                ToolbarItem(placement: .confirmationAction) {
                    Button(runTitle) {
                        finished = true
                        run(params)
                    }
                    .accessibilityIdentifier("settings.run")
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: choices) { committed() }
        .onChange(of: toggles) { committed() }
        .onChange(of: typing) { old, _ in if old != nil { committed() } }
    }

    private func committed() {
        // A field losing focus as the screen closes isn't a new try.
        if loaded, !finished { change?(params) }
    }

    @ViewBuilder
    private func row(_ f: ParamField) -> some View {
        switch f.kind {
        case let .number(min, max, _, whole):
            let value = Binding(get: { numbers[f.name] ?? 0 }, set: { numbers[f.name] = whole ? $0.rounded() : $0 })
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(Self.title(f.name))
                    Spacer()
                    TextField("", value: value, format: .number.precision(.fractionLength(0...(whole ? 0 : 2))))
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: scaled(80))
                        .focused($typing, equals: f.name)
                        .onSubmit { committed() }
                        .accessibilityIdentifier("settings.\(f.name)")
                }
                if let min, let max, max > min {
                    Slider(value: Self.curved(value, min, max), in: 0...1) { editing in if !editing { committed() } }
                        .accessibilityIdentifier("settings.\(f.name).slider")
                }
            }
        case let .choice(options, _) where f.name == "anchor" && Set(options) == Set(AnchorGrid.anchors):
            HStack {
                Text("Anchor")
                Spacer()
                AnchorGrid(anchor: Binding(get: { choices[f.name] ?? "center" }, set: { choices[f.name] = $0 }))
            }
        case let .color(options, _):
            colorRow(f.name, options)
        case let .choice(options, _):
            Picker(Self.title(f.name), selection: Binding(get: { choices[f.name] ?? "" }, set: { choices[f.name] = $0 })) {
                ForEach(options, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            .accessibilityIdentifier("settings.\(f.name)")
        case .toggle:
            Toggle(Self.title(f.name), isOn: Binding(get: { toggles[f.name] ?? false }, set: { toggles[f.name] = $0 }))
                .accessibilityIdentifier("settings.\(f.name)")
        case .text:
            TextField(Self.title(f.name), text: Binding(get: { texts[f.name] ?? "" }, set: { texts[f.name] = $0 }))
                .accessibilityIdentifier("settings.\(f.name)")
        }
    }

    /// A colour, or one of its named choices (Background, Foreground…) and Custom.
    @ViewBuilder
    private func colorRow(_ name: String, _ options: [String]) -> some View {
        let value = texts[name] ?? ""
        let swatch = ColorRow(title: options.isEmpty ? Self.title(name) : "Custom Colour", hex: value.hasPrefix("#") ? value : nil, id: "settings.\(name)") {
            texts[name] = $0
            committed()
        }
        if options.isEmpty {
            swatch
        } else {
            Picker(Self.title(name), selection: Binding(get: { value.hasPrefix("#") ? "#" : value }, set: { v in
                texts[name] = v == "#" ? "#808080" : v
                committed()
            })) {
                ForEach(options, id: \.self) { Text(Self.title($0)).tag($0) }
                Text("Custom").tag("#")
            }
            .accessibilityIdentifier("settings.\(name).choice")
            if value.hasPrefix("#") { swatch }
        }
    }

    private func load() {
        guard !loaded else { return }
        (numbers, choices, toggles, texts) = Self.defaults(fields: fields, initial: initial)
        // Changes made while loading aren't the user's.
        DispatchQueue.main.async {
            loaded = true
            if changeOnAppear { change?(params) }
        }
    }

    private var params: [String: Any] { Self.params(numbers: numbers, choices: choices, toggles: toggles, texts: texts).merging(extra) { _, b in b } }

    /// Each field's starting value: from `initial`, else the field's default.
    static func defaults(fields: [ParamField], initial: [String: Any])
        -> (numbers: [String: Double], choices: [String: String], toggles: [String: Bool], texts: [String: String]) {
        var out: (numbers: [String: Double], choices: [String: String], toggles: [String: Bool], texts: [String: String]) = ([:], [:], [:], [:])
        for f in fields {
            let v = initial[f.name]
            switch f.kind {
            case let .number(_, _, value, _): out.numbers[f.name] = (v as? NSNumber)?.doubleValue ?? value
            case let .choice(_, value): out.choices[f.name] = v as? String ?? value
            case let .toggle(value): out.toggles[f.name] = v as? Bool ?? value
            case let .text(value): out.texts[f.name] = v as? String ?? value
            // Kept with the texts: unset (empty) leaves the engine's default.
            case let .color(_, value): out.texts[f.name] = v as? String ?? value
            }
        }
        return out
    }

    /// The command's params: whole numbers as integers, empty texts left out.
    static func params(numbers: [String: Double], choices: [String: String], toggles: [String: Bool], texts: [String: String]) -> [String: Any] {
        var p: [String: Any] = [:]
        for (k, v) in numbers { p[k] = v == v.rounded() && abs(v) < 1e9 ? Int(v) as Any : v }
        for (k, v) in choices { p[k] = v }
        for (k, v) in toggles { p[k] = v }
        for (k, v) in texts where !v.isEmpty { p[k] = v }
        return p
    }

    /// Slider position for `value`: wide ranges from zero give small values more travel.
    static func curved(_ value: Binding<Double>, _ min: Double, _ max: Double) -> Binding<Double> {
        let power = min >= 0 && max - min > 100 ? 3.0 : 1.0
        return Binding(
            get: { pow(Swift.min(Swift.max((value.wrappedValue - min) / (max - min), 0), 1), 1 / power) },
            set: { value.wrappedValue = min + pow($0, power) * (max - min) }
        )
    }

    /// `preserveLuminosity` → "Preserve luminosity".
    static func title(_ name: String) -> String {
        var out = ""
        for c in name {
            if c.isUppercase, !out.isEmpty { out += " " + c.lowercased() } else { out.append(c) }
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}

extension EditorModel {
    /// Window › Actions: every action and its steps, and which one is recording.
    func actionList() -> [ActionsPanel.Action]? {
        let labels = commandLabels
        guard let list = run("actions.list") as? [String: Any], let rows = list["actions"] as? [[String: Any]] else { return nil }
        recordingAction = list["recording"] as? String
        return rows.compactMap { r in
            guard let name = r["name"] as? String, let a = run("actions.get", ["action": name]) as? [String: Any] else { return nil }
            let off = Set(a["disabled"] as? [Int] ?? [])
            let steps = (a["steps"] as? [[Any]] ?? []).enumerated().map { i, s in
                let id = s.first as? String ?? ""
                return (label: ActionsPanel.stepNames[id] ?? (labels[id] ?? id).replacingOccurrences(of: "…", with: ""), on: !off.contains(i))
            }
            let set = a["set"] as? String
            return ActionsPanel.Action(name: name, set: set ?? "Actions", hasSet: set != nil, steps: steps)
        }
    }

    /// Play an action off the main thread; says where it stopped if a step failed.
    func playAction(_ name: String, then: (() -> Void)? = nil) {
        runInBackground("actions.play", ["action": name]) { [weak self] out in
            if let f = out?["failed"] as? [String: Any] { self?.toast = "Stopped at step \((f["step"] as? Int ?? 0) + 1): \(f["error"] as? String ?? "")" }
            then?()
        }
    }
}

/// Type tool options: font, size, leading, tracking, alignment. They apply to the selected text
/// layer now, and to text you add next.
struct TypeOptions: View {
    @ObservedObject var model: EditorModel
    @State private var fonts: [String] = []

    var body: some View {
        Group {
        Menu {
                ForEach(fonts, id: \.self) { f in Button(f) { set("font", f); model.typeFont = f } }
            } label: {
                Text(model.typeFont.isEmpty ? "Font" : model.typeFont).font(.caption).lineLimit(1)
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityIdentifier("type.font")
            number("Size", "pt", Binding(get: { model.typeSize > 0 ? model.typeSize : model.defaultTypeSize }, set: { model.typeSize = $0 ?? 0 }), key: "size")
            number("Leading", "pt", Binding(get: { model.typeLeading > 0 ? model.typeLeading : nil }, set: { model.typeLeading = $0 ?? 0 }), key: "leading", prompt: "Auto")
            number("Tracking", "", Binding(get: { model.typeTracking }, set: { model.typeTracking = $0 ?? 0 }), key: "tracking")
            Picker("Align", selection: Binding(get: { model.typeAlign }, set: { a in
                model.typeAlign = a
                set("align", a)
            })) {
                Image(systemName: "text.alignleft").tag("left")
                Image(systemName: "text.aligncenter").tag("center")
                Image(systemName: "text.alignright").tag("right")
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .accessibilityIdentifier("type.align")
        }
        .onAppear {
            if let l = textLayer { model.loadTypeOptions(layer: l) }
            guard let out = try? model.editor.execute(id: "type.fonts", params: "{}"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { return }
            fonts = obj["families"] as? [String] ?? []
        }
        .onChange(of: textLayer) { _, l in if let l { model.loadTypeOptions(layer: l) } }
    }

    private var textLayer: UInt64? { model.activeLayer.flatMap { $0.kind == "Type" ? $0.id : nil } }

    private func set(_ key: String, _ value: Any, coalesce: String? = nil) {
        guard let l = textLayer else { return }
        var p: [String: Any] = ["layer": l, key: value]
        if let coalesce { p["coalesce"] = coalesce }
        model.run("type.setStyle", p)
    }

    private func number(_ title: String, _ unit: String, _ value: Binding<Double?>, key: String, prompt: String? = nil) -> some View {
        HStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TypeNumberField(title: title, prompt: prompt, value: value) { v, edit in
                if v != 0 || key == "tracking" { set(key, v, coalesce: "type-\(key)-\(edit)") }
            }
            .accessibilityIdentifier("type.\(key)")
            if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

/// A number field that applies as you type, so tapping the Font menu or the canvas never drops
/// what was typed. One focus is one edit (`apply` gets its id), so it undoes in one step.
struct TypeNumberField: View {
    let title: String
    let prompt: String?
    @Binding var value: Double?
    let apply: (Double, Int) -> Void
    @State private var text = ""
    @State private var edit = 0
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: prompt.map { Text($0) })
            .focused($focused)
            .keyboardType(.numbersAndPunctuation)
            .font(.caption.monospacedDigit())
            .frame(width: scaled(52))
            .textFieldStyle(.roundedBorder)
            .onAppear { text = Self.format(value) }
            .onChange(of: value) { _, v in if !focused { text = Self.format(v) } }
            .onChange(of: focused) { _, f in
                if f { edit += 1 } else { text = Self.format(value) }
            }
            .onChange(of: text) { _, t in
                guard focused, let v = Self.parse(t) else { return }
                value = v
                apply(v, edit)
            }
    }

    static func format(_ v: Double?) -> String {
        v.map { $0.formatted(.number.precision(.fractionLength(0...1)).grouping(.never)) } ?? ""
    }

    /// The number typed, with a comma or a point for decimals; `nil` while it isn't one yet.
    static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite ? $0 : nil }
    }
}

/// A compact tool setting: its name and value over a slider (`position` 0…1).
struct PropSlider: View {
    let title: String
    let value: String
    @Binding var position: Double
    var editing: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                Spacer(minLength: 4)
                Text(value).monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Slider(value: $position, in: 0...1, onEditingChanged: editing)
                .accessibilityIdentifier("option.\(title)")
                .accessibilityValue(value)
        }
        .frame(maxWidth: 170)
    }
}

extension View {
    /// A bar slider in a row that picks what fits: measured at its ideal width, never squeezed.
    var fitted: some View { frame(minWidth: 80, idealWidth: 84) }
}

/// A slider's value, the same width whatever its digits, so nothing beside it moves.
struct ValueLabel: View {
    let text: String
    let width: CGFloat
    var font: Font = .caption

    var body: some View {
        Text(text)
            .font(font.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: scaled(width), alignment: .trailing)
    }
}

// MARK: - Actions

/// Window › Actions: recorded steps to play back, in sets as Photoshop's Actions panel shows them.
struct ActionsPanel: View {
    @ObservedObject var model: EditorModel
    /// Load Actions: pick an .atn file.
    let load: () -> Void
    @State private var actions: [Action] = []
    @State private var selected: String?
    @State private var expanded: Set<String> = []
    @State private var editing: LayerTextEdit?

    struct Action: Identifiable {
        let name: String
        let set: String
        let hasSet: Bool
        let steps: [(label: String, on: Bool)]
        var id: String { name }
        var on: Bool { steps.allSatisfy(\.on) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 18) {
                        if model.recordingAction != nil {
                            button("Stop Recording", "stop.fill", "actions.stop") { stop() }
                        } else {
                            button("Record", "record.circle", "actions.record", enabled: selected != nil) { record(selected) }
                        }
                        button("Play", "play.fill", "actions.play", enabled: selected != nil && model.recordingAction == nil) { play() }
                        button("New Action", "plus", "actions.new", enabled: model.recordingAction == nil) {
                            editing = LayerTextEdit(layer: 0, title: "New Action", text: "Action \(actions.count + 1)") { record(nil, named: $0) }
                        }
                        button("Delete", "trash", "actions.delete", enabled: selected != nil && model.recordingAction == nil) {
                            if let a = selected { run("actions.delete", ["action": a]); selected = nil }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if let r = model.recordingAction {
                        Label("Recording “\(r)”: work on the image, then come back here and stop.", systemImage: "record.circle.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                ForEach(sets, id: \.self) { set in
                    Section(set) {
                        ForEach(actions.filter { $0.set == set }) { a in
                            let open = expanded.contains(a.name)
                            HStack {
                                Button {
                                    if open { expanded.remove(a.name) } else { expanded.insert(a.name) }
                                } label: { Image(systemName: open ? "chevron.down" : "chevron.right").frame(width: 16) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(open ? "Hide steps" : "Show steps")
                                .accessibilityIdentifier("action.expand.\(a.name)")
                                check(a.on, id: "action.toggle.\(a.name)") { run("actions.toggle", ["action": a.name]) }
                                HStack {
                                    Text(a.name)
                                    Spacer()
                                    if model.recordingAction == a.name { Image(systemName: "record.circle.fill").foregroundStyle(.red) }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { rename(a.name) }
                                .onTapGesture { selected = a.name }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityIdentifier("action.\(a.name)")
                            }
                            .listRowBackground(selected == a.name ? Color.accentColor.opacity(0.25) : nil)
                            if open {
                                ForEach(Array(a.steps.enumerated()), id: \.offset) { i, step in
                                    HStack {
                                        check(step.on, id: "step.toggle.\(a.name).\(i)") { run("actions.toggle", ["action": a.name, "step": i]) }
                                        Text(step.label).foregroundStyle(step.on ? .primary : .secondary)
                                            .accessibilityIdentifier("step.\(a.name).\(i)")
                                    }
                                    .padding(.leading, 28)
                                }
                            }
                        }
                    }
                }
                if actions.isEmpty {
                    Text("No actions yet. Tap + to record one: what you do next is recorded until you stop.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { DoneButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Rename…") { if let a = selected { rename(a) } }.disabled(selected == nil)
                        Button("Add to Set…") {
                            guard let a = selected else { return }
                            editing = LayerTextEdit(layer: 0, title: "Set Name", text: "Set 1") { run("actions.assignSet", ["action": a, "set": $0]) }
                        }
                        .disabled(selected == nil)
                        Divider()
                        Button("Load Actions…") { load() }
                        Button("Save Actions…") { save() }.disabled(actions.isEmpty)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("actions.menu")
                }
            }
            .alert(editing?.title ?? "", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Name", text: Binding(get: { editing?.text ?? "" }, set: { editing?.text = $0 }))
                    .accessibilityIdentifier("prompt.field")
                Button("Cancel", role: .cancel) { editing = nil }
                Button("OK") {
                    if let e = editing { e.apply(e.text) }
                    editing = nil
                }
                .accessibilityIdentifier("prompt.ok")
            }
            .onAppear(perform: reload)
        }
    }

    /// Photoshop's names for steps whose command label alone reads oddly.
    static let stepNames = [
        "layer.new.layer": "Make Layer", "paint.stroke": "Brush Tool", "layer.delete": "Delete Layer",
        "layer.duplicate": "Duplicate Layer", "select.all": "Select All", "select.deselect": "Deselect",
        "edit.fill": "Fill", "image.size": "Image Size", "layer.transform": "Transform",
    ]

    private var sets: [String] {
        var seen: [String] = []
        for a in actions where !seen.contains(a.set) { seen.append(a.set) }
        return seen
    }

    private func button(_ title: String, _ symbol: String, _ id: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title3) }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .accessibilityLabel(title)
            .accessibilityIdentifier(id)
    }

    private func check(_ on: Bool, id: String, _ toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) { Image(systemName: on ? "checkmark.square" : "square") }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(id)
            .accessibilityValue(on ? "on" : "off")
    }

    private func run(_ id: String, _ params: [String: Any] = [:]) {
        model.run(id, params)
        reload()
    }

    private func reload() {
        if let list = model.actionList() { actions = list }
    }

    private func record(_ action: String?, named name: String? = nil) {
        var p: [String: Any] = [:]
        if let action { p["action"] = action }
        if let name { p["name"] = name }
        model.run("actions.record", p)
        reload()
        selected = model.recordingAction ?? selected
    }

    private func stop() {
        run("actions.stop")
        model.recordingAction = nil
    }

    private func play() {
        guard let a = selected else { return }
        model.playAction(a) { reload() }
    }

    private func rename(_ name: String) {
        editing = LayerTextEdit(layer: 0, title: "Rename Action", text: name) { new in
            run("actions.rename", ["action": name, "name": new])
            if selected == name { selected = new }
        }
    }

    /// Save Actions: the sets as a Photoshop .atn file in the app's folder.
    private func save() {
        let set = actions.first(where: { $0.name == selected })?.set ?? actions.first?.set ?? "Actions"
        // The engine only saves named sets.
        for a in actions where a.set == set && !a.hasSet { model.run("actions.assignSet", ["action": a.name, "set": set]) }
        reload()
        guard let out = model.run("actions.save", ["set": set, "skipUnsupported": true]) as? [String: Any], let b64 = out["data"] as? String, let data = Data(base64Encoded: b64) else { return }
        let url = AppFolder.url.appendingPathComponent("\(set).atn")
        do {
            try data.write(to: url)
            let skipped = (out["skipped"] as? [Any])?.count ?? 0
            model.toast = "Saved \(url.lastPathComponent)" + (skipped > 0 ? ", without \(skipped) step\(skipped == 1 ? "" : "s") a Photoshop .atn can't hold" : "")
        } catch {
            model.show(error)
        }
    }
}

/// Canvas Size's anchor: where the image stays as the canvas grows or shrinks.
struct AnchorGrid: View {
    @Binding var anchor: String

    static let anchors = ["topLeft", "top", "topRight", "left", "center", "right", "bottomLeft", "bottom", "bottomRight"]

    var body: some View {
        let i = Self.anchors.firstIndex(of: anchor) ?? 4
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0..<3, id: \.self) { r in
                GridRow {
                    ForEach(0..<3, id: \.self) { c in
                        let k = r * 3 + c
                        Button { anchor = Self.anchors[k] } label: {
                            Image(systemName: Self.symbol(k, anchor: i))
                                .frame(width: 34, height: 34)
                                .background(Color(white: k == i ? 0.35 : 0.18), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(CommandSettings.title(Self.anchors[k]))
                        .accessibilityIdentifier("anchor.\(Self.anchors[k])")
                    }
                }
            }
        }
    }

    /// The anchor shows a dot; its neighbours arrows pointing away from it, as in Photoshop.
    static func symbol(_ k: Int, anchor a: Int) -> String {
        let (dr, dc) = (k / 3 - a / 3, k % 3 - a % 3)
        guard abs(dr) <= 1, abs(dc) <= 1 else { return "" }
        switch (dr, dc) {
        case (0, 0): return "circle.fill"
        case (-1, 0): return "arrow.up"
        case (1, 0): return "arrow.down"
        case (0, -1): return "arrow.left"
        case (0, 1): return "arrow.right"
        case (-1, -1): return "arrow.up.left"
        case (-1, 1): return "arrow.up.right"
        case (1, -1): return "arrow.down.left"
        default: return "arrow.down.right"
        }
    }
}
