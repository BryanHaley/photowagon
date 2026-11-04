import SwiftUI
import XCTest
@testable import PhotoWagon

/// Panels shown in a window and used through their accessibility elements, as VoiceOver would:
/// a button's action, a toggle, a slider's step.
@MainActor
final class PanelCoverageTests: XCTestCase {
    private var window: UIWindow?

    override func setUp() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        w.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window = w
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    private func render(_ view: some View, for seconds: TimeInterval = 0.15) {
        guard let window else { return XCTFail("no window") }
        window.rootViewController = UIHostingController(rootView: AnyView(view.preferredColorScheme(.dark)))
        window.isHidden = false
        window.layoutIfNeeded()
        spin(seconds)
    }

    private func spin(_ seconds: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// A document with three pixel layers, the middle one with a mask.
    private func threeLayers() -> EditorModel {
        let model = makeModel(width: 120, height: 80)
        model.run("layer.new.layer", ["name": "A"])
        model.run("layer.new.layer", ["name": "B"])
        model.run("layer.layerMask.revealAll")
        model.run("layer.new.layer", ["name": "C"])
        return model
    }

    // MARK: Masks

    func testMaskPropertiesAndTheirButtons() throws {
        let model = threeLayers()
        let b = try XCTUnwrap(model.row("B")).id
        render(NavigationStack { MaskProperties(model: model, layer: b) })
        model.maskAction(.enabled, layer: b)
        XCTAssertEqual(model.row("B")?.mask?.enabled, false)
        model.maskAction(.linked, layer: b)
        XCTAssertEqual(model.row("B")?.mask?.linked, false)
        render(NavigationStack { MaskProperties(model: model, layer: b) })
        model.maskAction(.invert, layer: b)
        XCTAssertTrue(model.maskTarget, "invert paints on the mask")
        XCTAssertEqual(model.historyNames.last, "Invert")
        model.maskAction(.apply, layer: b)
        XCTAssertEqual(model.row("B")?.hasMask, false)
        model.run("edit.undo")
        model.maskAction(.delete, layer: b)
        XCTAssertEqual(model.row("B")?.hasMask, false)
        render(NavigationStack { MaskProperties(model: model, layer: b) })
        var done = false
        render(MaskViewBar { done = true })
        XCTAssertFalse(done)
    }

    // MARK: Timeline

    func testTimelineInEachState() throws {
        render(TimelinePanel(model: makeModel()))
        let model = threeLayers()
        render(TimelinePanel(model: model))
        XCTAssertNil(model.animation)
        model.makeFramesFromLayers()
        let count = try XCTUnwrap(model.animation?.count)
        XCTAssertGreaterThan(count, 2)
        render(TimelinePanel(model: model), for: 0.5)
        model.selectedFrames = [0, 1]
        spin()
        model.setLoops(2)
        model.startPlaying()
        spin(0.2)
        model.stopPlaying()
        spin()
        XCTAssertFalse(model.playing)
    }

    func testTimelineStepsAndDeletes() throws {
        let model = threeLayers()
        model.stepFrame(by: 1)
        XCTAssertNil(model.animation, "no animation, nothing to step")
        model.makeFramesFromLayers()
        let n = try XCTUnwrap(model.animation?.count)
        model.selectFrame(0)
        model.stepFrame(by: -1)
        XCTAssertEqual(model.animation?.current, 0, "stays on the first")
        model.stepFrame(by: 1)
        XCTAssertEqual(model.animation?.current, 1)
        model.selectFrame(n - 1)
        model.stepFrame(by: 1)
        XCTAssertEqual(model.animation?.current, n - 1, "stays on the last")
        model.startPlaying()
        XCTAssertTrue(model.playing)
        model.deleteAnimation()
        XCTAssertFalse(model.playing)
        XCTAssertNil(model.animation)

        model.togglePlay()
        XCTAssertFalse(model.playing, "nothing to play")
        model.newFrame()
        model.deleteFrames()
        XCTAssertEqual(model.framesToChange, [0])
        XCTAssertNil(model.animation)
        model.makeFramesFromLayers()
        model.togglePlay()
        XCTAssertTrue(model.playing)
        model.togglePlay()
        XCTAssertFalse(model.playing)
        render(VStack { NumberPrompt(title: "Times") { _ in XCTFail("not until OK") } })

        let info = AnimationInfo(["animation": ["frames": [["delay": 0.5], [:]]]])
        XCTAssertEqual(info?.delays, [0.5, 0])
        XCTAssertEqual(info?.current, 0)
        XCTAssertEqual(info?.loops, 0)
        XCTAssertNil(AnimationInfo(["animation": [:]]))

        XCTAssertEqual(AnimationInfo.typedLoops(0), 1)
        XCTAssertEqual(AnimationInfo.typedLoops(4.6), 5)
        XCTAssertEqual(AnimationInfo.typedLoops(1e12), 65_535)
        XCTAssertEqual(AnimationInfo.typedLoops(.nan), 1)
        XCTAssertEqual(AnimationInfo(delays: [0.1, 0.2], current: 1).count, 2)
    }

    // MARK: Tutorial

    /// Stand-ins for the screen's parts at the top and bottom, as the editor lays them out.
    private struct TutorialHost: View {
        @ObservedObject var model: EditorModel
        var big = false

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    ForEach([TutorialTarget.home, .menu, .undo, .search, .history, .view, .layers], id: \.self) { t in
                        Color.gray.frame(width: 40, height: 40).tutorialTarget(t)
                    }
                }
                Spacer()
                Color.gray.frame(height: big ? 700 : 48).tutorialTarget(.contextBar)
                HStack { Color.gray.frame(height: 48); Color.red.frame(width: 40, height: 40).tutorialTarget(.colors) }
                    .tutorialTarget(.toolbar)
            }
            .overlayPreferenceValue(TutorialAnchors.self) { TutorialOverlay(model: model, anchors: $0) }
        }
    }

    func testEveryTutorialTipShows() {
        let model = makeModel(width: 100, height: 100)
        render(TutorialHost(model: model))
        for step in TutorialStep.allCases {
            model.showTutorial(step)
            spin()
            XCTAssertFalse(step.title.isEmpty || step.text.isEmpty)
            XCTAssertEqual(model.tutorialStep, step)
        }
        render(TutorialHost(model: model, big: true))
        model.showTutorial(.toolOptions)
        spin()
        XCTAssertEqual(TutorialStep.toolOptions.target, .contextBar)
        XCTAssertTrue(TutorialOverlay.around(CGRect(x: -50, y: -50, width: 10, height: 10), in: CGSize(width: 100, height: 100))
            .contains(CGPoint(x: 50, y: 50)), "a target off screen dims it all")
        model.endTutorial()
        spin()
        XCTAssertNil(model.tutorialStep)
    }

    // MARK: Help

    func testManualAndAcknowledgements() throws {
        render(ManualView(), for: 0.3)
        render(NavigationStack { AcknowledgementsView() })
        let ack = try XCTUnwrap(Acknowledgements.load())
        let entry = try XCTUnwrap(ack.groups.first?.entries.first)
        render(NavigationStack { LicenseView(entry: entry, texts: ack.texts(of: entry)) })
        XCTAssertFalse(ack.texts(of: entry).isEmpty)
        XCTAssertNil(Acknowledgements.load(from: Bundle(for: Self.self)), "only the app has them")
    }

    // MARK: Brush Settings

    func testBrushSettingsWithEverySectionOn() {
        let model = makeModel(width: 100, height: 100)
        model.tool = .brush
        render(BrushSettingsSheet(model: model))
        for key in ["shapeDynamics", "scattering", "transfer"] { model.setBrush(path: "\(key).enabled", true) }
        model.setBrush(path: "spacingEnabled", true)
        render(BrushSettingsSheet(model: model))
        render(BrushAngleDial(model: model))
        XCTAssertEqual(BrushPaths.get(model.query("brush.get") as? [String: Any] ?? [:], "scattering.enabled") as? Bool, true)

        let presets = model.brushGroups.flatMap(\.presets).count
        model.saveBrushPreset("  ", toolSettings: true)
        XCTAssertEqual(model.brushGroups.flatMap(\.presets).count, presets, "a blank name saves nothing")
        model.saveBrushPreset(" Mine ", toolSettings: false)
        XCTAssertTrue(model.brushGroups.flatMap(\.presets).contains("Mine"))

        let b: [String: Any] = ["size": 10, "shapeDynamics": ["size": ["jitter": 0.1]]]
        let m = BrushPaths.merged(b, "shapeDynamics.size.jitter", 0.5)
        XCTAssertEqual(BrushPaths.get(m, "shapeDynamics.size.jitter") as? Double, 0.5)
        XCTAssertEqual(m["size"] as? Int, 10, "the rest stays")
        XCTAssertEqual(BrushPaths.get(BrushPaths.merged([:], "a.b", 1), "a.b") as? Int, 1)
    }

    // MARK: Layers

    /// Background, pixels with a mask, text, a smart object with a filter, a group, a gradient fill,
    /// Posterize, a shape.
    private func layered() -> EditorModel {
        let model = makeModel(width: 200, height: 120)
        model.run("layer.new.layer", ["name": "A"])
        model.run("select.rect", ["x": 10, "y": 10, "width": 40, "height": 40])
        model.run("edit.fill")
        model.run("select.deselect")
        model.run("layer.layerMask.revealAll")
        model.run("type.create", ["x": 20, "y": 100, "text": "Hello", "size": 20])
        model.run("layer.new.layer", ["name": "S"])
        model.run("edit.fill")
        model.run("filter.convertForSmartFilters")
        model.run("filter.noise.addNoise", ["amount": 10])
        model.run("layer.layerStyle.dropShadow", [:])
        model.run("layer.new.layer", ["name": "G1"])
        model.run("layer.groupLayers", ["name": "G"])
        model.run("layer.newFillLayer.gradient")
        model.run("layer.newAdjustmentLayer.posterize")
        model.run("shape.create", ["kind": "rect", "rect": [120, 20, 60, 40]])
        model.run("layer.new.layer", ["name": "S2"])
        model.run("edit.fill")
        model.run("filter.convertForSmartFilters")
        return model
    }

    private func layer(_ model: EditorModel, _ kind: String) throws -> LayerRow {
        try XCTUnwrap(model.layers.first { $0.kind == kind }, "\(kind) in \(model.layers.map(\.kind))")
    }

    func testLayersPanelStates() throws {
        let model = layered()
        let history = model.historyNames.count
        render(LayersPanel(model: model))
        // Several selected, some clipped, a mask turned off, selecting on.
        let a = try XCTUnwrap(model.row("A"))
        model.run("layer.layerMask.enabled", ["layer": a.id])
        model.run("layer.select", ["layer": try layer(model, "Shape").id])
        model.run("layer.createClippingMask")
        model.run("layer.select", ["layer": a.id, "mode": "add"])
        model.reloadLayers()
        XCTAssertEqual(model.selectedLayers.count, 2)
        model.selectingLayers = true
        render(LayersPanel(model: model))
        // A phone on its side, then no thumbnails.
        render(LayersPanel(model: model).environment(\.verticalSizeClass, .compact))
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "layerThumbnails")
        defaults.set(ThumbnailSize.none.rawValue, forKey: "layerThumbnails")
        render(LayersPanel(model: model))
        defaults.set(saved, forKey: "layerThumbnails")
        model.run("layer.select", ["layer": try XCTUnwrap(model.layers.first(where: \.isBackground)).id])
        render(LayersPanel(model: model).environment(\.horizontalSizeClass, .regular))
        XCTAssertEqual(model.historyNames.count, history + 2, "only the mask and the clip changed")
    }

    func testLayerRowActions() throws {
        let model = layered()
        var editing: LayerTextEdit?
        var properties: LayerEdit?
        let row = { (r: LayerRow) in
            LayerRowView(model: model, row: r, editing: Binding(get: { editing }, set: { editing = $0 }),
                         properties: Binding(get: { properties }, set: { properties = $0 }))
        }

        // A pixel layer: double-tapping its thumbnail renames it.
        row(try XCTUnwrap(model.row("A"))).editContent()
        XCTAssertEqual(editing?.title, "Rename Layer")
        XCTAssertEqual(model.activeLayer?.name, "A", "renaming selects it")
        editing?.apply("")
        XCTAssertNotNil(model.row("A"), "a blank name keeps the old one")
        editing?.apply("A2")
        XCTAssertNotNil(model.row("A2"))

        // Text: its words.
        row(try layer(model, "Type")).editContent()
        XCTAssertEqual(editing?.title, "Edit Text")
        XCTAssertEqual(editing?.text, "Hello")
        editing?.apply("Bye")
        XCTAssertEqual(try layer(model, "Type").name, "Bye")
        editing = nil
        row(try XCTUnwrap(model.row("A2"))).editText()
        XCTAssertNil(editing, "only text has text to edit")

        // A fill layer: its Properties.
        let fill = try layer(model, "Fill")
        row(fill).editContent()
        XCTAssertEqual(properties?.id, LayerEdit(layer: fill.id).id)

        // Lock and unlock.
        let a = try XCTUnwrap(model.row("A2"))
        row(a).lock()
        XCTAssertEqual(model.row("A2")?.locked, true)
        row(try XCTUnwrap(model.row("A2"))).lock()
        XCTAssertEqual(model.row("A2")?.locked, false, "Lock again unlocks")

        // Selecting several: a tap adds or takes away.
        model.run("layer.select", ["layer": a.id])
        model.selectingLayers = true
        row(fill).tapped()
        XCTAssertEqual(Set(model.selectedLayers.map(\.id)), [a.id, fill.id])
        model.selectingLayers = false
        row(fill).tapped()
        XCTAssertEqual(model.selectedLayers.map(\.id), [fill.id])
        row(try XCTUnwrap(model.row("A2"))).openStyle("blendingOptions")
        XCTAssertEqual(model.request, .layerStyle("blendingOptions"))
        XCTAssertEqual(model.activeLayer?.id, a.id)

        // The Background becomes a normal layer to be renamed or unlocked.
        let bg = try XCTUnwrap(model.layers.first(where: \.isBackground))
        row(bg).rename()
        XCTAssertEqual(editing?.title, "New Layer")
        editing?.apply("Base")
        XCTAssertNil(model.layers.first(where: \.isBackground))
        XCTAssertNotNil(model.row("Base"))
        model.run("edit.undo")
        model.run("edit.undo")
        let bg2 = try XCTUnwrap(model.layers.first(where: \.isBackground))
        row(bg2).lock()
        XCTAssertNil(model.layers.first(where: \.isBackground), "the Background's lock unlocks it")

        // A group renames; a smart object opens as its own document.
        row(try XCTUnwrap(model.row("G"))).editContent()
        XCTAssertEqual(editing?.title, "Rename Layer")
        let docs = model.documents.count
        row(try XCTUnwrap(model.row("S"))).editContent()
        wait("its contents open") { model.documents.count == docs + 1 && !model.busy }
        XCTAssertEqual(model.request, .closePanels)
    }

    func testFilterAndEffectRows() throws {
        let model = layered()
        let s = try XCTUnwrap(model.row("S"))
        var properties: LayerEdit?
        let rows = SmartFilterRows(model: model, row: s, properties: Binding(get: { properties }, set: { properties = $0 }))
        let noise = try XCTUnwrap(s.smartFilters.first)
        rows.edit(noise)
        XCTAssertEqual(properties?.id, LayerEdit(layer: s.id, part: .smartFilter(noise.index)).id)
        rows.edit(SmartFilterRow(index: 0, command: "filter.cameraRaw", name: "Develop", visible: true))
        XCTAssertEqual(model.request, .closePanels)
        wait("Develop opens once the panel has gone", timeout: 3) { model.developEdit != nil }
        rows.edit(SmartFilterRow(index: 0, command: "filter.liquify", name: "Fluid Warp", visible: true))
        XCTAssertEqual(model.fluidWarp?.layer, s.id)
        model.fluidWarp = nil

        let effects = EffectRows(model: model, row: try XCTUnwrap(model.layers.first { $0.id == s.id }))
        effects.edit(try XCTUnwrap(s.effects.first))
        XCTAssertEqual(model.request, .layerStyle("dropShadow"))
        effects.edit(EffectRow(index: 9, name: "Unknown", visible: true))
        XCTAssertEqual(model.request, .layerStyle("blendingOptions"))

        let ids = [LayerEdit(layer: 1).id, LayerEdit(layer: 1, part: .smartFilter(0)).id, LayerEdit(layer: 1, part: .filterBlending(0)).id, LayerEdit(layer: 1, part: .mask).id]
        XCTAssertEqual(Set(ids).count, 4, "each part opens its own sheet")
    }

    func testMergeMoveAndNewLayerSettings() throws {
        let model = threeLayers()
        let n = model.layerCount
        LayersPanel(model: model).move(from: [0], to: 3)
        XCTAssertEqual(model.layers.first?.name, "B", "C moved down")
        XCTAssertEqual(model.layerCount, n)
        model.mergeDown()
        XCTAssertEqual(model.layerCount, n - 1)
        model.run("layer.select", ["layer": try XCTUnwrap(model.layers.first).id])
        model.run("layer.select", ["layer": try XCTUnwrap(model.layers.dropFirst().first).id, "mode": "add"])
        model.reloadLayers()
        model.mergeDown()
        XCTAssertEqual(model.layerCount, n - 2, "the two selected merge")

        let p = NewLayerSheet.params(name: "", clip: true, color: "red", mode: "Overlay", opacity: 0.5, neutral: true)
        XCTAssertNil(p["name"])
        XCTAssertEqual(p["fillNeutral"] as? Bool, true)
        XCTAssertEqual(NewLayerSheet.params(name: "N", clip: false, color: "none", mode: "Normal", opacity: 1, neutral: true)["fillNeutral"] as? Bool, false,
                       "Normal has no neutral colour")
        model.run("layer.new.layer", NewLayerSheet.params(name: "N", clip: false, color: "none", mode: "Overlay", opacity: 1, neutral: true))
        XCTAssertEqual(model.row("N")?.blend, "Overlay")
    }

    // MARK: Layer Properties

    func testLayerPropertiesForEveryPart() throws {
        let model = layered()
        let s = try XCTUnwrap(model.row("S"))
        model.run("layer.select", ["layer": s.id])
        model.run("filter.cameraRaw", ["exposure": 0.5])
        let a = try XCTUnwrap(model.row("A"))
        let history = model.historyNames
        render(LayerPropertiesSheet(model: model, edit: LayerEdit(layer: a.id, part: .mask)))
        render(LayerPropertiesSheet(model: model, edit: LayerEdit(layer: s.id, part: .filterBlending(0))))
        let develop = try XCTUnwrap(model.layers.first { $0.id == s.id }?.smartFilters.first { $0.command == "filter.cameraRaw" })
        render(LayerPropertiesSheet(model: model, edit: LayerEdit(layer: s.id, part: .smartFilter(develop.index))), for: 0.3)
        model.liveCancel()
        idle(model)
        render(LayerPropertiesSheet(model: model, edit: LayerEdit(layer: try layer(model, "Adjustment").id)))
        let shape = try layer(model, "Shape")
        render(LayerPropertiesSheet(model: model, edit: LayerEdit(layer: shape.id)))
        let fill = try layer(model, "Fill")
        render(LayerPropertiesContent(model: model, edit: LayerEdit(layer: fill.id), inPanel: true).environment(\.horizontalSizeClass, .regular))
        XCTAssertEqual(model.historyNames.filter { !$0.hasPrefix("Select") }, history.filter { !$0.hasPrefix("Select") }, "opening them changes nothing")

        // A solid colour fill.
        model.run("layer.newFillLayer.solidColor", ["color": [1, 0, 0, 1]])
        render(LayerPropertiesSheet(model: model, edit: LayerEdit(layer: try XCTUnwrap(model.activeLayer).id)))
        XCTAssertEqual(model.activeLayer?.kind, "Fill")
    }

    func testDraggingInTheImageMovesTheGradient() throws {
        let model = layered()
        let fill = try layer(model, "Fill")
        let before = try XCTUnwrap(model.query("gradient.fill.get", ["layer": fill.id]) as? [String: Any])
        render(NavigationStack { FillProperties(model: model, layer: fill.id, inPanel: true) })
        let drag = try XCTUnwrap(model.sheetDrag, "beside the canvas, a drag moves it")
        drag.moved(true, Point(x: 0, y: 0), Point(x: 10, y: 5))
        drag.moved(false, Point(x: 0, y: 0), Point(x: 20, y: 10))
        let after = try XCTUnwrap(model.query("gradient.fill.get", ["layer": fill.id]) as? [String: Any])
        let from = { (g: [String: Any]) in (g["from"] as? [NSNumber])?.map(\.doubleValue) ?? [] }
        XCTAssertEqual(from(after), zip(from(before), [20.0, 10]).map { $0 + $1 }, "from where the drag began")
        render(Text(""))
        XCTAssertNil(model.sheetDrag, "closing Properties lets go")

        let stops = [[0.0, 100], [1, 50]]
        XCTAssertEqual(FillProperties.transparency(stops, stop: 1, at: 0.4, opacity: nil), [[0, 100], [0.4, 50]])
        XCTAssertEqual(FillProperties.transparency(stops, stop: 0, at: nil, opacity: 20), [[0, 20], [1, 50]])
        XCTAssertNil(FillProperties.transparency(stops, stop: 2, at: 0, opacity: 0))
    }

    func testHueSaturationRangeAndTargetedAdjust() throws {
        XCTAssertEqual(HueSaturationProperties.range([0, 10, 20, 30], setting: 1, to: 25.4), [0, 25, 25, 30], "pushes the next along")
        XCTAssertEqual(HueSaturationProperties.range([0, 10, 20, 30], setting: 3, to: -5), [-5, -5, -5, -5])
        XCTAssertEqual(HueSaturationProperties.range([0, 10], setting: 4, to: 1), [0, 10])

        let model = makeModel(width: 60, height: 40)
        model.run("layer.newAdjustmentLayer.hueSaturation")
        let l = try XCTUnwrap(model.activeLayer).id
        model.setTargetedAdjust(true, layer: l, key: "k", inPanel: false)
        XCTAssertEqual(model.targetedAdjust?.layer, l)
        XCTAssertEqual(model.request, .panel(.properties), "dragging needs the canvas")
        render(NavigationStack { HueSaturationProperties(model: model, layer: l, key: "k", inPanel: true) })
        render(NavigationStack { HueSaturationProperties(model: model, layer: l, key: "k", inPanel: true, part: "reds") })
        model.request = nil
        model.setTargetedAdjust(false, layer: l, key: "k", inPanel: true)
        XCTAssertNil(model.targetedAdjust)
        XCTAssertNil(model.request)
        render(NavigationStack { HueSaturationProperties(model: model, layer: nil, key: "k", inPanel: false, initial: ["hue": 10], part: "blues") })

        // Each sheet's changes are one step.
        let steps = model.historyNames.count
        model.setAdjustment(l, ["hue": 10], key: "k")
        model.setAdjustment(l, ["hue": 20], key: "k")
        XCTAssertEqual(model.historyNames.count, steps + 1)
        XCTAssertEqual((model.activeLayer?.adjustment?.params["hue"] as? NSNumber)?.doubleValue, 20)
    }

    func testLiveFilterSettingsAndCorners() throws {
        let model = layered()
        let s = try XCTUnwrap(model.row("S"))
        let noise = try XCTUnwrap(s.smartFilters.first)
        let steps = model.historyNames.count
        model.liveBegin()
        model.setSmartFilter(s.id, noise.index, ["amount": 40])
        idle(model)
        model.setSmartFilter(s.id, noise.index, ["amount": 50], done: true)
        idle(model)
        XCTAssertEqual(model.historyNames.count, steps + 1, "tries are one step once kept")
        let amount = model.layers.first { $0.id == s.id }?.smartFilters.first?.params["amount"] as? NSNumber
        XCTAssertEqual(amount?.doubleValue, 50)

        let shape = try layer(model, "Shape")
        XCTAssertEqual(model.setCornerRadius(shape.id, 7.6, key: "r"), 8)
        model.setCornerRadius(shape.id, 9, key: "r")
        let live = (model.query("shape.info", ["layer": shape.id]) as? [String: Any])?["live"] as? [String: Any]
        let r = live?["radii"]
        XCTAssertEqual((r as? NSNumber)?.doubleValue ?? (r as? [NSNumber])?.first?.doubleValue, 9)
        XCTAssertEqual(model.historyNames.count, steps + 2, "one step for the corners")
    }

    // MARK: Options bar

    func testOptionsBarWhileWorkIsInProgress() throws {
        let model = threeLayers()
        model.run("select.rect", ["x": 10, "y": 10, "width": 30, "height": 30])
        model.run("edit.fill")
        model.run("edit.copy")
        let history = model.historyNames.count
        let bar = { self.render(ContextBar(model: model)) }
        model.tool = .aiRemove
        bar()
        model.tool = .marquee
        bar()
        model.tool = .pen
        bar()
        model.run("select.deselect")

        model.beginTransform()
        XCTAssertNotNil(model.transform)
        bar()
        model.setTransformPivot(0, 0)
        let t = try XCTUnwrap(model.transform)
        model.flipTransform(horizontal: true)
        model.flipTransform(horizontal: false)
        XCTAssertEqual(model.transform?.sx, -t.sx)
        XCTAssertEqual(model.transform?.sy, -t.sy)
        model.cancelPending()
        XCTAssertNil(model.transform)
        model.flipTransform(horizontal: true)
        model.setTransformPivot(1, 1)
        XCTAssertNil(model.transform, "nothing to flip")

        let c = try XCTUnwrap(model.row("C")).id
        model.puppet = Puppet(layer: c, pins: [Puppet.Pin(src: Point(x: 5, y: 5), dst: Point(x: 6, y: 6), rotate: 30)], selected: 0)
        bar()
        model.deletePuppetPin(3)
        XCTAssertEqual(model.puppet?.pins.count, 1)
        model.deletePuppetPin(0)
        XCTAssertEqual(model.puppet?.pins.count, 0)
        XCTAssertNil(model.puppet?.selected)
        bar()
        model.puppet = nil

        model.fluidWarp = FluidWarp(layer: c)
        model.fluidWarp?.add([[1, 1], [5, 5]])
        model.fluidWarp?.amount = 50
        bar()
        model.restoreFluidWarp()
        XCTAssertEqual(model.fluidWarp?.strokes.count, 0)
        XCTAssertEqual(model.fluidWarp?.amount, 100)
        model.fluidWarp = nil

        model.tool = .remove
        model.removeStrokes = [[Point(x: 1, y: 1)]]
        bar()
        model.removeStrokes = []
        model.tool = .crop
        model.straightening = true
        bar()
        model.straightening = false
        model.cropAngle = 5
        bar()
        model.cancelPending()
        model.cropAngle = 0
        render(ToolTip(tool: .brush))
        XCTAssertEqual(model.historyNames.count, history + 1, "only the Deselect: showing the options changes nothing")
    }

    func testWorkPathButtons() throws {
        let model = threeLayers()
        model.run("path.set", ["name": "work", "path": ["subpaths": [["closed": true, "knots": [[10, 10], [60, 10], [60, 50]]]]]])
        model.loadWorkPath()
        XCTAssertFalse(model.workPath.isEmpty)
        let n = model.layerCount
        model.workPathToShape()
        XCTAssertEqual(model.layerCount, n + 1)
        XCTAssertEqual(model.activeLayer?.kind, "Shape")
        model.run("layer.select", ["layer": try XCTUnwrap(model.row("C")).id])
        model.deleteWorkPath()
        XCTAssertTrue(model.workPath.isEmpty)
        model.workPathToShape()
        XCTAssertEqual(model.layerCount, n + 1, "no path, no shape")
    }

    func testTypeOptionsApplyToTheTextBeingEdited() throws {
        let model = makeModel(width: 200, height: 100)
        model.setTypeStyle("tracking", 20)
        model.run("type.create", ["x": 10, "y": 50, "text": "Hi", "size": 20])
        model.tool = .type
        let steps = model.historyNames.count
        XCTAssertNotNil(model.editingText)
        render(TypeOptions(model: model))
        model.setTypeAlign("center")
        XCTAssertEqual(model.typeAlign, "center")
        model.setTypeFont(model.typeFont)
        model.setTypeNumber("size", 0, edit: 1)
        XCTAssertEqual(model.historyNames.count, steps + 2, "a size of 0 isn't set")
        model.setTypeNumber("tracking", 0, edit: 1)
        model.setTypeNumber("tracking", 10, edit: 1)
        XCTAssertEqual(model.historyNames.count, steps + 3, "one edit, one step")
        model.finishEditingText()
        XCTAssertNil(model.editingText)
        model.setTypeStyle("tracking", 50)
        XCTAssertEqual(model.historyNames.count, steps + 3, "nothing without text being edited")
    }

    // MARK: Panels

    func testAdjustPanelForEachKind() {
        let model = threeLayers()
        let steps = model.historyNames.count
        render(AdjustPanel(model: model))
        render(AdjustPanel(model: model, kind: .hueSaturation))
        XCTAssertEqual(model.historyNames.count, steps, "nothing is added until a slider moves")
        XCTAssertEqual(AdjustPanel.Kind.hueSaturation.command, "layer.newAdjustmentLayer.hueSaturation")
    }

    func testHistoryPropertiesAndCommandSearch() throws {
        let model = threeLayers()
        model.run("edit.undo")
        XCTAssertFalse(model.history.redo.isEmpty)
        render(HistoryPanel(model: model))
        let b = try XCTUnwrap(model.row("B")).id
        model.targetLayer(b, mask: true)
        render(PropertiesPanel(model: model))
        render(PropertiesPanel(model: makeModel()))

        let commands = model.editor.commands()
        XCTAssertEqual(CommandSearch.matching(commands, "  ").count, commands.count)
        let blur = CommandSearch.matching(commands, "gaussian")
        XCTAssertEqual(blur.map(\.id), ["filter.blur.gaussianBlur"])
        let c = try XCTUnwrap(blur.first)
        XCTAssertTrue(CommandSearch.asksForSettings(c, fields: model.editor.commandFields(id: c.id)))
        XCTAssertFalse(CommandSearch.asksForSettings(c, fields: []))
        var ran: [String: Any]?
        render(NavigationStack { CommandSettings(command: c, fields: model.editor.commandFields(id: c.id)) { ran = $0 } })
        XCTAssertNil(ran, "nothing runs until OK")
    }

    func testActionsRecordPlayRenameAndSave() throws {
        let model = threeLayers()
        let state = ActionsState(model: model)
        render(ActionsPanel(model: model) {})
        state.reload()
        XCTAssertTrue(state.actions.isEmpty)
        state.play()
        state.deleteSelected()

        state.newAction()
        XCTAssertEqual(state.editing?.text, "Action 1")
        state.editing?.text = "Mine"
        state.finishEditing()
        XCTAssertNil(state.editing)
        XCTAssertEqual(model.recordingAction, "Mine")
        XCTAssertEqual(state.selected, "Mine")
        render(ActionsPanel(model: model) {})
        model.run("layer.new.layer", ["name": "Recorded"])
        state.stop()
        XCTAssertNil(model.recordingAction)
        XCTAssertEqual(state.actions.first?.steps.count, 1)
        XCTAssertEqual(state.sets, ["Actions"])

        state.toggleExpanded("Mine")
        XCTAssertEqual(state.expanded, ["Mine"])
        render(ActionsPanel(model: model, state: state) {})
        state.toggleExpanded("Mine")
        XCTAssertTrue(state.expanded.isEmpty)
        state.rename("Mine")
        state.editing?.text = "Renamed"
        state.finishEditing()
        XCTAssertEqual(state.selected, "Renamed")
        state.addToSet()
        XCTAssertEqual(state.editing?.text, "Set 1")
        state.finishEditing()
        XCTAssertEqual(state.actions.first?.set, "Set 1")
        render(ActionsPanel(model: model) {})

        let n = model.layerCount
        state.play()
        wait("it plays") { model.layerCount == n + 1 && !model.busy }
        state.run("actions.toggle", ["action": "Renamed"])
        XCTAssertEqual(state.actions.first?.on, false)

        let dir = try tempFolder()
        state.save(to: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Set 1.atn").path))
        XCTAssertEqual(model.toast, "Saved Set 1.atn")
        state.save(to: dir.appendingPathComponent("missing"))
        XCTAssertNotEqual(model.toast, "Saved Set 1.atn", "a folder that isn't there says so")

        state.deleteSelected()
        XCTAssertTrue(state.actions.isEmpty)
        XCTAssertNil(state.selected)
    }
}
