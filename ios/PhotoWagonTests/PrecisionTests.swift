import XCTest
@testable import PhotoWagon

/// The loupe, the marquee's adjustable box, movable points and the bigger reach for fingers.
@MainActor
final class PrecisionTests: XCTestCase {
    private func canvas(tool: Tool) -> (EditorModel, CanvasUIView) {
        let model = makeModel(width: 400, height: 400)
        model.tool = tool
        let canvas = CanvasUIView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        return (model, canvas)
    }

    private func selection(_ model: EditorModel) -> [Int]? {
        (model.inspect["selectionBounds"] as? [NSNumber])?.map(\.intValue)
    }

    func testTheLoupeSitsAboveLeftAndFlipsToStayOnScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let f = Loupe.frame(finger: CGPoint(x: 300, y: 400), in: bounds)
        XCTAssertEqual(f.size, CGSize(width: Loupe.size, height: Loupe.size))
        XCTAssertTrue(f.maxX < 300 && f.maxY < 400, "above and left of the finger: \(f)")
        let corner = Loupe.frame(finger: CGPoint(x: 10, y: 10), in: bounds)
        XCTAssertEqual(corner.origin, CGPoint(x: 30, y: 50), "below and right near the top left")
        XCTAssertTrue(bounds.contains(Loupe.frame(finger: CGPoint(x: 395, y: 795), in: bounds)))
        XCTAssertNil(Loupe.image(Data(count: 3), width: 1, height: 1), "too few bytes")
        XCTAssertEqual(Loupe.pixel(pt(-0.5, 10.9)).x, -1)
    }

    func testTheLoupeFollowsAFingerAndFetchesOnlyOnANewPixel() {
        let (model, canvas) = canvas(tool: .eyedropper)
        canvas.gesture = (1, 0, false)
        canvas.toolBegan(ToolTouch(canvas.toScreen(pt(100.2, 100.2))))
        XCTAssertFalse(canvas.loupe.isHidden)
        XCTAssertEqual(canvas.loupe.label.text, "100, 100")
        XCTAssertNotNil(canvas.loupe.pixels.contents)
        canvas.toolMoved(ToolTouch(canvas.toScreen(pt(100.6, 100.6))))
        XCTAssertEqual(canvas.loupeFetches, 1, "the same pixel")
        canvas.toolMoved(ToolTouch(canvas.toScreen(pt(120, 100))))
        XCTAssertEqual(canvas.loupeFetches, 2)
        XCTAssertEqual(canvas.loupe.label.text, "120, 100")
        canvas.toolEnded(ToolTouch(canvas.toScreen(pt(120, 100))))
        XCTAssertFalse(canvas.loupe.isHidden, "it stays a moment to show where the point went")
        wait("the loupe goes") { canvas.loupe.isHidden }

        var pencil = ToolTouch(canvas.toScreen(pt(50, 50)))
        pencil.direct = false
        canvas.toolBegan(pencil)
        XCTAssertTrue(canvas.loupe.isHidden, "a Pencil or mouse is precise already")
        canvas.toolCancelled()
        model.tool = .brush
        canvas.toolBegan(ToolTouch(canvas.toScreen(pt(50, 50))))
        XCTAssertTrue(canvas.loupe.isHidden, "not for painting")
        canvas.toolCancelled()
    }

    func testTheMarqueeBoxAdjustsTheSelectionWithoutNewSteps() throws {
        let (model, canvas) = canvas(tool: .marquee)
        canvas.drag(pt(100, 100), pt(200, 150))
        XCTAssertEqual(model.marqueeBox?.rect, [100, 100, 100, 50])
        let steps = model.historyNames
        // Bottom right corner, then the inside, then the right edge.
        canvas.drag(pt(200, 150), pt(250, 200))
        XCTAssertEqual(selection(model), [100, 100, 150, 100])
        canvas.drag(pt(150, 150), pt(160, 160))
        XCTAssertEqual(selection(model), [110, 110, 150, 100])
        canvas.drag(pt(260, 160), pt(240, 160))
        XCTAssertEqual(selection(model), [110, 110, 130, 100])
        model.setMarquee(\.x, 0)
        model.setMarquee(\.h, 0)
        XCTAssertEqual(selection(model), [0, 110, 130, 1], "typed; at least a pixel")
        XCTAssertEqual(model.historyNames, steps, "adjusting replaces the marquee's own step")

        model.run("edit.undo")
        XCTAssertNil(model.marqueeBox, "another history change ends the box")
        model.run("edit.redo")
        model.tool = .ellipse
        canvas.drag(pt(100, 100), pt(200, 200))
        XCTAssertEqual(model.marqueeBox?.ellipse, true)
        canvas.drag(pt(200, 200), pt(300, 300))
        XCTAssertEqual(model.marqueeBox?.ellipse, true, "still an ellipse")
        XCTAssertEqual(selection(model), [100, 100, 200, 200])
        canvas.tap(pt(380, 20))
        XCTAssertNil(model.marqueeBox, "a tap elsewhere")
        canvas.drag(pt(100, 100), pt(200, 200))
        model.tool = .lasso
        XCTAssertNil(model.marqueeBox, "another tool")
    }

    func testPolygonPointsShowWhereTheyGoAndMove() {
        let (model, canvas) = canvas(tool: .polygonLasso)
        for p in [pt(100, 100), pt(300, 100), pt(200, 300)] { canvas.tap(p) }
        canvas.gesture = (1, 0, false)
        canvas.toolBegan(ToolTouch(canvas.toScreen(pt(50, 350))))
        XCTAssertNotNil(canvas.toolPath.path, "the candidate point and its line")
        XCTAssertFalse(canvas.loupe.isHidden)
        canvas.toolCancelled()
        canvas.drag(pt(305, 102), pt(320, 150))
        XCTAssertEqual(model.quad.count, 3, "dragging a point moves it")
        XCTAssertNear(model.quad[safe: 1], pt(320, 150))
        model.undoLastPoint()
        XCTAssertEqual(model.quad.count, 2)
        model.cancelPending()

        model.tool = .perspectiveCrop
        for p in [pt(10, 20), pt(300, 10), pt(310, 290), pt(20, 280)] { canvas.tap(p) }
        canvas.drag(pt(310, 290), pt(330, 300))
        XCTAssertEqual(model.quad.count, 4)
        XCTAssertNear(model.quad[safe: 2], pt(330, 300))
    }

    func testRulerEndsSamplersAndPathHandlesDrag() throws {
        let (model, canvas) = canvas(tool: .ruler)
        canvas.drag(pt(0, 0), pt(30, 40))
        canvas.drag(pt(32, 42), pt(60, 80))
        XCTAssertNear(model.ruler?.0, pt(0, 0))
        XCTAssertNear(model.ruler?.1, pt(60, 80), "the end moved")

        model.tool = .colorSampler
        canvas.tap(pt(10, 10))
        canvas.drag(pt(12, 12), pt(50, 60))
        XCTAssertEqual(model.samplers.count, 1)
        XCTAssertNear(model.samplers[safe: 0], pt(50, 60))
        XCTAssertEqual(model.toast, "#1: R 255 G 255 B 255")

        model.tool = .pen
        canvas.drag(pt(200, 100), pt(250, 150))
        model.tool = .directSelect
        canvas.drag(pt(252, 152), pt(250, 100))
        let k = try XCTUnwrap(model.workPath.first?.knots.first)
        XCTAssertNear(k.outHandle, pt(250, 100))
        XCTAssertNear(k.inHandle, pt(200 - 50 * Float(2).squareRoot(), 100), accuracy: 0.01, "the other handle stays opposite")
        XCTAssertNear(k.anchor, pt(200, 100))
    }

    /// Lock Ratio: a corner, an edge or a typed size keeps the box's shape.
    func testTheMarqueeBoxKeepsItsRatioWhenLocked() {
        let b = MarqueeBox(x: 10, y: 10, w: 40, h: 20)
        let corner = b.dragged(.corner(2), dx: 40, dy: 0, keepRatio: true)
        XCTAssertEqual(corner.rect, [10, 10, 80, 40], "the top left stays")
        let edge = b.dragged(.edge(1), dx: 20, dy: 0, keepRatio: true)
        XCTAssertEqual([edge.w, edge.h], [60, 30])
        XCTAssertEqual(b.dragged(.corner(2), dx: 40, dy: 0, keepRatio: false).rect, [10, 10, 80, 20])

        let model = makeModel(width: 200, height: 200)
        model.selectMarquee([10, 10, 40, 20], ellipse: false, mode: "replace")
        model.marqueeLockRatio = true
        model.setMarquee(\.w, 80)
        XCTAssertEqual(model.marqueeBox?.h, 40)
    }
}
