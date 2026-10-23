import SwiftUI

/// Photoshop's blend modes, in its menu order.
let blendModes = [
    ["Normal", "Dissolve"],
    ["Darken", "Multiply", "Color Burn", "Linear Burn", "Darker Color"],
    ["Lighten", "Screen", "Color Dodge", "Linear Dodge (Add)", "Lighter Color"],
    ["Overlay", "Soft Light", "Hard Light", "Vivid Light", "Linear Light", "Pin Light", "Hard Mix"],
    ["Difference", "Exclusion", "Subtract", "Divide"],
    ["Hue", "Saturation", "Color", "Luminosity"],
]

/// What a layer's Properties sheet edits.
struct LayerEdit: Identifiable {
    enum Part { case layer, smartFilter(Int), filterBlending(Int), mask }
    let layer: UInt64
    var part = Part.layer
    var id: String {
        switch part {
        case .layer: "\(layer)"
        case let .smartFilter(i): "\(layer)-\(i)"
        case let .filterBlending(i): "\(layer)-\(i)-blending"
        case .mask: "\(layer)-mask"
        }
    }
}

struct LayersPanel: View {
    @ObservedObject var model: EditorModel
    @AppStorage("layerThumbnails") private var thumbnails = ThumbnailSize.medium
    /// Shown as an alert here: a sheet from the main screen can't open over this one.
    @State private var editing: LayerTextEdit?
    @State private var properties: LayerEdit?
    @State private var deletingMask = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Photoshop keeps these under the Layers panel; here they stay in view at any sheet height.
                    // One grid, so both rows' buttons line up in columns.
                    Grid(horizontalSpacing: 0, verticalSpacing: 6) {
                        GridRow {
                            layerButton("New Layer", "plus", id: "layers.new") { model.run("layer.new.layer") }
                            layerButton("New Group", "folder.badge.plus", id: "layers.group") { group() }
                            styleMenu
                            adjustmentsMenu
                            maskMenu
                            layerButton("Delete Layer", "trash", id: "layers.delete") {
                                // With the mask selected, the trash takes the mask (Photoshop asks first).
                                if model.maskTarget, model.activeLayer?.hasMask == true { deletingMask = true } else { model.run("layer.delete") }
                            }
                        }
                        GridRow {
                            layerButton("New Layer from Photos", "photo.on.rectangle", id: "layers.fromPhotos") { model.request = .layerFromPhotos }
                            layerButton("New Layer from Files", "doc.badge.plus", id: "layers.fromFiles") { model.request = .layerFromFiles }
                            layerButton("Duplicate Layer", "plus.square.on.square", id: "layers.duplicate") { model.run("layer.duplicate") }
                            layerButton("Merge Down", "square.stack.3d.down.right", id: "layers.mergeDown") {
                                model.run(model.selectedLayers.count > 1 ? "layer.mergeLayers" : "layer.mergeDown")
                            }
                            layerButton("Move Up", "arrow.up", id: "layers.up") { model.run("layer.arrange.bringForward") }
                            layerButton("Move Down", "arrow.down", id: "layers.down") { model.run("layer.arrange.sendBackward") }
                        }
                    }
                }
                if model.selectedLayers.count > 1 {
                    Section("\(model.selectedLayers.count) layers selected") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                chip("Merge", "square.stack.3d.down.right", "layers.merge") { model.run("layer.mergeLayers") }
                                chip("Group", "folder", "layers.groupSelected") { group() }
                                chip("Clip", "arrow.turn.left.down", "layers.clip") { model.run("layer.createClippingMask") }
                                chip("Embedded Layer", "square.on.square.squareshape.controlhandles", "layers.smart") { model.run("layer.smartObjects.convertToSmartObject") }
                                chip("Fit", "arrow.up.left.and.arrow.down.right", "layers.fit") { model.fitLayers() }
                            }
                        }
                    }
                }
                // A phone on its side has little height: the layers come first.
                if short { layerRows }
                blendSection
                if !short { layerRows }
            }
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { DoneButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.selectingLayers.toggle() } label: {
                        Image(systemName: model.selectingLayers ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .accessibilityLabel("Select Layers")
                    .accessibilityIdentifier("layers.select")
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Thumbnail Size", selection: $thumbnails) {
                            ForEach(ThumbnailSize.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.inline)
                        Button("Merge Visible") { model.run("layer.mergeVisible") }
                        Button("Flatten Image") { model.run("layer.flattenImage") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("layers.menu")
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
            .confirmationDialog("Apply the mask to the layer before deleting it?", isPresented: $deletingMask, titleVisibility: .visible) {
                if model.activeLayer?.kind == "Pixel" { Button("Apply") { model.run("layer.layerMask.apply") } }
                Button("Delete", role: .destructive) { model.run("layer.layerMask.delete") }
                    .accessibilityIdentifier("deleteMask.delete")
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $properties) { p in
                LayerPropertiesSheet(model: model, edit: p).panelDetents()
            }
        }
        .onDisappear { model.selectingLayers = false }
        .overlay(alignment: .top) {
            if let hint = model.hint { HintBubble(model: model, text: hint).allowsHitTesting(false) }
        }
    }

    private var short: Bool { verticalSizeClass == .compact }

    @ViewBuilder
    private var blendSection: some View {
                if let a = model.activeLayer {
                        Section {
                            blendRow(a)
                        } footer: {
                            if a.isBackground, !short { Text("The Background can't be moved, faded or blended. Tap its lock to make it a normal layer.") }
                        }
                    }
    }

    private var layerRows: some View {
                Section {
                        ForEach(model.layers) { row in
                            LayerRowView(model: model, row: row, editing: $editing, properties: $properties)
                                .listRowBackground(row.selected ? Color.accentColor.opacity(row.active ? 0.35 : 0.2) : nil)
                            if !model.collapsedFilters.contains(row.id) {
                                if !row.effects.isEmpty { EffectRows(model: model, row: row) }
                                if row.kind == "Embedded", !row.smartFilters.isEmpty, row.expanded {
                                    SmartFilterRows(model: model, row: row, properties: $properties)
                                }
                            }
                        }
                        .onMove(perform: move)
                    } footer: {
                        if !short { Text("Drag a layer to reorder, or just under a group to put it in. Double-tap a name to rename it, a thumbnail to edit the layer. Touch and hold a layer or a mask for more.") }
                    }
    }

    private func group() {
        model.newGroup()
    }

    /// The mask button: a tap reveals the selection (or all); touch and hold for a mask that
    /// hides it instead (Photoshop's ⌥-click).
    private var maskMenu: some View {
        let selection = model.doc?.hasSelection == true
        return Menu {
            Section("Add Mask") {
                Button(selection ? "Reveal Selection" : "Reveal All") { model.addMask() }
                Button(selection ? "Hide Selection" : "Hide All") { model.addMask(hide: true) }
                    .accessibilityIdentifier("layers.mask.hide")
            }
        } label: {
            Image(systemName: "circle.lefthalf.filled").frame(maxWidth: .infinity, minHeight: 30)
        } primaryAction: {
            model.addMask()
        }
        .accessibilityLabel("Add Mask")
        .accessibilityIdentifier("layers.mask")
        .disabled(model.activeLayer == nil)
    }

    /// Photoshop's fx button: Blending Options and the effects.
    private var styleMenu: some View {
        Menu {
            // Opening the menu says what it is.
            Section("Layer Style") {
            Button("Blending Options…") { model.request = .layerStyle("blendingOptions") }
            ForEach(LayerStyle.kinds.reversed(), id: \.kind) { k in
                Button("\(k.label)…") { model.request = .layerStyle(k.kind) }
            }
            }
        } label: {
            Text("fx").font(.body.italic().bold()).frame(maxWidth: .infinity, minHeight: 30)
        }
        .accessibilityLabel("Add a Layer Style")
        .accessibilityIdentifier("layers.fx")
        .disabled(model.activeLayer == nil)
    }

    /// The adjustment layer button: fill and adjustment layers, as in Photoshop.
    private var adjustmentsMenu: some View {
        Menu {
            Section("New Fill or Adjustment Layer") {
                ForEach(model.adjustmentCommands, id: \.id) { c in
                    Button(c.label) {
                        guard model.run(c.id) != nil, let layer = model.activeLayer?.id else { return }
                        properties = LayerEdit(layer: layer)
                    }
                }
            }
        } label: {
            Image(systemName: "circle.righthalf.filled").frame(maxWidth: .infinity, minHeight: 30)
        }
        .accessibilityLabel("New Fill or Adjustment Layer")
        .accessibilityIdentifier("layers.adjust")
    }

    @ViewBuilder
    private func blendRow(_ a: LayerRow) -> some View {
        let ids = model.selectedLayers.count > 1 ? model.selectedLayers.map(\.id) : [a.id]
        let set = { (key: String, v: Any) in
            model.run("layer.setProps", ["layers": ids, key: v, "coalesce": "\(key)-\(ids.map(String.init).joined(separator: ","))"])
        }
        HStack {
            Picker("Blend", selection: Binding(get: { a.blend }, set: { set("blend", $0) })) {
                ForEach(blendModes, id: \.self) { section in
                    Section { ForEach(section, id: \.self) { Text($0).tag($0) } }
                }
                if a.isGroup { Text("Pass Through").tag("Pass Through") }
            }
            .accessibilityIdentifier("layers.blend")
            // One mode at a time, to see what each does.
            Button { set("blend", EditorModel.stepBlend(a.blend, by: -1, group: a.isGroup)) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Previous Blend Mode")
                .accessibilityIdentifier("layers.blend.previous")
            Button { set("blend", EditorModel.stepBlend(a.blend, by: 1, group: a.isGroup)) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Next Blend Mode")
                .accessibilityIdentifier("layers.blend.next")
        }
        .disabled(a.isBackground)
        ScrubSlider(title: "Opacity", value: a.opacity, id: "layers.opacity") { set("opacity", $0) }
            .disabled(a.isBackground)
        ScrubSlider(title: "Fill", value: a.fill, id: "layers.fill") { set("fill", $0) }
            .disabled(a.isBackground)
    }

    /// A tap runs it; touch and hold only says what it is.
    private func layerButton(_ title: String, _ symbol: String, id: String, _ action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.body)
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 30)
            .namedButton(title, model: model, action)
            .accessibilityIdentifier(id)
    }

    private func chip(_ title: String, _ symbol: String, _ id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.caption) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(id)
    }

    /// List order is top first; the engine places a layer above or below another.
    private func move(from: IndexSet, to: Int) {
        if let i = from.first { model.moveLayer(from: i, to: to) }
    }
}

extension View {
    /// Half or full height on a phone. An iPad shows a sheet as a card, which half height squeezes
    /// to a strip: a full-height page there. `canvas`: the canvas beside it still takes touches.
    func panelDetents(canvas: Bool = false) -> some View { modifier(PanelDetents(canvas: canvas)) }
}

private struct PanelDetents: ViewModifier {
    let canvas: Bool
    @Environment(\.horizontalSizeClass) private var width

    func body(content: Content) -> some View {
        let card = width == .regular
        let sized = content
            .presentationDetents(card ? [.large] : [.medium, .large])
            .presentationBackgroundInteraction(canvas ? (card ? .enabled : .enabled(upThrough: .medium)) : .automatic)
        // The iPad's default card is too short for a list: a page sheet is taller.
        if #available(iOS 18.0, *), card {
            sized.presentationSizing(.page)
        } else {
            sized
        }
    }
}

/// A 0–1 value as a percentage. Dragging its name scrubs it, as in Photoshop.
struct ScrubSlider: View {
    let title: String
    let value: Double
    let id: String
    let set: (Double) -> Void
    @State private var from: Double?

    var body: some View {
        HStack {
            Text(title)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: scaled(64), alignment: .leading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { g in
                    let start = from ?? value
                    from = start
                    set(min(max(start + Double(g.translation.width) / 300, 0), 1))
                }.onEnded { _ in from = nil })
                .accessibilityIdentifier("\(id).label")
            Slider(value: Binding(get: { value }, set: set), in: 0...1)
                .accessibilityIdentifier(id)
            Text("\(Int((value * 100).rounded()))%").monospacedDigit().lineLimit(1).frame(width: scaled(56), alignment: .trailing)
        }
    }
}

struct LayerRowView: View {
    @ObservedObject var model: EditorModel
    let row: LayerRow
    @Binding var editing: LayerTextEdit?
    @Binding var properties: LayerEdit?
    @State private var thumb: UIImage?
    @State private var maskThumb: UIImage?
    @AppStorage("layerThumbnails") private var thumbnails = ThumbnailSize.medium

    var body: some View {
        HStack(spacing: 8) {
            Button { model.run("layer.setProps", ["layer": row.id, "visible": !row.visible]) } label: {
                Image(systemName: row.visible ? "eye" : "eye.slash").foregroundStyle(row.visible ? .primary : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("layer.eye.\(row.name)")
            if row.depth > 0 { Spacer().frame(width: CGFloat(row.depth) * 16) }
            if row.clipped {
                Image(systemName: "arrow.turn.left.down").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("layer.clipped.\(row.name)")
            }
            if row.isGroup {
                Button { model.toggleGroup(row.id) } label: {
                    Image(systemName: row.expanded ? "chevron.down" : "chevron.right").font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("layer.expand.\(row.name)")
            } else if (row.kind == "Embedded" && !row.smartFilters.isEmpty) || !row.effects.isEmpty {
                Button { model.toggleFilters(row.id) } label: {
                    Image(systemName: model.collapsedFilters.contains(row.id) ? "chevron.right" : "chevron.down").font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("layer.filters.\(row.name)")
            }
            if thumbnails != .none {
                thumbnail
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(row.selected && row.hasMask && !model.maskTarget ? Color.white : .clear, lineWidth: 2))
                    .overlay(alignment: .bottomTrailing) { badge }
                    .onTapGesture(count: 2) { editContent() }
                    .onTapGesture { tapped() }
                    .contextMenu { menu }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue(row.kind)
                    .accessibilityIdentifier("layer.thumb.\(row.name)")
            }
            if row.hasMask, thumbnails != .none {
                // Photoshop's link between the layer and its mask: tap to unlink or link again.
                Button { model.run("layer.layerMask.linked", ["layer": row.id]) } label: {
                    Image(systemName: "link").font(.caption2).opacity(row.mask?.linked == false ? 0.2 : 1)
                }
                .buttonStyle(.borderless)
                .frame(width: 14)
                .accessibilityLabel("Link Mask")
                .accessibilityValue(row.mask?.linked == false ? "unlinked" : "linked")
                .accessibilityIdentifier("layer.link.\(row.name)")
                maskThumbnail
                    .onTapGesture(count: 2) { target(mask: true); properties = LayerEdit(layer: row.id, part: .mask) }
                    .onTapGesture { target(mask: true) }
                    .contextMenu { maskItems }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue(row.mask?.enabled == false ? "disabled" : "enabled")
                    .accessibilityIdentifier("layer.mask.\(row.name)")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1)
                Text(row.opacity < 1 || !["Normal", "Pass Through"].contains(row.blend) ? "\(row.blend) · \(Int((row.opacity * 100).rounded()))%" : kindName)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { rename() }
            .onTapGesture { tapped() }
            .contextMenu { menu }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("layer.\(row.name)")
            // Photoshop opens Layer Style from a double-click on the right of a layer.
            Color.clear.frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { openStyle("blendingOptions") }
                .onTapGesture { tapped() }
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("layer.style.\(row.name)")
            if !row.effects.isEmpty {
                Text("fx").font(.caption.italic().bold()).foregroundStyle(.secondary).accessibilityIdentifier("layer.fx.\(row.name)")
            }
            if model.selectingLayers {
                Image(systemName: row.selected ? "checkmark.circle.fill" : "circle").foregroundStyle(row.selected ? Color.accentColor : .secondary)
            }
            if row.locked || row.isBackground {
                Button { unlock() } label: { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("layer.lock.\(row.name)")
            }
        }
        .contentShape(Rectangle())
        .task(id: "\(model.doc?.revision ?? 0)-\(thumbnails.rawValue)") {
            guard thumbnails != .none, ["Pixel", "Type", "Embedded", "Shape", "Fill"].contains(row.kind),
                  let data = try? model.editor.layerThumbnail(layer: row.id, maxSide: UInt32(thumbnails.side * 3)) else { return }
            thumb = UIImage(data: data)
        }
        .task(id: "\(model.doc?.revision ?? 0)-\(thumbnails.rawValue)-mask") {
            guard thumbnails != .none, row.hasMask, let data = try? model.editor.layerMaskThumbnail(layer: row.id, maxSide: UInt32(thumbnails.side * 3)) else { return }
            maskThumb = UIImage(data: data)
        }
    }

    /// The mask's own pixels; a red cross while it's turned off, as in Photoshop.
    private var maskThumbnail: some View {
        ZStack {
            if let maskThumb { Image(uiImage: maskThumb).resizable().scaledToFit() } else { Color.white }
            if row.mask?.enabled == false {
                Path { p in
                    p.move(to: .zero); p.addLine(to: CGPoint(x: thumbnails.side, y: thumbnails.side))
                    p.move(to: CGPoint(x: thumbnails.side, y: 0)); p.addLine(to: CGPoint(x: 0, y: thumbnails.side))
                }
                .stroke(Color.red, lineWidth: 3)
            }
        }
        .frame(width: thumbnails.side, height: thumbnails.side)
        .background(Color(white: 0.2))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(row.selected && model.maskTarget ? Color.accentColor : .clear, lineWidth: 2))
    }

    /// Touch and hold the mask: what Photoshop's mask thumbnail offers (⌥-click, ⇧-click,
    /// right-click, ⌥-drag to copy and drag to move).
    @ViewBuilder
    private var maskItems: some View {
        Button { model.toggleMaskView(row.id) } label: { Label(model.maskView == row.id ? "Stop Viewing Mask" : "View Mask", systemImage: "eye") }
        Button { target(mask: true); properties = LayerEdit(layer: row.id, part: .mask) } label: { Label("Mask Properties…", systemImage: "slider.horizontal.3") }
        Button { model.run("layer.layerMask.enabled", ["layer": row.id]) } label: {
            Label(row.mask?.enabled == false ? "Enable Mask" : "Disable Mask", systemImage: "eye.slash")
        }
        Button { model.run("layer.layerMask.linked", ["layer": row.id]) } label: {
            Label(row.mask?.linked == false ? "Link Mask" : "Unlink Mask", systemImage: "link")
        }
        Button { target(mask: true); model.run("image.adjustments.invert") } label: { Label("Invert Mask", systemImage: "circle.righthalf.filled") }
        Button { model.loadMaskAsSelection(row.id) } label: { Label("Load as Selection", systemImage: "selection.pin.in.out") }
        let others = model.layers.filter { $0.id != row.id && !$0.isBackground }
        if !others.isEmpty {
            Menu {
                ForEach(others) { l in Button(l.name) { model.copyMask(from: row.id, to: l.id, move: false) } }
            } label: { Label("Copy Mask To", systemImage: "plus.square.on.square") }
            Menu {
                ForEach(others) { l in Button(l.name) { model.copyMask(from: row.id, to: l.id, move: true) } }
            } label: { Label("Move Mask To", systemImage: "arrow.right.square") }
        }
        if row.kind == "Pixel" { Button { model.run("layer.layerMask.apply", ["layer": row.id]) } label: { Label("Apply Mask", systemImage: "checkmark.circle") } }
        Button(role: .destructive) { model.run("layer.layerMask.delete", ["layer": row.id]) } label: { Label("Delete Mask", systemImage: "trash") }
    }

    private var kindName: String {
        if let a = row.adjustment { return AdjustmentKinds.label(a.kind) }
        return row.kind
    }

    /// The layer's kind on its thumbnail, as Photoshop marks smart objects and shapes.
    @ViewBuilder
    private var badge: some View {
        let symbol: String? = switch row.kind {
        case "Embedded": "square.on.square.squareshape.controlhandles"
        case "Shape": "square.on.circle"
        default: nil
        }
        if let symbol, thumbnails != .none {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).padding(2)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button { rename() } label: { Label("Rename…", systemImage: "pencil") }
        if row.kind == "Type" { Button { editText() } label: { Label("Edit Text…", systemImage: "character.cursor.ibeam") } }
        if row.kind == "Embedded" { Button { editContents() } label: { Label("Edit Contents", systemImage: "square.and.pencil") } }
        if row.adjustment != nil || row.kind == "Fill" { Button { properties = LayerEdit(layer: row.id) } label: { Label("Properties…", systemImage: "slider.horizontal.3") } }
        Button { openStyle("blendingOptions") } label: { Label("Blending Options…", systemImage: "square.2.layers.3d") }
        if !row.isBackground {
            Button { model.run("layer.layerStyle.clear", ["layer": row.id]) } label: { Label("Clear Layer Style", systemImage: "square.slash") }
        }
        Button { model.run("layer.duplicate", ["layer": row.id]) } label: { Label("Duplicate Layer", systemImage: "plus.square.on.square") }
        Button { selectThis(); model.run(row.isGroup ? "layer.ungroupLayers" : "layer.groupLayers") } label: {
            Label(row.isGroup ? "Ungroup Layers" : "Group Layers", systemImage: "folder")
        }
        if row.hasMask {
            Section("Mask") { maskItems }
        }
        Section {
            Button { selectThis(); model.run("layer.mergeLayers") } label: { Label(model.selectedLayers.count > 1 ? "Merge Layers" : "Merge Down", systemImage: "square.stack.3d.down.right") }
            Button { model.run("layer.mergeVisible") } label: { Label("Merge Visible", systemImage: "square.stack.3d.up") }
            Button { model.run("layer.stampVisible") } label: { Label("Stamp Visible", systemImage: "square.stack.3d.up.fill") }
            let selected = model.selectedLayers.map(\.id)
            let many = selected.count > 1 && selected.contains(row.id)
            Button { model.exportLayers(many ? selected : [row.id]) } label: {
                Label(many ? "Quick Export Layers as PNG" : "Quick Export as PNG", systemImage: "square.and.arrow.up")
            }
            if row.kind != "Embedded" {
                Button { selectThis(); model.run("layer.smartObjects.convertToSmartObject") } label: { Label("Convert to Embedded Layer", systemImage: "square.on.square.squareshape.controlhandles") }
            }
            if ["Embedded", "Type", "Shape", "Fill"].contains(row.kind) {
                Button { selectThis(); model.run("layer.rasterize.layer", ["layer": row.id]) } label: { Label("Rasterize Layer", systemImage: "squareshape.split.3x3") }
            }
            Button {
                selectThis()
                model.run(row.clipped ? "layer.releaseClippingMask" : "layer.createClippingMask", ["layer": row.id])
            } label: { Label(row.clipped ? "Release Clipping Mask" : "Create Clipping Mask", systemImage: "arrow.turn.left.down") }
        }
        Section {
            // Photoshop's ⌥-click on the eye; again puts the other layers back as they were.
            Button { model.run("layer.showOnly", ["layer": row.id]) } label: { Label("Show This Layer Only", systemImage: "eye.square") }
            Button { model.run("layer.showHideOthers", ["layer": row.id]) } label: { Label("Show/Hide All Other Layers", systemImage: "eye.circle") }
            Button { selectThis(); model.fitLayers() } label: { Label("Fit Layer on Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
            Button { model.selectingLayers = true; select("toggle") } label: { Label("Select More Layers", systemImage: "checkmark.circle") }
            if !row.isBackground {
                Button { selectThis(); model.run("layer.new.backgroundFromLayer", ["layer": row.id]) } label: { Label("Background from Layer", systemImage: "square.bottomhalf.filled") }
            }
            Button { lock() } label: { Label(row.locked || row.isBackground ? "Unlock" : "Lock", systemImage: row.locked ? "lock.open" : "lock") }
        }
        if !row.isBackground {
            Section {
                let groups = model.layers.filter { $0.isGroup && $0.id != row.id && model.parentGroup(of: row.id)?.id != $0.id }
                if !groups.isEmpty {
                    Menu {
                        ForEach(groups) { g in Button(g.name) { model.moveLayer(row.id, into: g.id) } }
                    } label: { Label("Move Into Group", systemImage: "folder.badge.plus") }
                }
                if model.parentGroup(of: row.id) != nil {
                    Button { model.moveOutOfGroup(row.id) } label: { Label("Move Out of Group", systemImage: "folder.badge.minus") }
                }
            }
        }
        Button(role: .destructive) { model.run("layer.delete", ["layer": row.id]) } label: { Label("Delete Layer", systemImage: "trash") }
    }

    private var thumbnail: some View {
        Group {
            if row.kind == "Type" {
                Text("T").font(.title2.bold()).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(white: 0.3))
            } else if row.isGroup {
                Image(systemName: "folder.fill").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(white: 0.2))
            } else if let thumb {
                Image(uiImage: thumb).resizable().scaledToFit().background(Checkerboard())
            } else {
                Image(systemName: row.adjustment.map { AdjustmentKinds.symbol($0.kind) } ?? "photo").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(white: 0.2))
            }
        }
        .frame(width: thumbnails.side, height: thumbnails.side)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func openStyle(_ page: String) {
        target(mask: false)
        model.request = .layerStyle(page)
    }

    /// A tap: select this layer, or, while selecting several, add it or take it out.
    private func tapped() {
        if model.selectingLayers { select("toggle") } else { target(mask: false) }
    }

    private func select(_ mode: String) {
        model.run("layer.select", ["layer": row.id, "mode": mode])
        model.reloadLayers()
    }

    /// Commands from the layer's own menu act on it, unless it's part of a multiple selection.
    private func selectThis() {
        if !row.selected { target(mask: false) }
    }

    /// Select the layer, painting on its pixels or its mask.
    private func target(mask: Bool) {
        model.targetLayer(row.id, mask: mask)
    }

    /// Double-tapping a thumbnail edits what the layer holds, as in Photoshop.
    private func editContent() {
        switch row.kind {
        case "Type": editText()
        case "Embedded": editContents()
        case "Pixel", "Group": rename()
        default:
            selectThis()
            properties = LayerEdit(layer: row.id)
        }
    }

    private func editContents() {
        selectThis()
        model.runInBackground("layer.smartObjects.editContents", ["layer": row.id]) { _ in model.request = .closePanels }
    }

    private func rename() {
        // As in Photoshop, editing a layer's name selects it.
        if !row.selected { target(mask: false) }
        if row.isBackground {
            // The Background has to become a normal layer first; Photoshop offers to do it.
            editing = LayerTextEdit(layer: row.id, title: "New Layer", text: "Layer 0") { [model] name in
                model.run("layer.new.layerFromBackground")
                if !name.isEmpty, let l = model.activeLayer?.id { model.run("layer.renameLayer", ["layer": l, "name": name]) }
            }
            return
        }
        editing = LayerTextEdit(layer: row.id, title: "Rename Layer", text: row.name) { [model, row] name in
            if !name.isEmpty { model.run("layer.renameLayer", ["layer": row.id, "name": name]) }
        }
    }

    private func editText() {
        if !row.selected { target(mask: false) }
        guard row.kind == "Type",
              let info = try? model.editor.execute(id: "type.info", params: json(["layer": row.id])),
              let i = try? JSONSerialization.jsonObject(with: Data(info.utf8)) as? [String: Any] else { return }
        editing = LayerTextEdit(layer: row.id, title: "Edit Text", text: i["text"] as? String ?? "") { [model, row] text in
            model.run("type.edit", ["layer": row.id, "text": text])
        }
    }

    /// The Background unlocks into a normal layer; other layers drop their locks.
    private func unlock() {
        model.run("layer.select", ["layer": row.id])
        if row.isBackground {
            model.run("layer.new.layerFromBackground")
        } else {
            model.run("layer.lockLayers", ["all": false, "transparency": false, "pixels": false, "position": false])
        }
    }

    private func lock() {
        if row.locked || row.isBackground { unlock(); return }
        model.run("layer.select", ["layer": row.id])
        model.run("layer.lockLayers", ["all": true])
    }
}

/// A smart object's filters, under its row: tap the eye to hide one, double-tap to change it,
/// swipe to delete it.
struct SmartFilterRows: View {
    @ObservedObject var model: EditorModel
    let row: LayerRow
    @Binding var properties: LayerEdit?

    /// Fluid Warp is changed on the canvas, Develop in its own full screen, the others in their
    /// settings.
    private func edit(_ f: SmartFilterRow) {
        if f.command == "filter.liquify" {
            model.request = .closePanels
            model.editFluidWarp(layer: row.id, filter: f)
        } else if f.command == "filter.cameraRaw" {
            model.request = .closePanels
            // After the Layers sheet has gone: one sheet can't open while another closes.
            let edit = DevelopEdit(layer: row.id, index: f.index, initial: f.params)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [model] in model.developEdit = edit }
        } else {
            properties = LayerEdit(layer: row.id, part: .smartFilter(f.index))
        }
    }

    var body: some View {
        Text("Live Filters").font(.caption).foregroundStyle(.secondary)
            .padding(.leading, CGFloat(row.depth) * 16 + 44)
            .accessibilityIdentifier("filters.\(row.name)")
        ForEach(row.smartFilters.reversed()) { f in
            HStack(spacing: 8) {
                Button { model.run("layer.smartFilter.setVisible", ["layer": row.id, "index": f.index]) } label: {
                    Image(systemName: f.visible ? "eye" : "eye.slash").foregroundStyle(f.visible ? .primary : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("filter.eye.\(row.name).\(f.index)")
                Spacer().frame(width: CGFloat(row.depth) * 16 + 12)
                Text(f.name).font(.callout)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { edit(f) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("filter.\(row.name).\(f.name)")
            .swipeActions {
                Button(role: .destructive) { model.run("layer.smartFilter.delete", ["layer": row.id, "index": f.index]) } label: { Label("Delete", systemImage: "trash") }
            }
            .contextMenu {
                Button { edit(f) } label: { Label("Edit Live Filter…", systemImage: "slider.horizontal.3") }
                Button { properties = LayerEdit(layer: row.id, part: .filterBlending(f.index)) } label: { Label("Blending Options…", systemImage: "square.2.layers.3d") }
                let others = model.layers.filter { $0.kind == "Embedded" && $0.id != row.id }
                if !others.isEmpty {
                    Menu {
                        ForEach(others) { o in
                            Button(o.name) { model.run("layer.smartFilter.transfer", ["from": row.id, "to": o.id, "filter": f.index, "copy": true]) }
                        }
                    } label: { Label("Copy to Layer", systemImage: "square.on.square") }
                }
                Button(role: .destructive) { model.run("layer.smartFilter.delete", ["layer": row.id, "index": f.index]) } label: { Label("Delete Live Filter", systemImage: "trash") }
            }
        }
    }
}

/// A live filter's Blending Options: how its result mixes with the layer under it.
struct FilterBlending: View {
    @ObservedObject var model: EditorModel
    let layer: UInt64
    let filter: SmartFilterRow
    @State private var blend = "Normal"
    @State private var opacity = 1.0
    @State private var sent: (String, Double)?

    var body: some View {
        Form {
            Picker("Mode", selection: $blend) {
                ForEach(blendModes, id: \.self) { section in
                    Section { ForEach(section, id: \.self) { Text($0).tag($0) } }
                }
            }
            .accessibilityIdentifier("filterBlend.mode")
            .onChange(of: blend) { _, _ in apply() }
            HStack {
                Text("Opacity")
                Slider(value: $opacity, in: 0...1) { editing in if !editing { apply() } }
                    .accessibilityIdentifier("filterBlend.opacity")
                Text("\(Int((opacity * 100).rounded()))%").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
        }
        .navigationTitle("Blending Options (\(filter.name))")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            (blend, opacity) = (filter.blend, filter.opacity)
            sent = (filter.blend, filter.opacity)
        }
    }

    private func apply() {
        guard let s = sent, s != (blend, opacity) else { return }
        sent = (blend, opacity)
        model.run("layer.smartFilter.blendingOptions", ["layer": layer, "index": filter.index, "blend": blend, "opacity": opacity])
    }
}

/// A layer's styles, under its row: tap an eye to hide one, double-tap to change it, swipe to
/// delete it.
struct EffectRows: View {
    @ObservedObject var model: EditorModel
    let row: LayerRow

    var body: some View {
        HStack(spacing: 8) {
            eye(row.effectsVisible, id: "effects.eye.\(row.name)") { model.run("layer.setEffectsVisible", ["layer": row.id]) }
            Spacer().frame(width: CGFloat(row.depth) * 16 + 12)
            Text("Effects").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("effects.\(row.name)")
        ForEach(row.effects) { e in
            HStack(spacing: 8) {
                eye(e.visible, id: "effect.eye.\(row.name).\(e.index)") { model.run("layer.setEffectsVisible", ["layer": row.id, "index": e.index]) }
                Spacer().frame(width: CGFloat(row.depth) * 16 + 24)
                Text(e.name).font(.callout)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { edit(e) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("effect.\(row.name).\(e.name)")
            .swipeActions {
                Button(role: .destructive) { model.run("layer.layerStyle.clear", ["layer": row.id, "effect": e.index]) } label: { Label("Delete", systemImage: "trash") }
            }
            .contextMenu {
                Button { edit(e) } label: { Label("Edit Effect…", systemImage: "slider.horizontal.3") }
                Button(role: .destructive) { model.run("layer.layerStyle.clear", ["layer": row.id, "effect": e.index]) } label: { Label("Delete Effect", systemImage: "trash") }
            }
        }
    }

    private func eye(_ on: Bool, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? "eye" : "eye.slash").foregroundStyle(on ? .primary : .secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier(id)
    }

    private func edit(_ e: EffectRow) {
        model.run("layer.select", ["layer": row.id])
        model.request = .layerStyle(LayerStyle.kinds.first { $0.label == e.name }?.kind ?? "blendingOptions")
    }
}

/// Names and symbols of the adjustment kinds `document.inspect` reports.
enum AdjustmentKinds {
    static func label(_ kind: String) -> String {
        [
            "brightnessContrast": "Brightness/Contrast", "levels": "Levels", "curves": "Curves", "exposure": "Exposure",
            "vibrance": "Vibrance", "hueSaturation": "Hue/Saturation", "colorBalance": "Color Balance", "blackWhite": "Black & White",
            "photoFilter": "Photo Filter", "channelMixer": "Channel Mixer", "posterize": "Posterize", "threshold": "Threshold",
            "gradientMap": "Gradient Map", "selectiveColor": "Selective Color", "colorLookup": "Color Lookup", "invert": "Invert",
        ][kind] ?? "Adjustment"
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "hueSaturation", "vibrance", "colorBalance", "selectiveColor": "drop.halffull"
        case "exposure", "brightnessContrast", "levels", "curves": "sun.max"
        case "photoFilter", "colorLookup", "gradientMap": "camera.filters"
        default: "circle.righthalf.filled"
        }
    }
}

/// Layer › New › Layer… (⇧⌘N): a new layer with its name, clipping, colour, mode and opacity, and
/// for modes that have one, filled with their neutral colour (50% gray for Overlay).
struct NewLayerSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var clip = false
    @State private var color = "none"
    @State private var mode = "Normal"
    @State private var opacity = 1.0
    @State private var neutral = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).accessibilityIdentifier("newLayer.name")
                Toggle("Use Previous Layer to Create Clipping Mask", isOn: $clip)
                Picker("Color", selection: $color) {
                    ForEach(["none", "red", "orange", "yellow", "green", "blue", "violet", "gray"], id: \.self) { Text($0 == "none" ? "None" : $0.capitalized).tag($0) }
                }
                Picker("Mode", selection: $mode) {
                    ForEach(blendModes, id: \.self) { section in
                        Section { ForEach(section, id: \.self) { Text($0).tag($0) } }
                    }
                }
                .accessibilityIdentifier("newLayer.mode")
                ScrubSlider(title: "Opacity", value: opacity, id: "newLayer.opacity") { opacity = $0 }
                Toggle("Fill with \(mode)-neutral color", isOn: $neutral)
                    .disabled(!Self.hasNeutral(mode))
                    .accessibilityIdentifier("newLayer.neutral")
            }
            .navigationTitle("New Layer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        var p: [String: Any] = ["clipToPrevious": clip, "color": color, "mode": mode, "opacity": opacity, "fillNeutral": neutral && Self.hasNeutral(mode)]
                        if !name.isEmpty { p["name"] = name }
                        model.run("layer.new.layer", p)
                        dismiss()
                    }
                    .accessibilityIdentifier("newLayer.ok")
                }
            }
        }
    }

    /// Modes with a colour that leaves what's below unchanged (Photoshop offers the fill only for these).
    static func hasNeutral(_ mode: String) -> Bool {
        ["Multiply", "Color Burn", "Linear Burn", "Screen", "Color Dodge", "Linear Dodge (Add)", "Overlay", "Soft Light", "Hard Light",
         "Vivid Light", "Linear Light", "Pin Light", "Difference", "Exclusion", "Subtract", "Divide", "Darken", "Lighten"].contains(mode)
    }
}
