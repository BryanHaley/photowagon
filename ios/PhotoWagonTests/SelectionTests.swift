import XCTest
@testable import PhotoWagon

/// Selection tool options and turning a mask into a selection (SelectionsTests' model side).
@MainActor
final class SelectionTests: XCTestCase {
    private func soft(_ model: EditorModel) -> Double {
        (model.query("document.stats", ["of": "selection"]) as? [String: Any])?["soft"] as? Double ?? -1
    }

    func testFeatherAndAntiAliasShapeTheMarqueesEdge() {
        let model = makeModel(width: 200, height: 200)
        model.selectionFeather = 10
        model.selectMarquee([50, 50, 100, 100], ellipse: false, mode: "replace")
        XCTAssertGreaterThan(soft(model), 0.05, "feathered: a soft edge")
        model.selectionFeather = 0
        model.antiAlias = false
        model.selectMarquee([20, 20, 150, 120], ellipse: true, mode: "replace")
        XCTAssertEqual(soft(model), 0, accuracy: 0.0001, "no anti-alias: every pixel in or out")
        model.antiAlias = true
        model.selectMarquee([20, 20, 150, 120], ellipse: true, mode: "replace")
        XCTAssertGreaterThan(soft(model), 0, "anti-aliased: some partly selected pixels")
    }

    func testQuickSelectionTakesSampleAllLayersAndEnhanceEdge() throws {
        let model = makeModel(width: 100, height: 100)
        model.tool = .quickSelect
        model.sampleAllLayers = true
        model.enhanceEdge = true
        let p = try XCTUnwrap(model.strokeParams()).1
        XCTAssertEqual(p["sampleAllLayers"] as? Bool, true)
        XCTAssertEqual(p["enhanceEdge"] as? Bool, true)
    }

    func testAMaskLoadsAsTheSelection() throws {
        let model = makeModel(width: 200, height: 200)
        model.run("layer.new.layer", ["name": "masked"])
        model.run("select.rect", ["x": 0, "y": 0, "width": 100, "height": 200])
        model.addMask()
        XCTAssertEqual(model.doc?.hasSelection, false, "the mask took the selection")
        model.loadMaskAsSelection(try XCTUnwrap(model.row("masked")?.id))
        let mean = ((model.query("document.stats", ["of": "selection", "rect": [0, 0, 100, 200]]) as? [String: Any])?["mean"] as? [Double])?.first
        XCTAssertEqual(mean ?? 0, 1, accuracy: 0.01, "the left half is selected again")
        let right = ((model.query("document.stats", ["of": "selection", "rect": [100, 0, 200, 200]]) as? [String: Any])?["mean"] as? [Double])?.first
        XCTAssertEqual(right ?? 1, 0, accuracy: 0.01)
    }

    func testCopyFromOneImageAndPasteIntoAnother() {
        let model = makeModel(width: 100, height: 100)
        model.run("select.rect", ["x": 0, "y": 0, "width": 40, "height": 40])
        model.run("edit.fill", ["contents": "black"])
        XCTAssertFalse(model.editor.commandEnabled(id: "edit.paste"), "nothing copied yet")
        model.run("edit.copy")
        model.newDocument(["width": 100, "height": 100])
        XCTAssertEqual(model.documents.count, 2)
        XCTAssertTrue(model.editor.commandEnabled(id: "edit.paste"), "the clipboard is shared by the open images")
        model.run("edit.paste")
        XCTAssertEqual(model.layers.count, 2, "pasted as a new layer")
        let s = model.query("document.stats", ["rect": [10, 10, 30, 30]]) as? [String: Any]
        XCTAssertEqual(numbers(s?["mean"])?.first ?? 1, 0, accuracy: 0.01, "the black square, where it was in the first image")
    }

    func testSavedSelectionsLoadByName() {
        let model = makeModel(width: 100, height: 100)
        model.run("select.rect", ["x": 10, "y": 10, "width": 30, "height": 30])
        model.run("select.saveSelection", ["name": "oval"])
        model.run("select.deselect")
        XCTAssertEqual(model.savedSelections, ["oval"])
        model.loadSelection("oval")
        XCTAssertEqual(model.doc?.hasSelection, true)
        XCTAssertFalse(MenuTree.shows(CommandInfo(id: "select.loadSelection", label: "Load Selection…", menu: "Select", enabled: true, reason: nil, params: "{}")),
                       "a submenu of the saved selections instead")
    }
}
