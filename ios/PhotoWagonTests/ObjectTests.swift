import XCTest
@testable import PhotoWagon

/// Vision first, the engine's own object finding when Vision finds nothing (the simulator and
/// older devices): Object Selection, Select Subject, Refine Hair, Remove Background.
@MainActor
final class ObjectTests: XCTestCase {
    /// A Vision that finds nothing.
    final class NoObjects: ObjectFinder, @unchecked Sendable {
        override func objects(_ editor: Editor, layer: UInt64?) -> Found? { nil }
        override func personMatte(_ editor: Editor, layer: UInt64?) -> Mask? { nil }
    }

    private func subject() -> EditorModel {
        let model = makeModel()
        model.objects = NoObjects()
        open("subject.jpg", in: model)
        model.canvasResized(width: 1200, height: 1200, scale: 3)
        return model
    }

    func testHoldShowsTheEnginesObjectThenLiftSelectsIt() throws {
        let model = subject()
        let d = try XCTUnwrap(model.doc)
        let centre = pt(Float(d.width) / 2, Float(d.height) / 2)
        model.tool = .objectSelect
        model.holdObject(at: centre)
        // A tap while the hold is still looking waits for it.
        model.selectObject(at: centre, mode: "replace")
        idle(model)
        XCTAssertNotNil(model.lastObjectHighlight, "the held object is highlighted")
        XCTAssertEqual(model.doc?.hasSelection, true, "lifting selects it")
        model.tool = .move
        XCTAssertNil(model.objectHighlight, "another tool drops the highlight")
    }

    func testSelectSubjectAndRemoveBackgroundWithoutVision() throws {
        let model = subject()
        model.selectSubject(mode: "replace")
        idle(model)
        XCTAssertEqual(model.doc?.hasSelection, true, "the engine's subject")
        model.run("select.deselect")
        model.refineHair()
        idle(model)
        XCTAssertEqual(model.toast, "No person found to refine")

        model.run("layer.duplicate")
        model.removeBackground()
        idle(model)
        XCTAssertEqual(model.activeLayer?.hasMask, true, "a mask keeps the subject")
    }

    /// Select Subject looks at the active layer (Sample All Layers off), not a pattern over it.
    func testSelectSubjectLooksAtTheActiveLayer() throws {
        let model = subject()
        let photo = try XCTUnwrap(model.activeLayer?.id)
        model.run("layer.new.layer", ["name": "cover"])
        model.run("edit.fill", ["contents": "gray"])
        model.targetLayer(photo)
        model.selectSubject(mode: "replace")
        idle(model)
        let all = model.query("document.stats", ["of": "selection"]) as? [String: Any]
        XCTAssertGreaterThan((all?["mean"] as? [Double])?.first ?? 0, 0.1, "the dog under the grey layer")
    }

    func testNothingFoundSaysSo() {
        let model = makeModel(width: 200, height: 200)
        model.objects = NoObjects()
        model.selectSubject(mode: "replace")
        idle(model)
        XCTAssertEqual(model.toast, "No subject found")
        model.selectInBackground("select.object", ["rect": [10, 10, 50, 50], "mode": "replace"], nothing: "Nothing there")
        idle(model)
        XCTAssertEqual(model.toast, "Nothing there")
    }

    func testTheHighlightTint() throws {
        let image = try XCTUnwrap(ObjectFinder.tint(width: 1000, height: 10, maxSide: 100) { x, _ in x < 500 ? 255 : 0 })
        XCTAssertEqual(image.width, 100, "scaled to fit")
        XCTAssertEqual(image.height, 1)
        XCTAssertNil(ObjectFinder.tint(width: 0, height: 0) { _, _ in 0 })
    }
}
