import SwiftUI
import XCTest
@testable import PhotoWagon

/// Every panel and sheet builds for a document with every kind of layer, without crashing and
/// without changing the document (opening a panel is never an edit). Layout and taps are the UI
/// tests' job.
@MainActor
final class PanelRenderTests: XCTestCase {
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

    /// Show `view` in a window long enough for its body and `onAppear` to run.
    private func render(_ view: some View, for seconds: TimeInterval = 0.15) {
        guard let window else { return XCTFail("no window") }
        window.rootViewController = UIHostingController(rootView: AnyView(view.preferredColorScheme(.dark)))
        window.isHidden = false
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// A document with a pixel layer, a group, a smart object with a filter, mask and styles, text,
    /// a shape, a gradient fill and Hue/Saturation.
    private func everyKind() -> EditorModel {
        let model = makeModel(width: 300, height: 200)
        model.run("layer.new.layer", ["name": "A"])
        model.run("layer.groupLayers", ["name": "G"])
        model.run("layer.new.layer", ["name": "C"])
        model.run("select.rect", ["x": 0, "y": 0, "width": 60, "height": 60])
        model.run("edit.fill")
        model.run("select.deselect")
        model.run("filter.convertForSmartFilters")
        model.run("filter.noise.addNoise", ["amount": 10])
        model.run("layer.layerMask.revealAll")
        model.run("layer.layerStyle.dropShadow", [:])
        model.run("type.create", ["x": 20, "y": 150, "text": "Hello", "size": 30])
        model.run("shape.create", ["kind": "roundedRect", "rect": [150, 20, 80, 60]])
        model.run("layer.newFillLayer.gradient")
        model.run("layer.newAdjustmentLayer.hueSaturation")
        model.run("layer.newAdjustmentLayer.levels")
        XCTAssertEqual(model.layerCount, 9, "\(model.layers.map(\.name)) \(model.toast ?? "")")
        return model
    }

    func testPanelsBuildForEveryKindOfLayerWithoutEditing() throws {
        let model = everyKind()
        let history = model.historyNames
        render(LayersPanel(model: model))
        render(HistoryPanel(model: model))
        render(AdjustPanel(model: model))
        render(ActionsPanel(model: model) {})
        render(CommandSearch(model: model))
        for layer in model.layers {
            model.run("layer.select", ["layer": layer.id])
            render(PropertiesPanel(model: model))
        }
        // A collapsed group and thumbnails off.
        if let g = model.row("G") { model.run("layer.setExpanded", ["layer": g.id, "expanded": false]) }
        model.reloadLayers()
        render(LayersPanel(model: model))
        let edits = { (h: [String]) in h.filter { !$0.hasPrefix("Select") } }
        XCTAssertEqual(edits(model.historyNames), edits(history), "picking layers is the only change")
    }

    func testLayerPropertiesForEachKind() throws {
        let model = everyKind()
        for layer in model.layers {
            render(LayerPropertiesSheet(model: model, edit: LayerEdit(layer: layer.id)))
            if !layer.smartFilters.isEmpty {
                render(LayerPropertiesSheet(model: model, edit: LayerEdit(layer: layer.id, part: .smartFilter(0))))
                idle(model)
            }
        }
        render(LayerPropertiesSheet(model: model, edit: LayerEdit(layer: 999_999)))
        XCTAssertEqual(model.row("C")?.smartFilters.count, 1, "showing a filter's settings keeps it")
    }

    func testTheOptionsBarForEveryTool() {
        let model = everyKind()
        let history = model.historyNames
        render(ToolBar(model: model))
        render(ToolBar(model: model, vertical: true))
        render(ContextBar(model: model))
        let spin = { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        for g in Tool.groups.indices {
            model.pickingGroup = g
            spin()
        }
        model.pickingGroup = nil
        for t in Tool.allCases {
            model.tool = t
            spin()
        }
        model.tool = .type
        render(TypeOptions(model: model))
        XCTAssertEqual(model.historyNames, history)
    }

    func testLayerStylePages() throws {
        let model = everyKind()
        let c = try XCTUnwrap(model.row("C")).id
        let history = model.historyNames.count
        render(LayerStyleSheet(model: model, layer: c, start: "blendingOptions"))
        XCTAssertEqual(model.historyNames.count, history, "opening Blending Options changes nothing")
        for k in LayerStyle.kinds {
            render(LayerStyleSheet(model: model, layer: c, start: k.kind), for: 0.05)
        }
        XCTAssertNotNil(model.row("C")?.effects.first { $0.name == "Bevel & Emboss" }, "opening a missing effect adds it")
    }

    func testFileSheetsAndHome() throws {
        let model = makeModel()
        render(HomeView(model: model))
        let dir = try tempFolder()
        let url = dir.appendingPathComponent("recent.png")
        try XCTUnwrap(UIImage(systemName: "star")?.pngData()).write(to: url)
        model.newDocument(["width": 64, "height": 64, "name": "doc"])
        model.savedAs(url)
        render(HomeView(model: model), for: 0.3)
        render(DocumentTabs(model: model))
        render(StatusBar(model: model))
        render(NewDocumentSheet(model: model))
        render(SaveSheet(model: model, copy: false) { _, _, _ in })
        render(SaveSheet(model: model, copy: true) { _, _, _ in })
        render(ExportSheet(model: model))
        render(NewLayerSheet(model: model))
        render(FileBrowser(title: "Open", pick: { _ in }, browse: {}, photos: {}))
        render(PromptSheet(prompt: TextPrompt(title: "Text", text: "hi") { _ in }) {})
        model.toast = "Saved"
        render(ToastView(model: model))
        XCTAssertEqual(model.documents.count, 1)
    }

    func testSettingsScreensTryTheirStartingSettings() throws {
        let model = makeModel()
        open("beach.jpg", in: model)
        let blur = try XCTUnwrap(model.editor.commands().first { $0.id == "filter.blur.gaussianBlur" })
        model.liveBegin()
        render(NavigationStack {
            CommandSettings(title: "Gaussian Blur", fields: model.editor.commandFields(id: blur.id), initial: [:], runTitle: "OK",
                            change: { model.live(blur.id, $0) }, changeOnAppear: true) { model.liveFinish(blur.id, $0) }
        }, for: 0.3)
        idle(model)
        XCTAssertEqual(model.historyNames.last, "Gaussian Blur", "a filter shows its result as its settings open")
        model.liveCancel()
        idle(model)
        XCTAssertNotEqual(model.historyNames.last, "Gaussian Blur")

        model.liveBegin()
        render(CameraRawView(model: model, change: { model.live("filter.cameraRaw", $0) }, cancel: { model.liveCancel() }) { model.liveFinish("filter.cameraRaw", $0) }, for: 0.3)
        idle(model)
        model.liveCancel()
        idle(model)
        render(PreviewPane(model: model), for: 0.3)
    }
}
