import XCTest
@testable import PhotoWagon

/// The Move tool: snapping to the canvas, ⇧ for one direction, ⌥ for a copy, Auto-Select
/// (GettingStartedTests' Move steps, LayersTests' Snap and Copy While Moving).
@MainActor
final class MoveTests: XCTestCase {
    /// 400 × 400 with "a" (50 × 50 at 100, 100) under "b" (50 × 50 at 250, 250), "a" selected.
    private func twoLayers() throws -> (EditorModel, CanvasUIView) {
        let model = makeModel(width: 400, height: 400)
        for (name, x) in [("a", 100), ("b", 250)] {
            model.run("layer.new.layer", ["name": name])
            model.run("select.rect", ["x": x, "y": x, "width": 50, "height": 50])
            model.run("edit.fill")
        }
        model.run("select.deselect")
        model.run("layer.select", ["name": "a"])
        model.tool = .move
        let snap = model.snap
        model.snap = true
        addTeardownBlock { @MainActor in model.snap = snap }
        return (model, CanvasUIView(model: model))
    }

    func testSnapsToTheCanvasCentreAndEdgesOnly() throws {
        let (model, canvas) = try twoLayers()
        canvas.prepareSnap()
        // The centre (125) moved by 72 is 3 short of the canvas centre: it snaps.
        let (dx, dy) = canvas.snapped(72, 0)
        XCTAssertEqual(dx, 75)
        XCTAssertEqual(dy, 0)
        XCTAssertEqual(model.smartGuides.count, 1)
        XCTAssertEqual(model.smartGuides.first?.0, pt(200, 0), "a guide down the canvas centre")
        // Its left edge 3 short of "b"'s right edge (300), far from the canvas: no snap.
        XCTAssertEqual(canvas.snapped(197, 0).0, 197, "other layers aren't snapped to")
        XCTAssertTrue(model.smartGuides.isEmpty)
        // Its left edge 4 from the canvas edge.
        XCTAssertEqual(canvas.snapped(-96, -104).0, -100)
        XCTAssertEqual(canvas.snapped(-96, -104).1, -100)

        let steps = model.historyNames.count
        canvas.drag(pt(125, 125), pt(197, 125))
        XCTAssertEqual(model.row("a")?.bounds, [175, 100, 50, 50])
        XCTAssertTrue(model.smartGuides.isEmpty, "guides go when the finger lifts")
        XCTAssertEqual(model.historyNames.count, steps + 1, "the whole drag is one step")

        model.snap = false
        canvas.prepareSnap()
        XCTAssertEqual(canvas.snapped(22, 0).0, 22, "Snap off")
    }

    func testShiftKeepsToOneDirection() throws {
        let (model, canvas) = try twoLayers()
        canvas.drag(pt(125, 125), pt(165, 135), modifiers: .shift)
        XCTAssertEqual(model.row("a")?.bounds, [140, 100, 50, 50])
    }

    func testCopyWhileMovingLeavesTheOriginal() throws {
        let (model, canvas) = try twoLayers()
        model.moveCopies = true
        canvas.drag(pt(125, 125), pt(145, 165))
        XCTAssertEqual(model.layerCount, 4)
        XCTAssertEqual(model.row("a")?.bounds, [100, 100, 50, 50], "the original stays")
        XCTAssertEqual(model.activeLayer?.bounds, [120, 140, 50, 50], "the copy moved")
        model.moveCopies = false
        canvas.drag(pt(130, 145), pt(140, 145), alt: true)
        XCTAssertEqual(model.layerCount, 5, "⌥-drag copies too")
    }

    func testAutoSelectPicksTheLayerUnderTheFinger() throws {
        let (model, canvas) = try twoLayers()
        canvas.drag(pt(275, 275), pt(285, 275), modifiers: .command)
        XCTAssertEqual(model.activeLayer?.name, "b", "⌘ held: a temporary Auto-Select")
        XCTAssertEqual(model.row("b")?.bounds, [260, 250, 50, 50])
        model.autoSelect = true
        canvas.drag(pt(125, 125), pt(125, 135))
        XCTAssertEqual(model.activeLayer?.name, "a")
        XCTAssertEqual(model.row("a")?.bounds, [100, 110, 50, 50])
    }

    func testTheBackgroundDoesntMove() throws {
        let model = makeModel(width: 100, height: 100)
        model.tool = .move
        CanvasUIView(model: model).drag(pt(50, 50), pt(80, 50))
        XCTAssertEqual(model.row("Background")?.bounds, [0, 0, 100, 100])
        XCTAssertNotNil(model.toast, "says why")
    }
}
