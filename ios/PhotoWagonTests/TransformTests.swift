import XCTest
@testable import PhotoWagon

/// Free Transform, crops, the Polygonal Lasso and Pin Warp: the drags on the canvas and what
/// Return commits (GettingStartedTests' transform steps, LayersTests' ⌘T and Pin Warp).
@MainActor
final class TransformTests: XCTestCase {
    /// A 400 × 400 document with a 100 × 100 square at 100, 100 on its own layer, in Free Transform.
    private func square() throws -> (EditorModel, CanvasUIView) {
        let model = makeModel(width: 400, height: 400)
        model.run("layer.new.layer", ["name": "square"])
        model.run("select.rect", ["x": 100, "y": 100, "width": 100, "height": 100])
        model.run("edit.fill")
        model.run("select.deselect")
        model.beginTransform()
        XCTAssertEqual(try XCTUnwrap(model.transform).corners, [pt(100, 100), pt(200, 100), pt(200, 200), pt(100, 200)])
        return (model, CanvasUIView(model: model))
    }

    private func quad(_ model: EditorModel) -> [[Float]] {
        (model.transform?.quad ?? []).map { [($0.x * 100).rounded() / 100, ($0.y * 100).rounded() / 100] }
    }

    func testTheBoxMovesScalesAndTurnsAboutItsReferencePoint() {
        var b = TransformBox(x0: 0, y0: 0, x1: 100, y1: 50)
        XCTAssertEqual(b.origin, pt(50, 25), "the centre unless moved")
        XCTAssertEqual(b.gridPoint(2, 2), pt(100, 50))
        XCTAssertEqual(b.gridPoint(1, 0), pt(50, 0))
        b.sx = 2
        XCTAssertEqual(b.map(pt(100, 50)), pt(150, 50))
        b.setPivot(b.gridPoint(0, 0))
        XCTAssertEqual(b.quad.map { [$0.x, $0.y] }, [[-50, 0], [150, 0], [150, 50], [-50, 50]], "moving the reference point keeps the box")
        b.angle = .pi / 2
        let turned = b.map(pt(100, 0))
        XCTAssertEqual(turned.x, -50, accuracy: 0.001, "turns about the new reference point")
        XCTAssertEqual(turned.y, 200, accuracy: 0.001)
    }

    /// The round handle above the box turns it; the options bar turns it by quarter turns.
    func testTheRotateHandleAndQuarterTurns() throws {
        let (model, canvas) = try square()
        let knob = canvas.toDoc(canvas.rotateHandle(try XCTUnwrap(model.transform)).knob)
        guard case .rotate = canvas.transformDrag(try XCTUnwrap(model.transform), at: knob) else { return XCTFail("the handle rotates") }
        // Dragged a quarter turn round the centre (150, 150): from above it to the right of it.
        canvas.drag(knob, pt(150 + (150 - knob.y), 150), steps: 8)
        XCTAssertEqual(try XCTUnwrap(model.transform).angle, .pi / 2, accuracy: 0.01)
        model.rotateTransform(by: -90)
        XCTAssertEqual(try XCTUnwrap(model.transform).angle, 0, "back exactly")
        model.rotateTransform(by: 90)
        XCTAssertEqual(quad(model), [[200, 100], [200, 200], [100, 200], [100, 100]], "a quarter turn about the centre")
    }

    func testACornerKeepsTheProportionsUnlessShiftOrTheOptionIsOff() throws {
        let (model, canvas) = try square()
        canvas.drag(pt(200, 200), pt(300, 250))
        XCTAssertEqual(quad(model), [[100, 100], [300, 100], [300, 300], [100, 300]], "the opposite corner stays, proportions kept")
        canvas.drag(pt(300, 300), pt(300, 250), modifiers: .shift)
        XCTAssertEqual(quad(model)[safe: 2], [300, 250], "⇧ stretches")

        model.keepProportions = false
        canvas.drag(pt(300, 250), pt(250, 350))
        XCTAssertEqual(quad(model)[safe: 2], [250, 350])

        model.commitPending()
        XCTAssertNil(model.transform)
        XCTAssertEqual(model.row("square")?.bounds, [100, 100, 150, 250])
    }

    func testScaleFromTheReferencePoint() throws {
        let (model, canvas) = try square()
        model.scaleFromPivot = true
        canvas.drag(pt(200, 200), pt(250, 250))
        XCTAssertEqual(quad(model), [[50, 50], [250, 50], [250, 250], [50, 250]], "about the centre")
        model.scaleFromPivot = false
        model.transform?.setPivot(try XCTUnwrap(model.transform).gridPoint(0, 0))
        // ⌥ scales about the reference point (now the top left) for one drag.
        canvas.drag(pt(250, 250), pt(150, 150), modifiers: .alternate)
        XCTAssertEqual(quad(model), [[50, 50], [150, 50], [150, 150], [50, 150]])
    }

    func testDragTheReferencePointThenTurnAboutIt() throws {
        let (model, canvas) = try square()
        canvas.drag(pt(150, 150), pt(110, 110))
        XCTAssertNear(model.transform?.origin, pt(110, 110))
        XCTAssertEqual(quad(model)[safe: 0], [100, 100], "the box stays put")
        // Outside the box turns it; ⇧ in 15° steps.
        canvas.drag(pt(300, 110), pt(110, 300), modifiers: .shift)
        XCTAssertEqual(try XCTUnwrap(model.transform).angle, .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(quad(model)[safe: 0], [120, 100], "turned about the reference point")
        canvas.drag(pt(300, 300), pt(200, 300))
        let angle = try XCTUnwrap(model.transform).angle
        XCTAssertNotEqual(angle.truncatingRemainder(dividingBy: .pi / 12), 0, "free without ⇧")
    }

    func testInsideTheBoxMovesIt() throws {
        let (model, canvas) = try square()
        canvas.drag(pt(130, 170), pt(180, 190))
        XCTAssertEqual(quad(model)[safe: 0], [150, 120])
        XCTAssertTrue(canvas.inside(pt(150, 150), quad: [pt(100, 100), pt(200, 100), pt(200, 200), pt(100, 200)]))
        XCTAssertTrue(canvas.inside(pt(150, 150), quad: [pt(100, 100), pt(100, 200), pt(200, 200), pt(200, 100)]), "either winding")
        XCTAssertFalse(canvas.inside(pt(250, 150), quad: [pt(100, 100), pt(200, 100), pt(200, 200), pt(100, 200)]))
        model.commitPending()
        XCTAssertEqual(model.row("square")?.bounds, [150, 120, 100, 100])
        XCTAssertEqual(model.historyNames.last, "Free Transform")
    }

    func testCancelLeavesTheLayerAndAnEmptyLayerHasNothingToTransform() throws {
        let (model, canvas) = try square()
        canvas.drag(pt(200, 200), pt(300, 300))
        model.cancelPending()
        XCTAssertNil(model.transform)
        XCTAssertEqual(model.row("square")?.bounds, [100, 100, 100, 100])
        model.run("layer.new.layer")
        model.beginTransform()
        XCTAssertNil(model.transform)
        XCTAssertEqual(model.toast, "Nothing to transform on this layer")
    }

    func testCropFrameCommitsAndTooSmallDoesNothing() throws {
        let model = makeModel(width: 400, height: 300)
        model.tool = .crop
        let canvas = CanvasUIView(model: model)
        canvas.tap(pt(200, 150))
        XCTAssertEqual(model.cropRect.map { [$0.0, $0.1] }, [pt(0, 0), pt(400, 300)], "a tap frames the whole image")
        // Drag the right edge in, then move the frame.
        canvas.drag(pt(400, 150), pt(300, 150))
        XCTAssertNear(model.cropRect?.1, pt(300, 300))
        canvas.drag(pt(150, 150), pt(160, 140))
        XCTAssertNear(model.cropRect?.0, pt(10, -10))
        XCTAssertNear(model.cropRect?.1, pt(310, 290))
        model.cropRect = (pt(10, 20), pt(310, 220))
        model.commitPending()
        XCTAssertEqual(model.doc?.width, 300)
        XCTAssertEqual(model.doc?.height, 200)
        XCTAssertNil(model.cropRect)

        model.cropRect = (pt(10, 10), pt(10.5, 100))
        model.commitPending()
        XCTAssertEqual(model.doc?.width, 300, "under a pixel wide: nothing")
        model.cropRect = (pt(0, 0), pt(10, 10))
        model.tool = .move
        XCTAssertNil(model.cropRect, "a half-made crop belongs to its tool")
    }

    func testStraightenLevelsTheLineAndShrinksTheFrame() throws {
        // LayersTests: Crop › Straighten along the horizon.
        let model = makeModel(width: 1000, height: 500)
        model.tool = .crop
        model.straightening = true
        let canvas = CanvasUIView(model: model)
        canvas.drag(pt(100, 300), pt(900, 260))
        XCTAssertFalse(model.straightening)
        XCTAssertEqual(model.cropAngle, -2.9, accuracy: 0.001)
        XCTAssertEqual(model.toast, "Straightened -2.9°")
        let (a, b) = try XCTUnwrap(model.cropRect)
        XCTAssertLessThan(b.x - a.x, 1000)
        XCTAssertEqual((b.x - a.x) / (b.y - a.y), 2, accuracy: 0.01, "the image's shape")
        model.commitPending()
        XCTAssertEqual(model.cropAngle, 0)
        XCTAssertLessThan(try XCTUnwrap(model.doc).width, 1000)
        model.straighten(from: pt(0, 0), to: pt(1, 1))
        XCTAssertNil(model.cropRect, "a line too short to read")
    }

    func testPerspectiveCropTakesFourCornersInAnyOrder() throws {
        let corners = [pt(310, 290), pt(10, 20), pt(300, 10), pt(20, 280)]
        XCTAssertEqual(clockwiseFromTopLeft(corners), [pt(10, 20), pt(300, 10), pt(310, 290), pt(20, 280)])
        let model = makeModel(width: 400, height: 300)
        model.tool = .perspectiveCrop
        let canvas = CanvasUIView(model: model)
        for p in corners { canvas.tap(p) }
        XCTAssertEqual(model.toast, "Return or ✓ crops")
        XCTAssertTrue(model.hasPending)
        model.commitPending()
        XCTAssertEqual(model.doc?.width, 290)
        XCTAssertEqual(model.doc?.height, 270)
    }

    func testPolygonalLassoClosesOnItsFirstPoint() throws {
        let model = makeModel(width: 400, height: 400)
        model.tool = .polygonLasso
        let canvas = CanvasUIView(model: model)
        for p in [pt(100, 100), pt(300, 100), pt(200, 300)] { canvas.tap(p) }
        XCTAssertEqual(model.quad.count, 3)
        XCTAssertEqual(model.doc?.hasSelection, false)
        canvas.tap(pt(102, 101))
        XCTAssertTrue(model.quad.isEmpty)
        XCTAssertEqual(model.doc?.hasSelection, true)
        // Two points aren't a shape.
        model.quad = [pt(1, 1), pt(5, 5)]
        model.commitPending()
        XCTAssertTrue(model.quad.isEmpty)
    }

    func testPinWarpPinsBendAndCommit() throws {
        // LayersTests: Edit › Pin Warp: pins, then drag one; Return commits.
        let (model, canvas) = try square()
        model.cancelPending()
        model.beginPuppet()
        let layer = try XCTUnwrap(model.row("square")).id
        XCTAssertEqual(model.puppet?.layer, layer)
        canvas.tap(pt(110, 110))
        canvas.tap(pt(190, 190))
        XCTAssertEqual(model.puppet?.pins.count, 2)
        XCTAssertEqual(model.puppet?.selected, 1)
        canvas.tap(pt(111, 111))
        XCTAssertEqual(model.puppet?.selected, 0, "a tap near a pin picks it")
        XCTAssertEqual(model.puppet?.pins.count, 2)
        canvas.drag(pt(190, 190), pt(240, 190))
        XCTAssertNear(model.puppet?.pins[safe: 1]?.dst, pt(240, 190))
        XCTAssertNear(model.puppet?.pins[safe: 1]?.src, pt(190, 190))
        let p = try XCTUnwrap(model.puppet)
        XCTAssertTrue(p.sameWarp(Puppet(layer: layer, pins: p.pins, selected: 0, showMesh: false)), "showing and selecting don't change the warp")
        XCTAssertFalse(p.sameWarp(nil))
        XCTAssertEqual((p.warpParams["pins"] as? [[String: Any]])?.count, 2)
        model.commitPending()
        XCTAssertNil(model.puppet)
        idle(model)
        XCTAssertEqual(model.historyNames.last, "Pin Warp")
        XCTAssertGreaterThan(try XCTUnwrap(model.row("square")?.bounds?[safe: 2]), 100, "the right side was pulled out")

        model.run("layer.new.layer")
        model.beginPuppet()
        XCTAssertNotNil(model.puppet, "an empty pixel layer still opens (the warp finds no mesh)")
        model.cancelPending()
        XCTAssertNil(model.puppet)
    }
}
