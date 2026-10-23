import XCTest
@testable import PhotoWagon

/// What a drag or tap does with each kind of tool, through the canvas's gesture code.
@MainActor
final class ToolTests: XCTestCase {
    private func canvas(_ w: Int = 400, _ h: Int = 400, tool: Tool) -> (EditorModel, CanvasUIView) {
        let model = makeModel(width: w, height: h)
        model.tool = tool
        let canvas = CanvasUIView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        return (model, canvas)
    }

    private func selection(_ model: EditorModel) -> [Int]? {
        (model.inspect["selectionBounds"] as? [NSNumber])?.map(\.intValue)
    }

    func testMarqueesSelectAndATapDeselects() {
        let (model, canvas) = canvas(tool: .marquee)
        canvas.drag(pt(100, 100), pt(200, 150))
        XCTAssertEqual(selection(model), [100, 100, 100, 50])
        canvas.tap(pt(300, 300))
        canvas.drag(pt(100, 100), pt(200, 150), modifiers: .shift)
        XCTAssertEqual(selection(model), [100, 100, 100, 100], "⇧: a square")
        canvas.tap(pt(300, 300))
        XCTAssertEqual(model.doc?.hasSelection, false, "a tap deselects")

        model.tool = .ellipse
        model.view.rotation = 0.3
        canvas.drag(pt(100, 100), pt(200, 200))
        XCTAssertEqual(model.doc?.hasSelection, true, "a tilted view selects the tilted shape")
        model.view.rotation = 0

        model.tool = .singleRow
        canvas.tap(pt(50, 120))
        XCTAssertEqual(selection(model), [0, 120, 400, 1])
        model.tool = .singleColumn
        model.selectionMode = .add
        canvas.tap(pt(30, 50))
        XCTAssertEqual(selection(model), [0, 0, 400, 400], "added to the row")
    }

    func testLassoAndMagicWand() {
        // LayersTests: Magic Wand, a tolerance, tap the white; Delete leaves the bee.
        let (model, canvas) = canvas(tool: .lasso)
        canvas.drag(pt(100, 100), pt(200, 200), steps: 6)
        XCTAssertEqual(model.doc?.hasSelection, false, "a straight line isn't a shape")
        model.run("select.all")
        canvas.tap(pt(10, 10))
        XCTAssertEqual(model.doc?.hasSelection, false, "a tap deselects")

        model.run("layer.new.layer")
        model.run("select.rect", ["x": 0, "y": 0, "width": 200, "height": 400])
        model.setForeground(.black)
        model.run("edit.fill")
        model.run("select.deselect")
        model.tool = .magicWand
        model.sampleAllLayers = true
        canvas.tap(pt(300, 100))
        let white = selection(model) ?? []
        XCTAssertTrue(white.first.map { (199...200).contains($0) } == true && white.last == 400, "the white half: \(white)")
        model.tool = .paintBucket
        model.setForeground(UIColor(red: 1, green: 0, blue: 0, alpha: 1))
        model.run("select.deselect")
        canvas.tap(pt(50, 50))
        XCTAssertEqual(model.pixel(50, 50), [1, 0, 0, 1])
        XCTAssertEqual(model.pixel(300, 50), [1, 1, 1, 1])
        model.tool = .magicEraser
        canvas.tap(pt(50, 50))
        XCTAssertEqual(model.pixel(50, 50), [1, 1, 1, 1], "erased down to the white Background")
    }

    func testBrushPaintsAndTheEraserOnTheBackgroundPaintsTheBackgroundColour() {
        // LayersTests: the Eraser on the locked Background paints the background colour.
        let (model, canvas) = canvas(tool: .brush)
        model.setForeground(UIColor(red: 0, green: 0, blue: 1, alpha: 1))
        model.setBrush("size", 30)
        model.setBrush("hardness", 1)
        canvas.drag(pt(50, 200), pt(350, 200), steps: 10)
        XCTAssertEqual(model.pixel(200, 200), [0, 0, 1, 1])
        model.run("tools.setColors", ["background": "#ff0000"])
        model.tool = .eraser
        canvas.drag(pt(50, 200), pt(350, 200), steps: 10)
        XCTAssertEqual(model.pixel(200, 200), [1, 0, 0, 1])
        model.tool = .spotHeal
        canvas.drag(pt(100, 100), pt(120, 100))
        idle(model)
        XCTAssertEqual(model.historyNames.last, "Spot Repair Brush")
    }

    func testHoldOrOptionSamplesAColourOrSetsTheCloneSource() {
        let (model, canvas) = canvas(tool: .brush)
        model.run("select.rect", ["x": 0, "y": 0, "width": 100, "height": 100])
        model.run("tools.setColors", ["foreground": "#00ff00"])
        model.run("edit.fill")
        model.run("select.deselect")
        model.setForeground(.black)
        canvas.mode = .tool
        canvas.tap(pt(50, 50), alt: true)
        XCTAssertEqual(model.foreground.hex, "#00ff00", "⌥-click samples")
        XCTAssertEqual(canvas.mode, .idle)
        model.tool = .clone
        canvas.mode = .tool
        canvas.tap(pt(50, 50), alt: true)
        XCTAssertEqual(model.toast, "Clone source set")
        model.tool = .eyedropper
        model.setForeground(.black)
        canvas.drag(pt(300, 300), pt(50, 50))
        XCTAssertEqual(model.foreground.hex, "#00ff00", "the Eyedropper follows the finger")
    }

    func testGradientShapesAndLine() throws {
        let (model, canvas) = canvas(tool: .gradient)
        model.setForeground(.black)
        canvas.drag(pt(0, 200), pt(400, 200))
        XCTAssertLessThan(model.pixel(20, 200)[safe: 0] ?? 1, 0.2)
        XCTAssertGreaterThan(model.pixel(380, 200)[safe: 0] ?? 0, 0.8)
        let steps = model.historyNames.count
        canvas.tap(pt(10, 10))
        XCTAssertEqual(model.historyNames.count, steps, "a tap draws no gradient")

        for (tool, kind) in [(Tool.rectangle, "Shape"), (.ellipseShape, "Shape"), (.triangle, "Shape"), (.polygon, "Shape"), (.customShape, "Shape"), (.line, "Shape")] {
            model.tool = tool
            canvas.drag(pt(100, 100), pt(200, 180))
            XCTAssertEqual(model.activeLayer?.kind, kind, "\(tool)")
        }
        XCTAssertEqual(model.layerCount, 7)
        model.tool = .rectangle
        canvas.tap(pt(5, 5))
        XCTAssertEqual(model.layerCount, 7, "a tap makes no shape")
    }

    func testTypeToolAsksForTextThenEditsIt() throws {
        // GettingStartedTests: tap, type; double-tap the T to edit it.
        let (model, canvas) = canvas(tool: .type)
        model.typeSize = 40
        canvas.tap(pt(50, 200))
        let prompt = try XCTUnwrap(model.prompt)
        XCTAssertEqual(prompt.title, "Text")
        prompt.done("")
        XCTAssertEqual(model.layerCount, 1, "nothing typed: no layer")
        prompt.done("Hello")
        XCTAssertEqual(model.activeLayer?.kind, "Type")
        XCTAssertEqual(model.activeLayer?.name, "Hello")

        canvas.tap(pt(60, 190))
        let edit = try XCTUnwrap(model.prompt)
        XCTAssertEqual(edit.title, "Edit Text", "a tap on type edits it")
        XCTAssertEqual(edit.text, "Hello")
        edit.done("Match")
        let id = try XCTUnwrap(model.activeLayer?.id)
        XCTAssertEqual((model.query("type.info", ["layer": id]) as? [String: Any])?["text"] as? String, "Match")
        model.loadTypeOptions(layer: id)
        XCTAssertEqual(model.typeSize, 40)

        // A box drag: paragraph text; the mask tool makes a selection instead of a layer.
        model.tool = .typeMask
        canvas.drag(pt(100, 250), pt(300, 350))
        XCTAssertEqual(model.prompt?.title, "Type Mask")
        model.prompt?.done("Hi")
        XCTAssertEqual(model.doc?.hasSelection, true)
        XCTAssertEqual(model.layerCount, 2)
    }

    func testZoomHandAndRotateViewTools() {
        // GettingStartedTests: scrubby zoom right and left, Hand, Rotate View.
        let (model, canvas) = canvas(tool: .zoomIn)
        let fit = model.view.zoom
        canvas.drag(pt(200, 200), pt(300, 200))
        XCTAssertGreaterThan(model.view.zoom, fit, "scrubby zoom: right zooms in")
        canvas.drag(pt(300, 200), pt(100, 200))
        XCTAssertLessThan(model.view.zoom, fit, "left zooms out")
        model.fit()
        canvas.tap(pt(200, 200))
        XCTAssertEqual(model.view.zoom, fit * 2, accuracy: 0.001, "a tap doubles")
        model.scrubbyZoom = false
        model.fit()
        canvas.drag(pt(100, 100), pt(200, 200))
        XCTAssertEqual(model.view.zoom, 12, accuracy: 0.01, "zoom to the dragged area")
        XCTAssertEqual(model.view.centerX, 150, accuracy: 0.5)
        model.fit()
        canvas.tap(pt(200, 200), alt: true)
        XCTAssertEqual(model.view.zoom, fit / 2, accuracy: 0.001, "⌥ zooms out")
        model.tool = .zoomOut
        model.fit()
        canvas.tap(pt(200, 200))
        XCTAssertEqual(model.view.zoom, fit / 2, accuracy: 0.001)

        model.tool = .hand
        model.fit()
        let x = model.view.centerX
        canvas.drag(pt(200, 200), pt(150, 200))
        XCTAssertEqual(model.view.centerX, x + 50, accuracy: 0.5, "the image follows the finger")

        model.tool = .rotateView
        model.fit()
        canvas.drag(pt(300, 200), pt(200, 300))
        XCTAssertEqual(model.view.rotation, .pi / 2, accuracy: 0.001, "in 5° steps")
    }

    func testMarkersSlicesFramesAndNotes() throws {
        let (model, canvas) = canvas(tool: .colorSampler)
        canvas.tap(pt(10, 10))
        XCTAssertEqual(model.samplers.count, 1)
        XCTAssertEqual(model.toast, "#1: R 255 G 255 B 255")
        model.tool = .count
        canvas.tap(pt(20, 20))
        canvas.tap(pt(40, 20))
        XCTAssertEqual(model.countMarks.count, 2)
        XCTAssertEqual(model.toast, "Count: 2")
        model.tool = .ruler
        canvas.drag(pt(0, 0), pt(30, 40))
        XCTAssertNear(model.ruler?.1, pt(30, 40))
        model.tool = .slice
        canvas.drag(pt(100, 100), pt(200, 200))
        XCTAssertEqual(canvas.sliceRects.count, 1)
        model.tool = .sliceSelect
        canvas.tap(pt(150, 150))
        XCTAssertNotNil(model.toast)
        model.tool = .frame
        canvas.drag(pt(50, 250), pt(150, 350))
        XCTAssertEqual(model.activeLayer?.isGroup, true, "a frame is a clipped group")
        model.tool = .note
        canvas.tap(pt(300, 300))
        model.prompt?.done("check this")
        XCTAssertEqual((model.inspect["notes"] as? [Any])?.count, 1)
        // Switching tools drops a half-measured ruler and Return/Esc state.
        model.tool = .move
        XCTAssertNil(model.ruler)
    }

    func testPenToolsDrawAndEditTheWorkPath() throws {
        let (model, canvas) = canvas(tool: .pen)
        canvas.tap(pt(100, 100))
        canvas.drag(pt(200, 100), pt(250, 150))
        canvas.tap(pt(200, 200))
        XCTAssertEqual(model.workPath.first?.knots.count, 3)
        XCTAssertNear(model.workPath.first?.knots[safe: 1]?.outHandle, pt(250, 150), "dragging pulls out handles")
        canvas.tap(pt(101, 101))
        XCTAssertEqual(model.workPath.first?.closed, true, "touching the first anchor closes it")
        model.loadWorkPath()
        XCTAssertEqual(model.workPath.first?.knots.count, 3, "written to the engine")

        model.tool = .directSelect
        canvas.drag(pt(200, 200), pt(220, 220))
        XCTAssertNear(model.workPath.first?.knots[safe: 2]?.anchor, pt(220, 220))
        model.tool = .pathSelect
        canvas.drag(pt(150, 150), pt(160, 150))
        XCTAssertNear(model.workPath.first?.knots[safe: 0]?.anchor, pt(110, 100), "the whole path moves")
        model.tool = .deleteAnchor
        canvas.tap(pt(230, 220))
        XCTAssertEqual(model.workPath.first?.knots.count, 2)
        model.tool = .addAnchor
        canvas.tap(pt(178, 119))
        XCTAssertEqual(model.workPath.first?.knots.count, 3)
        model.tool = .convertPoint
        let k = try XCTUnwrap(model.workPath.first?.knots.first)
        canvas.tap(k.anchor)
        XCTAssertNotEqual(model.workPath.first?.knots.first.map { $0.outHandle == $0.anchor }, k.outHandle == k.anchor, "corner ↔ smooth")

        model.setWorkPath([])
        model.tool = .curvaturePen
        for p in [pt(50, 300), pt(150, 250), pt(250, 300)] { canvas.tap(p) }
        XCTAssertEqual(model.workPath.first?.knots.count, 3)
        XCTAssertNotEqual(model.workPath.first?.knots[safe: 1]?.inHandle, model.workPath.first?.knots[safe: 1]?.anchor, "a smooth curve through them")
        model.tool = .freeformPen
        canvas.drag(pt(50, 50), pt(350, 80), steps: 12)
        XCTAssertEqual(model.workPath.count, 2)
    }

    func testSelectionToolsAndObjectSelectionFallBackToTheEngine() {
        let (model, canvas) = canvas(tool: .objectSelect)
        model.objectFinder = false
        canvas.drag(pt(10, 10), pt(390, 390))
        idle(model)
        XCTAssertEqual(model.toast, "No object found there. Drag a box around it.", "a plain white image has no object")
        model.tool = .magneticLasso
        canvas.drag(pt(100, 100), pt(300, 300), steps: 3)
        idle(model)
        model.tool = .quickSelect
        canvas.drag(pt(100, 100), pt(300, 300), steps: 6)
        idle(model)
        XCTAssertEqual(model.doc?.hasSelection, true)
    }
    func testEachToolStrokesWithItsOwnSettings() throws {
        let model = makeModel(width: 100, height: 100)
        model.setBrush("size", 25)
        model.setBrush("opacity", 0.5)
        model.setBrush("hardness", 0.4)
        func params(_ t: Tool) -> [String: Any] {
            model.tool = t
            return model.strokeParams()?.1 ?? [:]
        }
        XCTAssertNil({ model.tool = .move; return model.strokeParams() }(), "the Move tool doesn't stroke")
        XCTAssertEqual(params(.brush)["opacity"] as? Double, 0.5)
        XCTAssertNotNil(params(.brush)["zoom"], "the brush spaces its dabs for the zoom")
        XCTAssertEqual(params(.eraser)["erase"] as? Bool, true)
        XCTAssertNil(params(.pencil)["hardness"], "a pencil has no hardness")
        XCTAssertEqual(params(.spotHeal)["hardness"] as? Double ?? -1, 40, accuracy: 0.001, "retouching takes percent")
        XCTAssertEqual(params(.dodge)["opacity"] as? Double ?? -1, 50, accuracy: 0.001)
        model.selectionMode = .subtract
        XCTAssertEqual(params(.quickSelect)["mode"] as? String, "subtract")
        model.selectionMode = .replace
        XCTAssertEqual(params(.quickSelect)["mode"] as? String, "add", "Quick Selection adds unless subtracting")
        XCTAssertEqual(model.strokeParams()?.0, "select.quick")
    }
}
