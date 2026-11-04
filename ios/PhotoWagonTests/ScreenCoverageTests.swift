import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UIKit.UIGestureRecognizerSubclass
import XCTest
@testable import PhotoWagon

/// Screens shown in a window so their body and `onAppear` run, the small types their buttons
/// call, and the canvas's gesture handlers fed recognizers that report fixed points.
@MainActor
final class ScreenCoverageTests: XCTestCase {
    private var window: UIWindow?

    override func setUp() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        w.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window = w
    }

    override func tearDown() async throws {
        window?.rootViewController?.dismiss(animated: false)
        window?.isHidden = true
        window = nil
    }

    /// Show `view` in a window long enough for its body and `onAppear` to run.
    private func render(_ view: some View, for seconds: TimeInterval = 0.15) {
        guard let window else { return XCTFail("no window") }
        window.rootViewController?.dismiss(animated: false)
        window.rootViewController = UIHostingController(rootView: AnyView(view.preferredColorScheme(.dark)))
        window.isHidden = false
        window.layoutIfNeeded()
        spin(seconds)
    }

    private func spin(_ seconds: TimeInterval = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func info(_ id: String, _ label: String = "Settings…", menu: String = "Filter") -> CommandInfo {
        CommandInfo(id: id, label: label, menu: menu, enabled: true, reason: nil, params: "{}")
    }

    /// A white document with a red square and a blue one.
    private func picture(_ w: Int = 120, _ h: Int = 80) -> EditorModel {
        let model = makeModel(width: w, height: h)
        model.run("select.rect", ["x": 10, "y": 10, "width": 30, "height": 30])
        model.run("edit.fill", ["color": "#d02020"])
        model.run("select.rect", ["x": 60, "y": 20, "width": 30, "height": 30])
        model.run("edit.fill", ["color": "#2040c0"])
        model.run("select.deselect")
        return model
    }

    // MARK: - Small screens

    func testAutoOptionsAndPencilScreens() {
        XCTAssertEqual(AutoOptions.Method.allCases.map(\.title), ["Monochromatic Contrast", "Per Channel Contrast", "Find Dark & Light Colors"])
        var applied: AutoOptions?
        render(AutoOptionsSheet(options: AutoOptions(method: .darkLight, snapNeutral: true)) { applied = $0 })
        XCTAssertNil(applied, "nothing runs before OK")

        let model = makeModel(width: 100, height: 100)
        model.tool = .eraser
        render(PencilPalette(model: model, at: CGPoint(x: 40, y: 40)))
        let c = UIColor(rgb: [0.2, 0.4, 0.6]).rgb
        XCTAssertEqual(c[0], 0.2, accuracy: 0.001)
        XCTAssertEqual(c[2], 0.6, accuracy: 0.001)
        XCTAssertEqual(UIColor(rgb: [1]).rgb, [0, 0, 0], "a colour that isn't RGB is black")

        model.pencilTap = .undo
        model.pencilSqueeze = .palette
        XCTAssertEqual(model.pencilTap, .undo)
        XCTAssertEqual(model.pencilSqueeze, .palette)
        if #available(iOS 17.5, *) { XCTAssertEqual(PencilAction.from(.showContextualPalette), .palette) }
        XCTAssertEqual(PencilAction.from(UIPencilPreferredAction(rawValue: 99) ?? .ignore), .off)
        XCTAssertEqual(PencilPressure.firm.id, "firm")
    }

    func testPressureCurveRoundTripsThroughTheEngine() {
        let model = makeModel(width: 50, height: 50)
        XCTAssertEqual(model.pressurePoints, [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 255)])
        model.pressurePoints = PencilPressure.light.curve.map { CGPoint(x: $0[0] * 255, y: $0[1] * 255) }
        XCTAssertEqual(model.pencilPressure, .light)
        model.pressurePoints = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 30), CGPoint(x: 255, y: 255)]
        XCTAssertNil(model.pencilPressure, "a curve of its own")
        render(NavigationStack { PressureCurveView(model: model) })
        render(GeneralPreferencesSheet(model: model))
        XCTAssertEqual(model.pressurePoints.count, 3, "showing the screens changes nothing")
    }

    func testPreviewScreens() {
        let model = picture()
        let history = model.historyNames
        render(FullScreenPreview(model: model, selection: false), for: 0.5)
        model.run("select.rect", ["x": 0, "y": 0, "width": 50, "height": 50])
        render(FullScreenPreview(model: model, selection: true), for: 0.5)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        render(PreviewLoupe(image: image, fit: CGRect(x: 0, y: 0, width: 200, height: 100), finger: CGPoint(x: 180, y: 10), pane: CGSize(width: 200, height: 100)))
        model.previewClipping = true
        model.beginPick(.preview, prompt: "") { _ in }
        render(PreviewPane(model: model), for: 0.5)
        model.endPick()
        XCTAssertEqual(model.historyNames.count, history.count + 1, "only the selection changed")
    }

    // MARK: - AI Remove's model

    func testTheModelIsFoundDeletedAndAZipThatIsntOneRefused() throws {
        let dir = try tempFolder()
        let missing = ModelDownload(folder: dir)
        XCTAssertEqual(missing.state, .missing)
        XCTAssertNil(missing.inpainter)
        try FileManager.default.createDirectory(at: missing.compiled, withIntermediateDirectories: true)
        let ready = ModelDownload(folder: dir)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.inpainter?.side, ModelDownload.side)
        ready.download()
        XCTAssertEqual(ready.state, .ready, "nothing to download")
        ready.delete()
        XCTAssertEqual(ready.state, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ready.compiled.path))

        let zip = dir.appendingPathComponent("model.zip")
        try Data("not a zip".utf8).write(to: zip)
        XCTAssertThrowsError(try ModelDownload.install(zip: zip, into: dir, sha256: ModelDownload.digest(zip)), "the checksum matches but it won't unpack")
        XCTAssertThrowsError(try CoreMLInpainter(url: dir, side: 4).fill(image: Data(), mask: Data()), "a picture of the wrong size")
    }

    /// Reaches the network: `TEST_RUNNER_NETWORK_TESTS=1 xcodebuild test …` runs it.
    func testDownloadStartsAndCancels() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NETWORK_TESTS"] == "1", "talks to the network")
        try XCTSkipIf(ModelDownload.shared.state == .ready, "the model is on this simulator")
        let model = makeModel(width: 50, height: 50)
        model.aiRemoveWaiting = .selection
        model.downloadAIModel()
        XCTAssertNil(model.aiRemoveWaiting, "what waited goes with the download")
        render(ToastView(model: model))
        render(GeneralPreferencesSheet(model: model))
        ModelDownload.shared.cancel()
        wait("the download stops") {
            if case .downloading = ModelDownload.shared.state { return false }
            return true
        }
        XCTAssertNotEqual(ModelDownload.shared.state, .ready)
        if ModelDownload.shared.state == .missing { XCTAssertNil(model.toast, "cancelling says nothing") }
    }

    func testPersonMatteAndMaskParams() {
        let model = picture(64, 64)
        if let m = ObjectFinder().personMatte(model.editor, layer: nil) {
            XCTAssertEqual(m.data.count, m.width * m.height)
        }
        let mask = ObjectFinder.Mask(width: 2, height: 1, data: Data([0, 255]))
        XCTAssertEqual(mask.params["data"] as? String, "AP8=")
        XCTAssertEqual(mask.params["width"] as? Int, 2)
    }

    // MARK: - Command screens

    func testEveryCommandScreenTriesItsSettings() {
        let model = picture()
        model.run("layer.new.layer", ["name": "Top"])
        for id in CommandEditor.handled.sorted() where !["image.mode.duotone", "image.mode.colorTable"].contains(id) {
            var tries = 0
            render(NavigationStack { CommandEditor(model: model, command: info(id), change: { _ in tries += 1 }, run: { _ in }) }, for: 0.3)
            XCTAssertGreaterThan(tries, 0, "\(id) shows its first try")
        }
        render(NavigationStack { CommandEditor(model: model, command: info("filter.distort.shear"), change: nil, run: { _ in }) })
        model.endPick()
    }

    func testDuotoneAndColorTableScreensReadTheImage() {
        let gray = picture()
        gray.run("image.mode.grayscale")
        render(NavigationStack { DuotoneEditor(model: gray) { _ in } })
        gray.run("image.mode.duotone", ["type": "duotone"])
        render(NavigationStack { DuotoneEditor(model: gray) { _ in } })

        let indexed = picture()
        indexed.run("image.mode.indexedColor")
        XCTAssertFalse(((indexed.query("image.mode.colorTable") as? [String: Any])?["colors"] as? [String] ?? []).isEmpty)
        render(NavigationStack { ColorTableEditor(model: indexed) { _ in } })
    }

    func testShearGraphAddsAndMovesPoints() {
        var pts = ShearEditor.straight
        var dragging: Int?
        let size = CGSize(width: 200, height: 200)
        ShearGraph.drag(&pts, &dragging, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 150, y: 100), size: size)
        XCTAssertEqual(pts.count, 3, "a drag off the points adds one")
        XCTAssertEqual(dragging, 1)
        XCTAssertEqual(pts[1], CGPoint(x: 0.5, y: 0.5))
        dragging = nil
        ShearGraph.drag(&pts, &dragging, from: CGPoint(x: 100, y: 199), to: CGPoint(x: 0, y: 150), size: size)
        XCTAssertEqual(dragging, 2, "the bottom point, picked up")
        XCTAssertEqual(pts[2], CGPoint(x: -1, y: 1), "it stays at the bottom")
        dragging = nil
        ShearGraph.drag(&pts, &dragging, from: CGPoint(x: 150, y: 100), to: CGPoint(x: 150, y: 260), size: size)
        XCTAssertEqual(pts[1].y, 0.99, accuracy: 0.001, "a middle point stays between its neighbours")
    }

    func testColorRangeSamples() {
        var p = ColorRangeEditor.sample(["fuzziness": 40], picker: "pick", at: [1, 2])
        XCTAssertEqual(p["points"] as? [[Int]], [[1, 2]])
        p = ColorRangeEditor.sample(p, picker: "add", at: [3, 4])
        p = ColorRangeEditor.sample(p, picker: "subtract", at: [5, 6])
        XCTAssertEqual(p["points"] as? [[Int]], [[1, 2], [3, 4]])
        XCTAssertEqual(p["subtractPoints"] as? [[Int]], [[5, 6]])
        XCTAssertEqual(p["order"] as? [String], ["+", "+", "-"])
        p = ColorRangeEditor.sample(p, picker: "pick", at: [7, 8])
        XCTAssertEqual(p["points"] as? [[Int]], [[7, 8]], "a new pick starts again")
        XCTAssertEqual(p["subtractPoints"] as? [[Int]], [])
    }

    // MARK: - Develop

    func testDevelopTriesUndoAndWhiteBalance() {
        var t = DevelopTries()
        XCTAssertNil(t.tried(), "nothing is tried before the image loads")
        let rgb = (0..<600).map { i -> SIMD3<Float> in let v = Float(30 + i % 200); return SIMD3(v, v * 0.85, v * 0.6) }
        t.load([:], pixels: AutoPixels(rgb: rgb))
        XCTAssertEqual(t.whiteBalance, "asShot")
        t.settings["exposure"] = 1
        XCTAssertNotNil(t.tried())
        XCTAssertEqual(t.undo.count, 1)
        XCTAssertNotNil(t.setWhiteBalance("auto"))
        XCTAssertEqual(t.whiteBalance, "auto")
        XCTAssertGreaterThan(abs(t.settings["temperature"]), 0, "a warm image is cooled")
        XCTAssertNil(t.setWhiteBalance("custom"))
        XCTAssertNotNil(t.setWhiteBalance("asShot"))
        XCTAssertEqual(t.whiteBalance, "asShot")
        let now = t.settings
        XCTAssertNotNil(t.step(back: true))
        XCTAssertNotEqual(t.settings, now)
        XCTAssertNotNil(t.step(back: false))
        XCTAssertEqual(t.settings, now)
        XCTAssertNil(t.step(back: false), "nothing to redo")
        XCTAssertNotNil(t.applyAuto(DevelopSettings.light.map(\.key)))
        XCTAssertNotNil(t.autoValue("tint"))
        XCTAssertNil(t.autoValue("clarity"), "Auto doesn't set it")
        XCTAssertNotNil(t.whiteBalance(from: [[200, 170, 120], [190, 160, 110]]))
        XCTAssertNil(t.whiteBalance(from: []))
        XCTAssertEqual(t.bins("pointCurve").reduce(0, +), rgb.count)
        XCTAssertEqual(t.bins("pointCurveRed")[30], 3)
        XCTAssertEqual(DevelopTries.tint("pointCurveRed"), .red)
        XCTAssertEqual(DevelopTries.tint("pointCurveGreen"), .green)
        XCTAssertEqual(DevelopTries.tint("pointCurveBlue"), .blue)
        XCTAssertEqual(DevelopTries.tint("pointCurve"), .primary)
    }

    func testDevelopScreenWithEveryPanelOpen() {
        let model = picture()
        let all = Set(DevelopSettings.panels.map(\.name))
        var tries = 0
        render(CameraRawView(model: model, change: { _ in tries += 1 }, cancel: {}, done: { _ in }, expanded: all), for: 0.4)
        XCTAssertEqual(tries, 0, "nothing tried until a control changes")
        render(CameraRawView(model: model, initial: ["exposure": 0.5], opening: true, change: { _ in tries += 1 }, done: { _ in }, expanded: all), for: 0.4)
        XCTAssertEqual(tries, 1, "a file's kept settings show at once")
        model.liveCancel()
    }

    // MARK: - Crop and Rotate

    func testCropBoxTurnsRatiosAndReset() {
        var e = CropEdit(size: CGSize(width: 300, height: 200))
        XCTAssertFalse(e.changed)
        XCTAssertNil(e.ratio)
        e.setAspect(.r16x9)
        XCTAssertEqual(e.ratio ?? 0, 16.0 / 9, accuracy: 1e-9)
        XCTAssertEqual(e.frame.size.width / e.frame.size.height, 16.0 / 9, accuracy: 0.01)
        XCTAssertTrue(e.changed)
        e.lockRatio(true)
        XCTAssertEqual(e.lockedRatio ?? 0, 16.0 / 9, accuracy: 0.01)
        e.setAspect(.square)
        XCTAssertNil(e.lockedRatio)
        XCTAssertEqual(e.frame.size.width, e.frame.size.height, accuracy: 0.01)
        e.lockRatio(true)
        e.lockRatio(false)
        XCTAssertEqual(e.aspect, .freeform)
        XCTAssertNil(e.ratio)
        e.reset()
        XCTAssertFalse(e.changed)

        e.beginTurn()
        e.turn(to: 10)
        e.turnFrom = nil
        XCTAssertEqual(e.frame.angle, 10, accuracy: 1e-9)
        XCTAssertLessThan(e.frame.size.width, 300, "kept on the image, it shrinks")
        XCTAssertFalse(e.frame.addsCanvas(width: 300, height: 200))
        e.toggleKeepInside()
        XCTAssertFalse(e.keepInside)
        XCTAssertEqual(e.frame.size.width, 300, accuracy: 0.01, "let go, it grows back")
        XCTAssertTrue(e.frame.addsCanvas(width: 300, height: 200))
        e.reset()
        e.turnQuarter(clockwise: true)
        XCTAssertEqual(e.frame.size.width, 200, accuracy: 0.01)
        XCTAssertEqual(e.frame.size.height, 300, accuracy: 0.01)
        XCTAssertEqual(ThirdsGrid().path(in: CGRect(x: 0, y: 0, width: 90, height: 90)).boundingRect, CGRect(x: 0, y: 0, width: 90, height: 90))
    }

    func testCropScreenAndAIFill() {
        let model = picture(100, 100)
        render(CropRotateView(model: model), for: 0.5)
        model.inpainterOverride = GreenFill(side: 64)
        model.aiMatchColor = false
        let f = CropFrame(width: 100, height: 100).resized(.init(x: 1, y: 0), by: CGVector(dx: 50, dy: 0), scale: 1, aspect: nil)
        model.cropRotate(f, fill: .ai, image: CGSize(width: 100, height: 100))
        idle(model)
        XCTAssertEqual(model.doc?.width, 150)
        XCTAssertEqual(model.pixel(140, 80).dropFirst().first ?? 0, 1, accuracy: 0.05, "the added canvas, filled by the model")
        XCTAssertEqual(model.pixel(140, 80).first ?? 1, 0, accuracy: 0.05)
        XCTAssertEqual(model.pixel(50, 80), [1, 1, 1, 1], "the image is kept")
        XCTAssertEqual(model.doc?.hasSelection, false, "the selection it filled goes")
    }
    // MARK: - The main screen

    /// A document on screen with a picked layer that has a mask.
    private func editing() -> EditorModel {
        let model = picture(200, 150)
        model.run("layer.new.layer", ["name": "Top"])
        model.run("layer.layerMask.revealAll")
        model.showHome = false
        return model
    }

    func testMainScreenOverlaysAndPrompts() throws {
        let model = editing()
        let history = model.historyNames
        render(ContentView(model: model), for: 0.5)
        model.beginPick(.canvas, prompt: "Tap a color") { _ in }
        spin()
        model.canvasPick = nil
        model.pencilPalette = CGPoint(x: 100, y: 100)
        spin()
        model.pencilPalette = nil
        let top = try XCTUnwrap(model.row("Top")?.id)
        model.toggleMaskView(top)
        XCTAssertEqual(model.maskView, top)
        model.showSizePreview = true
        model.showTimeline = true
        spin()
        model.toggleMaskView(top)
        model.showSizePreview = false
        model.showTimeline = false
        model.rasterizePrompt = model.row("Top")
        spin()
        model.rasterizePrompt = nil
        model.aiRemoveWaiting = .selection
        spin()
        model.aiRemoveWaiting = nil
        var typed: String?
        model.prompt = TextPrompt(title: "Text", text: "Hi", multiline: true) { typed = $0 }
        spin(0.4)
        model.prompt = nil
        model.prompt = TextPrompt(title: "Name", text: "A") { typed = $0 }
        spin(0.4)
        model.prompt = nil
        spin(0.4)
        model.showAcknowledgements = true
        spin(0.4)
        model.showAcknowledgements = false
        spin(0.3)
        XCTAssertNil(typed, "closing the prompt types nothing")
        XCTAssertEqual(model.historyNames, history, "showing things isn't an edit")
    }

    func testEveryRequestIsTakenUp() {
        let requests: [EditorModel.Request] = [
            .search, .newDocument, .save, .saveAs, .saveCopy, .panel(.layers), .panel(.history), .panel(.adjustments), .panel(.actions),
            .panel(.properties), .closePanels, .cameraRaw, .newLayer, .exportAs, .saveForWeb, .generalPreferences, .defineBrush,
            .layerStyle("dropShadow"), .cropRotate, .importBrushTips, .openFiles, .placeFiles, .layerFromFiles, .close,
        ]
        for r in requests {
            let model = editing()
            render(ContentView(model: model), for: 0.2)
            model.request = r
            spin(0.4)
            XCTAssertNil(model.request, "\(r)")
            model.liveCancel()
        }
        // From a panel: it closes first, then the next screen opens.
        let model = editing()
        render(ContentView(model: model), for: 0.2)
        model.request = .panel(.layers)
        spin(0.4)
        model.request = .layerStyle("stroke")
        spin(0.8)
        model.request = .cropRotate
        spin(0.8)
        model.request = .panel(.history)
        spin(0.4)
        model.request = .cropRotate
        spin(0.8)
        XCTAssertNil(model.request)
    }

    func testSettingsScreensOnAPhoneAndBesideTheCanvas() {
        let commands = [
            info("filter.blur.gaussianBlur", "Gaussian Blur…", menu: "Filter > Blur"),
            info("image.adjustments.levels", "Levels…", menu: "Image > Adjustments"),
            info("filter.distort.shear", "Shear…", menu: "Filter > Distort"),
            info("select.refineEdge", "Refine Edge…", menu: "Select"),
            info("image.imageSize", "Image Size…", menu: "Image"),
        ]
        for wide in [false, true] {
            for c in commands {
                let model = editing()
                let view = ContentView(model: model).environment(\.horizontalSizeClass, wide ? .regular : .compact)
                render(view, for: 0.2)
                model.commandSettings = c
                spin(0.5)
                XCTAssertEqual(model.commandSettings?.id, c.id, "the screen stays up")
                model.commandSettings = nil
                spin(0.3)
                model.liveCancel()
            }
        }
        // Develop, opening a file and on a smart filter.
        let model = editing()
        render(ContentView(model: model), for: 0.2)
        model.developOpen = DevelopOpen(key: "k", initial: [:])
        spin(0.5)
        model.developOpen = nil
        spin(0.3)
        model.developEdit = DevelopEdit(layer: model.activeLayer?.id ?? 0, index: 0, initial: ["exposure": 0.2])
        spin(0.5)
        model.developEdit = nil
        spin(0.3)
        model.liveCancel()
        model.confirmClose = model.doc
        spin(0.3)
        model.confirmClose = nil
        model.showHome = true
        spin(0.3)
        XCTAssertTrue(model.showHome)
    }

    func testPickedFilesExportsAndTheSmallButtons() throws {
        let model = editing()
        let layers = model.layerCount
        model.picked(sample("star.png"), for: .layer)
        idle(model)
        XCTAssertEqual(model.layerCount, layers + 1, "a layer from the file")
        model.picked(sample("star.png"), for: .place)
        idle(model)
        XCTAssertEqual(model.layerCount, layers + 2, "placed")
        model.placeFile(URL(fileURLWithPath: "/nonexistent.png"))
        XCTAssertEqual(model.layerCount, layers + 2, "a file that can't be read adds nothing")
        let docs = model.documents.count
        model.picked(sample("star.png"), for: .open)
        wait("opened") { model.documents.count > docs && !model.busy }

        model.exported(.success(URL(fileURLWithPath: "/tmp/copy.png")), kind: .copy)
        XCTAssertEqual(model.toast, "Saved copy.png")
        model.closeAfterSave = true
        model.exported(.failure(CocoaError(.fileWriteNoPermission)), kind: .saveAs)
        XCTAssertFalse(model.closeAfterSave, "a failed save doesn't close")
        XCTAssertNotEqual(model.toast, "Saved copy.png")

        let brushes = picture()
        brushes.run("select.rect", ["x": 5, "y": 5, "width": 40, "height": 40])
        brushes.defineBrush(named: "  ")
        XCTAssert(brushes.brushGroups.flatMap(\.presets).contains("Brush"), "a blank name is Brush")

        let count = model.documents.count
        model.confirmClose = model.doc
        model.closeWithoutSaving()
        XCTAssertNil(model.confirmClose)
        XCTAssertEqual(model.documents.count, count - 1)
        model.confirmClose = model.doc
        XCTAssertFalse(model.saveBeforeClose(), "a new document needs Save As")
        XCTAssertTrue(model.closeAfterSave)
        XCTAssertNil(model.confirmClose)

        var picked: [Float]?
        let delegate = SystemColorPicker.Delegate { picked = $0 }
        delegate.colorPickerViewController(UIColorPickerViewController(), didSelect: UIColor(red: 1, green: 0.5, blue: 0, alpha: 1), continuously: false)
        XCTAssertEqual(picked, [1, 0.5, 0])
        XCTAssertEqual(DataFile(data: Data([1, 2])).data, Data([1, 2]))
        render(CanvasPickBar(prompt: "Tap a color") {})
        render(DeviceProbe(model: model), for: 0.4)
    }

    // MARK: - Canvas gestures

    private final class Pan: UIPanGestureRecognizer {
        var at = CGPoint.zero
        var moved = CGPoint.zero
        var flags: UIKeyModifierFlags = []
        override func location(in view: UIView?) -> CGPoint { at }
        override func translation(in view: UIView?) -> CGPoint { moved }
        override var modifierFlags: UIKeyModifierFlags { flags }
    }

    private final class Press: UILongPressGestureRecognizer {
        var at = CGPoint.zero
        override func location(in view: UIView?) -> CGPoint { at }
    }

    private final class Hover: UIHoverGestureRecognizer {
        var at = CGPoint.zero
        override func location(in view: UIView?) -> CGPoint { at }
    }

    private func canvas(_ model: EditorModel) -> CanvasUIView {
        let canvas = CanvasUIView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        return canvas
    }

    func testPinchTurnScrollAndPointer() {
        let model = picture(200, 200)
        let canvas = canvas(model)
        let zoom = model.view.zoom
        let pinch = UIPinchGestureRecognizer()
        pinch.scale = 2
        canvas.pinched(pinch)
        XCTAssertEqual(model.view.zoom, zoom * 2, accuracy: zoom * 0.01)
        XCTAssertEqual(pinch.scale, 1, "each step counts once")
        let turn = UIRotationGestureRecognizer()
        turn.rotation = 0.5
        canvas.rotated(turn)
        XCTAssertEqual(model.view.rotation, 0.5, accuracy: 0.001)
        let x = model.view.centerX
        let scroll = Pan()
        scroll.moved = CGPoint(x: 30, y: 0)
        canvas.scrolled(scroll)
        XCTAssertNotEqual(model.view.centerX, x, "two-finger scroll pans")
        let before = model.view.zoom
        scroll.flags = .command
        scroll.moved = CGPoint(x: 0, y: -50)
        canvas.scrolled(scroll)
        XCTAssertGreaterThan(model.view.zoom, before, "⌘-scroll zooms")

        model.tool = .brush
        let region = UIPointerRegion(rect: .zero, identifier: nil)
        XCTAssertNotNil(canvas.pointerInteraction(UIPointerInteraction(delegate: nil), styleFor: region), "the brush outline is the pointer")
        model.tool = .move
        XCTAssertNil(canvas.pointerInteraction(UIPointerInteraction(delegate: nil), styleFor: region))

        model.tool = .brush
        let hover = Hover()
        hover.at = CGPoint(x: 100, y: 100)
        hover.state = .began
        canvas.hovered(hover)
        XCTAssertEqual(canvas.cursorAt, CGPoint(x: 100, y: 100))
        XCTAssertNotNil(canvas.cursor.path)
        hover.state = .ended
        canvas.hovered(hover)
        XCTAssertNil(canvas.cursorAt)
    }

    func testPickOnTheCanvasWithAHold() {
        let model = picture(200, 200)
        let canvas = canvas(model)
        var got: CGPoint?
        model.beginPick(.canvas, prompt: "Tap a color") { got = $0 }
        let press = Press()
        press.at = canvas.toScreen(pt(50, 100))
        press.state = .began
        canvas.pickPressed(press)
        XCTAssertNil(got, "the loupe shows while it's held")
        press.state = .ended
        canvas.pickPressed(press)
        XCTAssertEqual(got?.x ?? 0, 0.25, accuracy: 0.01)
        XCTAssertEqual(got?.y ?? 0, 0.5, accuracy: 0.01)
        XCTAssertNil(model.canvasPick)
        press.state = .cancelled
        canvas.pickPressed(press)
    }

    func testDragOnTheCanvasAdjustsTheColorUnderIt() throws {
        let model = picture(200, 200)
        model.run("layer.newAdjustmentLayer.hueSaturation")
        let layer = try XCTUnwrap(model.activeLayer?.id)
        let canvas = canvas(model)
        model.targetedAdjust = TargetedAdjust(layer: layer, key: "t", hue: false)
        var pan = Pan()
        pan.at = canvas.toScreen(pt(25, 25))
        pan.state = .began
        canvas.targetedPanned(pan)
        XCTAssertEqual(model.toast, "Adjusting Reds")
        pan.at.x += 30
        pan.state = .changed
        canvas.targetedPanned(pan)
        let reds = model.layers.first { $0.id == layer }?.adjustment?.params["reds"] as? [String: Any]
        XCTAssertEqual((reds?["saturation"] as? NSNumber)?.doubleValue, 30)
        pan.state = .ended
        canvas.targetedPanned(pan)
        XCTAssertNil(canvas.targeted)

        // On white there's no colour to adjust.
        pan = Pan()
        pan.at = canvas.toScreen(pt(150, 150))
        pan.state = .began
        canvas.targetedPanned(pan)
        XCTAssertEqual(model.toast, "No color there to adjust")
        pan.state = .cancelled
        canvas.targetedPanned(pan)

        // A sheet's own drag (a shadow's offset) wins.
        model.targetedAdjust = nil
        var moves: [(Bool, Point, Point)] = []
        model.sheetDrag = SheetDrag { moves.append(($0, $1, $2)) }
        pan = Pan()
        pan.at = canvas.toScreen(pt(20, 20))
        pan.moved = .zero
        pan.state = .began
        canvas.targetedPanned(pan)
        pan.at = canvas.toScreen(pt(40, 20))
        pan.state = .changed
        canvas.targetedPanned(pan)
        XCTAssertEqual(moves.count, 2)
        XCTAssertEqual(moves.first?.0, true)
        XCTAssertNear(moves.last?.2, pt(40, 20), accuracy: 0.5)
    }

    func testACancelledStrokeLeavesNothing() {
        let model = picture(200, 200)
        model.tool = .brush
        let canvas = canvas(model)
        canvas.gesture = (1, 0, false)
        canvas.toolBegan(ToolTouch(canvas.toScreen(pt(100, 150)), time: 100), modifiers: [], alt: false)
        canvas.toolMoved(ToolTouch(canvas.toScreen(pt(150, 150)), time: 100.1), modifiers: [])
        canvas.mode = .tool
        canvas.touchesCancelled([], with: nil)
        XCTAssertEqual(canvas.mode, .idle)
        XCTAssertFalse(canvas.stroking)
        XCTAssertEqual(model.pixel(125, 150), [1, 1, 1, 1])
        canvas.mode = .tool
        canvas.dropFinishedTouches()
        XCTAssertEqual(canvas.mode, .idle, "no touches left: the gesture is over")
    }

    func testWorkInProgressIsDrawnOverTheCanvas() throws {
        let model = picture(200, 200)
        let canvas = canvas(model)
        model.tool = .crop
        model.cropRect = (pt(20, 20), pt(180, 120))
        model.cropAngle = 5
        canvas.updatePending()
        XCTAssertNotNil(canvas.shade.path, "outside the crop is shaded")
        XCTAssertFalse(canvas.pendingLines.path?.isEmpty ?? true)
        model.cropRect = nil

        model.run("layer.new.layer", ["name": "L"])
        model.run("select.rect", ["x": 50, "y": 50, "width": 50, "height": 50])
        model.run("edit.fill", ["color": "#000000"])
        model.run("select.deselect")
        model.beginTransform()
        XCTAssertNotNil(model.transform)
        canvas.updatePending()
        XCTAssertNil(canvas.shade.path)
        XCTAssertFalse(canvas.pendingDots.path?.isEmpty ?? true, "the box's handles")
        model.cancelPending()

        model.beginPuppet()
        model.puppet?.pins = [.init(src: pt(60, 60), dst: pt(70, 60), rotate: nil)]
        wait("the mesh") { !model.puppetMesh.isEmpty }
        canvas.updatePending()
        XCTAssertFalse(canvas.pendingLines.path?.isEmpty ?? true, "the mesh")
        model.cancelPending()

        model.tool = .pen
        model.workPath = [Subpath(knots: [Knot(pt(10, 10)), Knot(anchor: pt(90, 10), in: pt(80, 0), out: pt(100, 20)), Knot(pt(90, 90))], closed: true)]
        model.smartGuides = [(pt(0, 100), pt(200, 100))]
        canvas.updatePending()
        XCTAssertFalse(canvas.guideLines.path?.isEmpty ?? true)
        let lines = try XCTUnwrap(canvas.pendingLines.path).boundingBoxOfPath
        XCTAssertGreaterThan(lines.width, 0)
        model.workPath = []

        model.tool = .frame
        model.frameOutlines = [.init(rect: [10, 10, 50, 40], ellipse: false), .init(rect: [100, 100, 60, 60], ellipse: true)]
        canvas.updatePending()
        XCTAssertFalse(canvas.pendingLines.path?.isEmpty ?? true)

        model.tool = .aiRemove
        model.removeStrokes = [[pt(10, 10), pt(50, 50)]]
        canvas.updatePending()
        XCTAssertNotNil(canvas.toolPath.path, "the strokes waiting to be removed")
    }

    // MARK: - Saving and exporting

    func testSaveAndExportScreensInEachFormat() {
        let model = picture()
        for ext in ["jpg", "jxl", "psd"] {
            let format = SaveFormat.all.first { $0.ext == ext } ?? SaveFormat.all[0]
            render(SaveSheet(model: model, copy: false, elsewhere: { _, _, _ in }, format: format, jxlLossless: false))
        }
        render(SaveSheet(model: model, copy: true) { _, _, _ in })
        for (format, lossless) in [("jpg", false), ("jxl", false), ("webp", false)] {
            render(ExportSheet(model: model, format: format, jxlLossless: lossless))
        }
        for format in ["jpeg", "png8"] { render(SaveForWebSheet(model: model, format: format), for: 0.4) }
        model.run("layer.new.layer")
        model.run("layer.new.layer")
        model.createFrameAnimation()
        model.makeFramesFromLayers()
        render(SaveForWebSheet(model: model), for: 0.4)
        XCTAssertGreaterThan(model.animation?.count ?? 0, 1)
    }

    func testSaveFilesAndExportSettings() throws {
        let model = picture()
        let jpg = try XCTUnwrap(model.fileData("jpg", jpegQuality: 8, jxl: (true, 90, 7)))
        XCTAssertEqual(jpg.prefix(2), Data([0xFF, 0xD8]))
        let jxl = try XCTUnwrap(model.fileData("jxl", jpegQuality: 8, jxl: (false, 80, 3)))
        XCTAssertFalse(jxl.isEmpty)
        let name = "coverage-\(UUID().uuidString)"
        model.saveInAppFolder(jpg, file: "\(name).jpg", copy: true)
        XCTAssertEqual(model.toast, "Saved \(name).jpg")
        let url = AppFolder.url.appendingPathComponent("\(name).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        model.saveInAppFolder(jpg, file: "missing-folder/\(name).jpg", copy: false)
        XCTAssertNotEqual(model.toast, "Saved \(name).jpg", "a file that can't be written says why")

        model.saveForWeb(SaveForWebSheet.params(format: "png24", colors: 256, palette: "selective", dither: "none", transparency: true, quality: 60, percent: 50, loops: nil), file: "\(name).png")
        idle(model)
        let png = AppFolder.url.appendingPathComponent("\(name).png")
        defer { try? FileManager.default.removeItem(at: png) }
        XCTAssertEqual(model.toast, "Saved \(name).png")
        XCTAssertEqual(UIImage(contentsOfFile: png.path)?.size.width, 60)

        let jxlPrefs = ExportSheet.prefs(format: "jxl", quality: 70, jxlLossless: true, srgb: false)
        XCTAssertEqual(jxlPrefs["jxlLossless"] as? Bool, true)
        XCTAssertEqual(jxlPrefs["jxlQuality"] as? Int, 70)
        XCTAssertEqual(ExportSheet.prefs(format: "jpg", quality: 55, jxlLossless: false, srgb: true)["jpegQuality"] as? Int, 55)
        XCTAssertEqual(ExportSheet.prefs(format: "webp", quality: 40, jxlLossless: false, srgb: true)["webpQuality"] as? Int, 40)
        XCTAssertNil(ExportSheet.prefs(format: "png", quality: 40, jxlLossless: false, srgb: true)["jpegQuality"])

        XCTAssertEqual(NewDocumentSheet.preset("A4")?.width, 2480)
        XCTAssertNil(NewDocumentSheet.preset("Nope"))
        let (a, b) = (URL(fileURLWithPath: "/f/frame 10.png"), URL(fileURLWithPath: "/f/frame 2.png"))
        XCTAssertEqual(FileBrowser.inNameOrder([a, b]), [b, a], "numbers in name order")
        XCTAssertEqual(FileBrowser.toggled(a, in: [b]), [b, a])
        XCTAssertEqual(FileBrowser.toggled(b, in: [b, a]), [a])
    }

    // MARK: - Levels, Curves and their eyedroppers

    func testCurveGraphDragsAndThePencil() {
        var pts = CurvesValues.identity
        var dragging: Int?
        var selected: Int?
        let size = CGSize(width: 255, height: 255)
        CurveGraph.drag(&pts, &dragging, &selected, from: CGPoint(x: 128, y: 128), to: CGPoint(x: 128, y: 100), size: size)
        XCTAssertEqual(pts.count, 3, "a point added")
        XCTAssertEqual(selected, 1)
        XCTAssertEqual(pts[1].y, 155, accuracy: 0.5)
        CurveGraph.drag(&pts, &dragging, &selected, from: CGPoint(x: 128, y: 128), to: CGPoint(x: 128, y: 400), size: size)
        XCTAssertEqual(pts.count, 2, "dragged off the graph, it goes")
        XCTAssertNil(selected)
        CurveGraph.drag(&pts, &dragging, &selected, from: CGPoint(x: 0, y: 255), to: CGPoint(x: 20, y: 255), size: size)
        XCTAssertEqual(dragging, 0, "the black point")
        XCTAssertEqual(pts[0].x, 20, accuracy: 0.5)
        let line = CurveGraph.draw((0..<256).map(Double.init), from: CGPoint(x: 10, y: 200), to: CGPoint(x: 20, y: 100))
        XCTAssertEqual(line?[15] ?? 0, 150, accuracy: 0.01)
        XCTAssertEqual(line?[30], 30, "the rest stays")
        XCTAssertNil(CurveGraph.draw([0, 1], from: .zero, to: .zero))

        var ends: [String] = []
        let surface = TouchSurface(changed: { a, b in ends.append("\(a.x),\(b.x)") }, ended: { ends.append("end") })
        let coordinator = surface.makeCoordinator()
        let press = Press()
        press.at = CGPoint(x: 5, y: 5)
        press.state = .began
        coordinator.pressed(press)
        press.at = CGPoint(x: 9, y: 5)
        press.state = .changed
        coordinator.pressed(press)
        press.state = .ended
        coordinator.pressed(press)
        XCTAssertEqual(ends, ["5.0,5.0", "5.0,9.0", "end"])
    }

    func testLevelsHandlesAndEyedroppers() throws {
        var c = LevelsValues.Channel()
        var handle: Int?
        c.dragInput(&handle, from: 2, to: 30)
        XCTAssertEqual(handle, 0)
        XCTAssertEqual(c.inBlack, 30)
        handle = nil
        c.dragInput(&handle, from: 250, to: 10)
        XCTAssertEqual(c.inWhite, 32, "white stays above black")
        handle = nil
        c = LevelsValues.Channel()
        c.dragInput(&handle, from: 128, to: 64)
        XCTAssertEqual(handle, 1)
        XCTAssertGreaterThan(c.gamma, 1, "the midtone moved left: lighter")
        handle = nil
        c.dragOutput(&handle, from: 240, to: 200)
        XCTAssertEqual(handle, 1)
        XCTAssertEqual(c.outWhite, 200)
        handle = nil
        c.dragOutput(&handle, from: 10, to: -20)
        XCTAssertEqual(c.outBlack, 0)

        let model = picture()
        var picked: CGPoint?
        let now = model.toggleEyedropper("black", picking: nil, surface: .preview, prompt: "") { picked = $0 }
        XCTAssertEqual(now, "black")
        model.previewTap?(CGPoint(x: 0.1, y: 0.1))
        XCTAssertNotNil(picked)
        XCTAssertNil(model.toggleEyedropper("black", picking: now, surface: .preview, prompt: "") { _ in })
        XCTAssertNil(model.previewTap)

        let sampler = PreviewSampler(model, layer: nil)
        XCTAssertEqual(sampler.color(at: CGPoint(x: 0.2, y: 0.3))?.first ?? 0, 0.816, accuracy: 0.02, "the red square")
        let d = try XCTUnwrap(model.doc)
        XCTAssertEqual(PreviewSampler.docPoint(CGPoint(x: 1, y: 1), d), [119, 79], "kept on the image")
        let out = sampler.adjust("levels", [:], "white", at: CGPoint(x: 0.2, y: 0.3), model: model)
        XCTAssertNotNil(out, "the white point set on the red")
        model.run("layer.newAdjustmentLayer.levels")
        let layer = try XCTUnwrap(model.activeLayer?.id)
        XCTAssertNotNil(PreviewSampler(model, layer: layer).adjust("levels", [:], "black", at: CGPoint(x: 0.2, y: 0.3), model: model))

        let q = ReplaceColorEditor.sampled(["points": [[1, 1]]], mode: "add", at: [5, 5], color: [1, 0, 0])
        XCTAssertEqual(q["points"] as? [[Int]], [[1, 1], [5, 5]])
        XCTAssertNil(q["color"])
        let r = ReplaceColorEditor.sampled(["points": [[1, 1]]], mode: "pick", at: [5, 5], color: [1, 0, 0])
        XCTAssertEqual(r["points"] as? [[Int]], [[5, 5]])
        XCTAssertEqual(r["color"] as? String, "#ff0000")

        let stops: [[Any]] = [[0.0, "#000000"], [1.0, "#ffffff"]]
        XCTAssertNil(GradientStopsSections.removing([0], from: stops), "two stops at least")
        let three = GradientStopsSections.addingStop(to: stops)
        XCTAssertEqual(three.map { $0.first as? Double }, [0, 0.5, 1])
        XCTAssertEqual(GradientStopsSections.removing([1], from: three)?.count, 2)
    }

    // MARK: - The model's less used paths

    func testSavingBackIntoAnEmbeddedLayerAndFailedSaves() throws {
        let model = picture()
        model.run("layer.smartObjects.convertToSmartObject")
        let layer = try XCTUnwrap(model.activeLayer?.id)
        let docs = model.documents.count
        model.runInBackground("layer.smartObjects.editContents", ["layer": layer])
        idle(model)
        XCTAssertEqual(model.documents.count, docs + 1)
        model.run("edit.fill", ["color": "#00ff00"])
        XCTAssertTrue(model.save(), "the contents save into the layer")
        idle(model)
        XCTAssertEqual(model.toast, "Saved the embedded layer's contents")

        let other = picture()
        other.savedAs(URL(fileURLWithPath: "/nonexistent-folder/x.png"))
        XCTAssertFalse(other.save(), "a file that can't be written: Save As")
        other.importBrushTips(sample("star.png"))
        XCTAssertNotNil(other.toast)
        let filters = try XCTUnwrap(other.activeLayer?.id)
        other.toggleFilters(filters)
        XCTAssert(other.collapsedFilters.contains(filters))
        other.toggleFilters(filters)
        XCTAssertFalse(other.collapsedFilters.contains(filters))
    }

    func testQuickExportCanvasColourAndLayerMoves() throws {
        let model = picture()
        let name = "coverage-\(UUID().uuidString)"
        model.quickExport(name: name, prefs: ["quickExportFormat": "png"])
        idle(model)
        let url = AppFolder.url.appendingPathComponent("\(name).png")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(model.toast, "Exported \(name).png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let (was, rgb) = (model.canvasColor, CanvasColor.customRGB)
        defer { model.canvasColor = was; CanvasColor.customRGB = rgb }
        model.canvasColor = .custom
        model.setCustomCanvas([0.1, 0.2, 0.3])
        XCTAssertEqual(CanvasColor.customRGB, [0.1, 0.2, 0.3])
        XCTAssertEqual(model.canvasColor, .custom)

        let layers = makeModel()
        layers.newDocument(["width": 50, "height": 50, "background": "transparent"])
        layers.run("layer.new.layer", ["name": "A"])
        layers.run("layer.new.layer", ["name": "B"])
        let bottom = layers.layers.last?.name
        layers.moveLayer(from: 0, to: layers.layers.count)
        XCTAssertEqual(layers.layers.map(\.name), ["A", bottom ?? "", "B"], "to the bottom")
    }

    func testCropEdgesPatchRedEyeAndArtboard() throws {
        let model = picture(200, 200)
        let canvas = canvas(model)
        model.tool = .crop
        let edges: [(Point, Point, (Float, Float, Float, Float))] = [
            (pt(100, 20), pt(100, 40), (20, 40, 180, 180)), (pt(100, 180), pt(100, 160), (20, 20, 180, 160)),
            (pt(20, 100), pt(40, 100), (40, 20, 180, 180)), (pt(180, 100), pt(160, 100), (20, 20, 160, 180)),
        ]
        for (from, to, want) in edges {
            model.cropRect = (pt(20, 20), pt(180, 180))
            canvas.drag(from, to)
            let (a, b) = try XCTUnwrap(model.cropRect)
            let got = (min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
            XCTAssert(abs(got.0 - want.0) <= 1 && abs(got.1 - want.1) <= 1 && abs(got.2 - want.2) <= 1 && abs(got.3 - want.3) <= 1, "\(from): \(got)")
        }
        model.cropRect = nil

        model.tool = .redEye
        canvas.tap(pt(25, 25))
        XCTAssertEqual(model.historyNames.last, "Red Eye")

        model.tool = .patch
        model.run("select.rect", ["x": 10, "y": 10, "width": 30, "height": 30])
        canvas.drag(pt(25, 25), pt(125, 145))
        idle(model)
        XCTAssertGreaterThan(model.pixel(25, 25).dropFirst().first ?? 0, 0.5, "the red patched from the white below")
        model.run("select.deselect")

        model.tool = .artboard
        let layers = model.layerCount
        canvas.drag(pt(10, 10), pt(100, 100))
        XCTAssertEqual(model.layerCount, layers + 1, "an artboard")
    }

    // MARK: - Test probe, settings OK, objects

    func testTheUITestProbeAnswers() throws {
        let model = picture()
        let at = try XCTUnwrap(TestProbe.answer("app.docToCanvas", ["x": 60.0, "y": 40.0], model: model) as? [String: Double])
        XCTAssertNotNil(at["x"])
        let docs = try XCTUnwrap(TestProbe.answer("app.documents", [:], model: model) as? [String: Any])
        XCTAssertEqual(docs["names"] as? [String], model.documents.map(\.name))
        XCTAssertEqual((TestProbe.answer("app.objectHighlight", [:], model: model) as? [String: Any])?["shown"] as? Bool, false)
        XCTAssertNotNil((TestProbe.answer("app.toasts", [:], model: model) as? [String: Any])?["toasts"])
        let state = try XCTUnwrap(TestProbe.answer("app.state", [:], model: model) as? [String: Any])
        XCTAssertEqual(state["documents"] as? Int, 1)
        XCTAssertFalse(((TestProbe.answer("app.menuTree", [:], model: model) as? [String: Any])?["items"] as? [Any] ?? []).isEmpty)
        XCTAssertFalse(((TestProbe.answer("app.tools", [:], model: model) as? [String: Any])?["groups"] as? [Any] ?? []).isEmpty)
        let stats = try XCTUnwrap(TestProbe.answer("document.stats", ["of": "composite"], model: model) as? [String: Any])
        XCTAssertNotNil(stats["mean"])
        XCTAssertNotNil((TestProbe.answer("layer.layerStyle.get", ["layer": 987_654], model: model) as? [String: Any])?["error"], "a bad query says so")
        XCTAssertNotNil((TestProbe.answer("edit.fill", [:], model: model) as? [String: Any])?["error"], "only queries")
        XCTAssertEqual(model.historyNames.last, "Deselect", "nothing changed")
        model.run("layer.new.layer")
        XCTAssertEqual((TestProbe.answer("app.reset", [:], model: model) as? [String: Bool])?["ok"], true)
        XCTAssertEqual(model.documents.map(\.name), ["Omega"], "the same document before each try")
        XCTAssertEqual(model.layerCount, 2)
        XCTAssertEqual(UTType.psd.preferredFilenameExtension, "psd")
        XCTAssertEqual(UTType.pcraft.preferredFilenameExtension, "pcraft")
        XCTAssertEqual(DataFile.readableContentTypes, [.data])
    }

    func testSettingsOKRunsOrKeepsTheTry() {
        let model = picture()
        model.commandSettings = info("filter.blur.gaussianBlur")
        model.settingsDone("filter.blur.gaussianBlur", ["radius": 3], live: false)
        idle(model)
        XCTAssertNil(model.commandSettings)
        XCTAssertEqual(model.historyNames.last, "Gaussian Blur")
        model.liveBegin()
        model.live("filter.noise.addNoise", ["amount": 20])
        idle(model)
        model.settingsDone("filter.noise.addNoise", ["amount": 20], live: true)
        idle(model)
        XCTAssertEqual(model.historyNames.last, "Add Noise")
        XCTAssertEqual(model.historyNames.filter { $0 == "Add Noise" }.count, 1, "the try is kept, not run again")
    }

    func testObjectHighlightAndHoverWithoutVision() throws {
        let model = makeModel()
        model.objects = ObjectTests.NoObjects()
        open("subject.jpg", in: model)
        model.canvasResized(width: 1200, height: 1200, scale: 3)
        let d = try XCTUnwrap(model.doc)
        model.tool = .objectSelect
        model.holdObject(at: pt(Float(d.width) / 2, Float(d.height) / 2))
        idle(model)
        XCTAssertNotNil(model.objectHighlight)
        let canvas = canvas(model)
        canvas.updateObjectHighlight()
        XCTAssertNotNil(canvas.objectLayer.contents, "the object, tinted on the canvas")
        model.tool = .move
        canvas.updateObjectHighlight()
        XCTAssertNil(canvas.objectLayer.contents)

        model.tool = .objectSelect
        model.showAllObjects = true
        spin(0.3)
        model.showObjects(at: pt(10, 10))
        spin(0.3)
        model.showObjects(at: pt(20, 10))
        XCTAssertNil(model.objectHighlight, "Vision found nothing to show")
        model.showAllObjects = false
    }

    func testCropDoneSymmetryAndThePencil() {
        let model = picture(100, 100)
        var edit = CropEdit(size: CGSize(width: 100, height: 100))
        model.cropRotate(edit, fill: .transparent, color: nil)
        XCTAssertEqual(model.historyNames.last, "Deselect", "an unchanged box does nothing")
        edit.setAspect(.r16x9)
        model.cropRotate(edit, fill: .transparent, color: nil)
        idle(model)
        XCTAssertEqual(Double(model.doc?.height ?? 0), 56, accuracy: 1)
        XCTAssertEqual(model.layers.count, 1, "nothing added: the Background stays")
        let f = CropFrame(width: 100, height: 100).resized(.init(x: 0, y: 1), by: CGVector(dx: 0, dy: 50), scale: 1, aspect: 2)
        XCTAssertEqual(f.size, CGSize(width: 300, height: 150), "an edge with a ratio grows both ways")
        XCTAssertEqual(CropAspect.square.id, "square")
        XCTAssertEqual(CropFill.ai.id, "ai")

        var tries = DevelopTries()
        tries.load([:], pixels: AutoPixels(rgb: []))
        XCTAssertNil(tries.whiteBalance(at: CGPoint(x: 0.5, y: 0.5), in: PreviewSampler()), "no image to pick from")
        XCTAssertNotNil(tries.whiteBalance(at: CGPoint(x: 0.9, y: 0.9), in: PreviewSampler(model, layer: nil)))

        model.setSymmetry("vertical")
        let canvas = canvas(model)
        model.tool = .brush
        canvas.updateSymmetry()
        XCTAssertNotNil(canvas.symmetryGuide.path)
        model.tool = .move
        canvas.updateSymmetry()
        XCTAssertNil(canvas.symmetryGuide.path, "shown only with a brush")
        canvas.pencilInteractionDidTap(UIPencilInteraction())
        XCTAssertEqual(model.tool, .move, "iPadOS 17.5 and later tap through the newer call")
    }

}

/// Fills every hole green.
private struct GreenFill: Inpainter {
    let side: Int
    func fill(image: Data, mask: Data) throws -> Data { Data((0..<side * side).flatMap { _ in [UInt8(0), 255, 0] }) }
}
