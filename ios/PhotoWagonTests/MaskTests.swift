import XCTest
@testable import PhotoWagon

/// Layer masks from the Layers panel and Mask Properties: the mask button, View Mask, Density
/// and Feather, linking, copying and moving, Delete and moving an unlinked mask alone
/// (LayerMaskTests' model side).
@MainActor
final class MaskTests: XCTestCase {
    /// A 200 × 200 document with a pixel layer "paint" filled grey, active.
    private func painted() throws -> (EditorModel, UInt64) {
        let model = makeModel(width: 200, height: 200)
        model.run("layer.new.layer", ["name": "paint"])
        model.run("edit.fill", ["contents": "gray"])
        return (model, try XCTUnwrap(model.row("paint")?.id))
    }

    private func mask(_ model: EditorModel, _ layer: String, _ rect: [Int]? = nil) -> Double {
        var p: [String: Any] = ["of": "mask", "layer": layer]
        if let rect { p["rect"] = rect }
        return ((model.query("document.stats", p) as? [String: Any])?["mean"] as? [Double])?.first ?? -1
    }

    func testTheMaskButtonRevealsOrHidesTheSelectionOrEverything() throws {
        let (model, _) = try painted()
        model.run("select.rect", ["x": 50, "y": 50, "width": 50, "height": 50])
        model.addMask(hide: true)
        XCTAssertTrue(model.maskTarget, "painting goes on the new mask")
        XCTAssertEqual(mask(model, "paint", [60, 60, 90, 90]), 0, accuracy: 0.01, "the selection hides")
        XCTAssertEqual(mask(model, "paint", [150, 150, 190, 190]), 1, accuracy: 0.01)
        model.run("layer.new.layer", ["name": "other"])
        model.addMask(hide: true)
        XCTAssertEqual(mask(model, "other"), 0, accuracy: 0.001, "no selection: Hide All")
        model.run("layer.layerMask.delete")
        model.addMask()
        XCTAssertEqual(mask(model, "other"), 1, accuracy: 0.001, "Reveal All")
    }

    func testDensityFeatherAndLinkShowOnTheRow() throws {
        let (model, id) = try painted()
        model.addMask()
        let steps = model.historyNames.count
        model.setMask(id, density: 30)
        model.setMask(id, density: 50)
        model.setMask(id, feather: 12)
        XCTAssertEqual(model.row("paint")?.mask?.density ?? 0, 50, accuracy: 0.01)
        XCTAssertEqual(model.row("paint")?.mask?.feather ?? 0, 12, accuracy: 0.01)
        XCTAssertEqual(model.historyNames.count, steps + 2, "a slider's drag is one step")
        model.run("layer.layerMask.linked", ["layer": id])
        XCTAssertEqual(model.row("paint")?.mask?.linked, false)
        model.run("layer.layerMask.enabled", ["layer": id])
        XCTAssertEqual(model.row("paint")?.mask?.enabled, false)
    }

    func testCopyAndMoveAMaskToAnotherLayer() throws {
        let (model, id) = try painted()
        model.run("select.rect", ["x": 0, "y": 0, "width": 100, "height": 200])
        model.addMask()
        model.run("layer.new.layer", ["name": "other"])
        let other = try XCTUnwrap(model.row("other")?.id)
        model.copyMask(from: id, to: other, move: false)
        XCTAssertEqual(mask(model, "other"), mask(model, "paint"), accuracy: 0.001)
        XCTAssertTrue(model.row("paint")?.hasMask == true, "a copy")
        model.copyMask(from: other, to: id, move: true)
        XCTAssertFalse(model.row("other")?.hasMask == true, "moved")
    }

    func testViewMaskTogglesAndEndsOnAnotherLayer() throws {
        let (model, id) = try painted()
        model.addMask()
        model.toggleMaskView(id)
        XCTAssertEqual(model.maskView, id)
        model.toggleMaskView(id)
        XCTAssertNil(model.maskView)
        model.toggleMaskView(id)
        model.targetLayer(try XCTUnwrap(model.row("Background")?.id))
        XCTAssertNil(model.maskView, "selecting another layer ends it")
    }

    /// A black square painted in the mask at 20, 20 (40 × 40).
    private func maskSquare(_ model: EditorModel) {
        model.addMask()
        model.run("select.rect", ["x": 20, "y": 20, "width": 40, "height": 40])
        model.run("edit.fill", ["contents": "black"])
        model.run("select.deselect")
    }

    func testAnUnlinkedMaskMovesAloneWithFreeTransformAndTheMoveTool() throws {
        let (model, id) = try painted()
        maskSquare(model)
        model.run("layer.layerMask.linked", ["layer": id])
        model.beginTransform()
        let box = try XCTUnwrap(model.transform)
        XCTAssertEqual([box.x0, box.y0, box.x1, box.y1], [20, 20, 60, 60], "the box frames the mask's painting")
        model.transform?.dx = 100
        model.commitPending()
        XCTAssertEqual(mask(model, "paint", [125, 25, 155, 55]), 0, accuracy: 0.01, "the square moved right in the mask")
        XCTAssertEqual(mask(model, "paint", [25, 25, 55, 55]), 1, accuracy: 0.01)
        model.tool = .move
        CanvasUIView(model: model).drag(pt(140, 40), pt(140, 140))
        XCTAssertEqual(mask(model, "paint", [125, 125, 155, 155]), 0, accuracy: 0.01, "and down with the Move tool")
        let layerPixels = (model.query("document.stats", ["of": "pixels", "layer": "paint"]) as? [String: Any])?["mean"] as? [Double]
        XCTAssertEqual(layerPixels?.first ?? 0, 0.5, accuracy: 0.01, "the layer's pixels stay")
    }

    func testDeleteFillsASelectedMaskWithTheBackgroundColour() throws {
        let (model, _) = try painted()
        model.addMask(hide: true)
        model.run("select.rect", ["x": 0, "y": 0, "width": 100, "height": 100])
        // A selected mask has its own colours, white in front and black behind: swap for white.
        model.swapColors()
        model.run("edit.clear")
        XCTAssertEqual(mask(model, "paint", [10, 10, 90, 90]), 1, accuracy: 0.01, "white, the background colour")
        XCTAssertEqual((model.query("document.stats", ["of": "pixels", "layer": "paint"]) as? [String: Any]).flatMap { ($0["mean"] as? [Double])?.last } ?? 0, 1, accuracy: 0.01, "the pixels stay")
    }

    func testAColorFillTakesItsColourFromTheImage() throws {
        let model = makeModel(width: 200, height: 200)
        model.run("select.rect", ["x": 0, "y": 0, "width": 100, "height": 200])
        model.run("edit.fill", ["contents": "color", "color": "#ff0000"])
        model.run("select.deselect")
        model.run("layer.newFillLayer.solidColor", ["color": "#0000ff"])
        let fill = try XCTUnwrap(model.activeLayer?.id)
        model.run("layer.setProps", ["layer": fill, "visible": false])
        model.sampleSize = "3"
        model.setFillColor(fill, from: CGPoint(x: 0.25, y: 0.5))
        model.run("layer.setProps", ["layer": fill, "visible": true])
        let c = model.mean([150, 50, 190, 150])
        XCTAssertEqual(c.first ?? 0, 1, accuracy: 0.01, "red now: \(c)")
        XCTAssertEqual(c[safe: 2] ?? 1, 0, accuracy: 0.01)
    }

    func testKeysOpenTheSettingsTheirMenuItemsOpen() {
        let model = makeModel(width: 100, height: 100)
        model.performKey("image.adjustments.curves")
        XCTAssertEqual(model.commandSettings?.id, "image.adjustments.curves", "⌘M opens Curves")
        model.commandSettings = nil
        model.performKey("edit.preferences.general")
        XCTAssertEqual(model.request, .generalPreferences)
        model.performKey("select.all")
        XCTAssertEqual(model.doc?.hasSelection, true, "a key without settings runs")
    }

    func testPreferencesRoundTrip() {
        let model = makeModel()
        let was = model.pref("general.resizeImageDuringPlace") as? Bool ?? true
        model.setPref("general.resizeImageDuringPlace", !was)
        XCTAssertEqual(model.pref("general.resizeImageDuringPlace") as? Bool, !was)
        model.setPref("general.resizeImageDuringPlace", was)
    }
}
