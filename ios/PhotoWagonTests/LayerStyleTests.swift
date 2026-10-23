import XCTest
@testable import PhotoWagon

/// Layer Style: effects added, shared light, deleted, dragged in the image, and Cancel
/// (OpacityFillTests' testLayerStyles and Blending Options).
@MainActor
final class LayerStyleTests: XCTestCase {
    private func styled() throws -> (EditorModel, UInt64) {
        let model = makeModel(width: 200, height: 200)
        model.run("layer.new.layer", ["name": "text"])
        model.run("select.rect", ["x": 50, "y": 50, "width": 100, "height": 100])
        model.run("edit.fill")
        model.run("select.deselect")
        return (model, try XCTUnwrap(model.activeLayer?.id))
    }

    private func angles(_ s: LayerStyleState) -> [Double] { s.effects.compactMap { ($0.params["angle"] as? NSNumber)?.doubleValue } }

    func testDropShadowsShareTheGlobalLightAndOneCanBeDeleted() throws {
        let (model, layer) = try styled()
        let style = LayerStyleState(model: model, layer: layer, start: "dropShadow")
        XCTAssertEqual(style.effects.map(\.kind), ["dropShadow"], "opening a missing effect adds it")
        XCTAssertEqual(style.current?.kind, "dropShadow")
        XCTAssertEqual(model.row("text")?.effects.map(\.name), ["Drop Shadow"])
        let first = try XCTUnwrap(style.current?.id)
        style.set(first, "useGlobalLight", true)
        style.add("dropShadow")
        XCTAssertEqual(style.effects.count, 2)
        XCTAssertNotEqual(style.effects.first?.id, first, "the copy goes above the first")
        XCTAssertEqual(model.row("text")?.effects.count, 2)

        style.set(first, "angle", 45.0)
        XCTAssertEqual(angles(style), [45, 45], "Use Global Light: one angle turns both")
        XCTAssertEqual((model.query("layer.layerStyle.get", ["layer": layer]) as? [String: Any]).flatMap { ($0["globalLight"] as? NSNumber)?.doubleValue }, 45)
        XCTAssertEqual(style.light, 45)

        style.delete(try XCTUnwrap(style.effects.first?.id))
        XCTAssertEqual(style.effects.map(\.id), [first])
        XCTAssertEqual(style.page, "blendingOptions")
        style.set(first, "spread", 40)
        XCTAssertEqual(model.row("text")?.effects.count, 1)

        // Fill 0%: the layer's pixels go, the shadow stays.
        style.setBlending("fillOpacity", 0)
        XCTAssertEqual(model.row("text")?.fill, 0)
        XCTAssertLessThan(model.mean([150, 150, 20, 20])[safe: 0] ?? -1, 0.99, "the shadow still shows")
        XCTAssertEqual(model.pixel(100, 100), [1, 1, 1, 1], "the fill is gone")

        // Reopening finds the shadow instead of adding another; a hidden one comes back on.
        style.set(first, enabled: false)
        let again = LayerStyleState(model: model, layer: layer, start: "dropShadow")
        XCTAssertEqual(again.effects.count, 1)
        XCTAssertEqual(again.current?.enabled, true)
    }

    func testCancelTakesBackOnlyWhatThisSheetChanged() throws {
        let (model, layer) = try styled()
        let untouched = LayerStyleState(model: model, layer: layer, start: "blendingOptions")
        let history = model.historyNames
        untouched.cancel()
        XCTAssertEqual(model.historyNames, history, "nothing changed: nothing undone")

        let style = LayerStyleState(model: model, layer: layer, start: "stroke")
        style.add("bevelEmboss")
        style.set(try XCTUnwrap(style.current?.id), "depth", 300)
        style.setBlending("fillOpacity", 50)
        style.cancel()
        XCTAssertEqual(model.row("text")?.effects, [])
        XCTAssertEqual(model.row("text")?.fill, 1)
    }

    func testDraggingInTheImageMovesTheShadow() throws {
        // OpacityFillTests: drag in the image to move the shadow.
        let (model, layer) = try styled()
        let style = LayerStyleState(model: model, layer: layer, start: "dropShadow")
        let id = try XCTUnwrap(style.current?.id)
        style.set(id, ["angle": 90.0, "distance": 10.0, "useGlobalLight": false])
        style.updateDrag()
        let drag = try XCTUnwrap(model.sheetDrag)
        // Light from above: the shadow falls 10 below. Dragging 20 right puts it below and right.
        drag.moved(true, pt(0, 0), pt(0, 0))
        drag.moved(false, pt(0, 0), pt(20, 0))
        let p = try XCTUnwrap(style.current?.params)
        XCTAssertEqual(p["distance"] as? Double, 22)
        XCTAssertEqual(p["angle"] as? Double, 153)
        style.page = "blendingOptions"
        style.updateDrag()
        XCTAssertNil(model.sheetDrag, "only a shadow's page takes drags")
        XCTAssertEqual(LayerStyle.label("dropShadow"), "Drop Shadow")
        XCTAssertEqual(LayerStyle.label("mystery"), "mystery")
    }
}
