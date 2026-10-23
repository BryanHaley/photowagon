import XCTest
@testable import PhotoWagon

/// The Layers list as the panel shows it, and the layer rules the walkthroughs check
/// (LayersTests, OpacityFillTests).
@MainActor
final class LayerTests: XCTestCase {
    /// Background, a group G of A and B, a smart object C with a live filter, a mask, half fill
    /// and a drop shadow, and an Invert clipped to it.
    private func everyKind() -> EditorModel {
        let model = makeModel(width: 64, height: 64)
        model.run("layer.new.layer", ["name": "A"])
        model.run("layer.new.layer", ["name": "B"])
        model.run("layer.select", ["name": "A", "mode": "add"])
        model.run("layer.groupLayers", ["name": "G"])
        model.run("layer.new.layer", ["name": "C"])
        model.run("select.rect", ["x": 0, "y": 0, "width": 20, "height": 20])
        model.run("edit.fill")
        model.run("select.deselect")
        model.run("filter.convertForSmartFilters")
        model.run("filter.noise.addNoise", ["amount": 10])
        model.run("layer.layerMask.revealAll")
        model.run("layer.setProps", ["fill": 0.5])
        model.run("layer.layerStyle.dropShadow", [:])
        model.run("layer.newAdjustmentLayer.invert")
        model.run("layer.createClippingMask")
        return model
    }

    func testTheListShowsGroupsMasksFiltersAndStyles() throws {
        let model = everyKind()
        XCTAssertNil(model.toast, model.toast ?? "")
        XCTAssertEqual(model.layers.map(\.name), ["Invert 1", "C", "G", "B", "A", "Background"], "top first, a group's layers under it")
        XCTAssertEqual(model.layers.map(\.depth), [0, 0, 0, 1, 1, 0])
        XCTAssertEqual(model.layerCount, 6)

        let invert = try XCTUnwrap(model.row("Invert 1"))
        XCTAssertEqual(invert.adjustment?.kind, "invert")
        XCTAssertTrue(invert.clipped)
        XCTAssertTrue(invert.active)
        XCTAssertEqual(model.activeLayer?.id, invert.id)

        let c = try XCTUnwrap(model.row("C"))
        XCTAssertEqual(c.kind, "Embedded")
        XCTAssertTrue(c.hasMask)
        XCTAssertEqual(c.fill, 0.5)
        XCTAssertEqual(c.smartFilters.map(\.name), ["Add Noise"], "the filter's menu name")
        XCTAssertEqual(c.smartFilters.first?.params["amount"] as? Int, 10)
        XCTAssertEqual(c.effects.map(\.name), ["Drop Shadow"])
        XCTAssertEqual(c.bounds, [0, 0, 20, 20])

        XCTAssertTrue(try XCTUnwrap(model.row("Background")).isBackground)
        XCTAssertEqual(model.layers.filter(\.isBackground).count, 1)
        XCTAssertTrue(try XCTUnwrap(model.row("G")).isGroup)

        // A closed group's layers leave the list but still count.
        let g = try XCTUnwrap(model.row("G"))
        model.run("layer.setExpanded", ["layer": g.id, "expanded": false])
        model.reloadLayers()
        XCTAssertEqual(model.layers.map(\.name), ["Invert 1", "C", "G", "Background"])
        XCTAssertEqual(model.layerCount, 6)
        XCTAssertFalse(try XCTUnwrap(model.row("G")).expanded)
    }

    func testOpacityAndFillAreTheSameWithoutAStyle() throws {
        // OpacityFillTests: a black Solid Color over white at 42% opacity, or at 42% fill.
        let model = makeModel(width: 64, height: 64)
        model.run("layer.newFillLayer.solidColor", ["color": "#000000"])
        let fill = try XCTUnwrap(model.activeLayer)
        XCTAssertEqual(fill.kind, "Fill")
        model.run("layer.setProps", ["opacity": 0.42])
        let byOpacity = model.mean()
        model.run("layer.setProps", ["opacity": 1, "fill": 0.42])
        XCTAssertEqual(model.mean()[safe: 0] ?? -1, byOpacity[safe: 0] ?? -2, accuracy: 0.01)
        XCTAssertEqual(byOpacity[safe: 0] ?? -1, 0.58, accuracy: 0.02)
        // With a style, Fill leaves the style alone and Opacity fades it too.
        model.run("layer.setProps", ["fill": 0])
        XCTAssertEqual(model.mean()[safe: 0] ?? -1, 1, accuracy: 0.01, "fill 0: nothing left")
    }

    func testTheBackgroundIsLocked() throws {
        let model = makeModel(width: 64, height: 64)
        let bg = try XCTUnwrap(model.activeLayer)
        XCTAssertTrue(bg.isBackground)
        model.beginTransform()
        XCTAssertNil(model.transform)
        XCTAssertEqual(model.toast, "The Background is locked: tap its lock in Layers to transform it")
        model.beginPuppet()
        XCTAssertNil(model.puppet)
        XCTAssertEqual(model.toast, "Pin Warp can't bend the Background: unlock it first")

        // Inside a selection it transforms.
        model.run("select.rect", ["x": 8, "y": 8, "width": 16, "height": 16])
        model.beginTransform()
        XCTAssertEqual(model.transform.map { [$0.x0, $0.y0, $0.x1, $0.y1] }, [8, 8, 24, 24])
        model.cancelPending()
        XCTAssertNil(model.transform)

        // Number keys don't fade it.
        model.tool = .move
        CanvasUIView(model: model).opacityKey(4, shift: false, time: 1)
        XCTAssertEqual(model.info("Background")?["opacity"] as? Double, 1)
    }

    func testRasterizePromptForTypeAndSmartLayers() throws {
        // LayersTests: the Brush on a smart object asks to rasterize it first.
        let model = makeModel(width: 200, height: 200)
        model.run("type.create", ["x": 10, "y": 100, "text": "Hi", "size": 40])
        let type = try XCTUnwrap(model.activeLayer)
        XCTAssertEqual(type.kind, "Type")
        model.tool = .brush
        let canvas = CanvasUIView(model: model)
        canvas.drag(pt(20, 20), pt(120, 120))
        XCTAssertEqual(model.rasterizePrompt?.id, type.id)
        XCTAssertEqual(model.rasterizePromptText?.title, "This type must be rasterized before proceeding.")
        XCTAssertEqual(model.rasterizePromptText?.message, "Its contents will no longer be editable as text.")
        model.rasterizePromptAnswered(rasterize: true)
        XCTAssertNil(model.rasterizePrompt)
        XCTAssertEqual(model.activeLayer?.kind, "Pixel")
        canvas.drag(pt(20, 20), pt(120, 120))
        XCTAssertNil(model.rasterizePrompt, "now it paints")
        XCTAssertEqual(model.activeLayer?.kind, "Pixel")

        model.run("layer.smartObjects.convertToSmartObject")
        canvas.drag(pt(20, 120), pt(120, 20))
        XCTAssertEqual(model.rasterizePromptText?.title, "This embedded layer must be rasterized before proceeding.")
        XCTAssertEqual(model.rasterizePromptText?.message, "Its contents will no longer be editable as an embedded layer.")
        model.rasterizePromptAnswered(rasterize: false)
        XCTAssertNil(model.rasterizePrompt)
        XCTAssertEqual(model.activeLayer?.kind, "Embedded", "Cancel keeps it")
    }

    func testFitLayersZoomsToTheSelectedContent() throws {
        let model = makeModel(width: 1000, height: 1000)
        model.run("layer.new.layer")
        model.run("select.rect", ["x": 100, "y": 200, "width": 100, "height": 50])
        model.run("edit.fill")
        model.run("select.deselect")
        model.fitLayers()
        XCTAssertEqual(model.view.zoom, 1200 / 100 * 0.9, accuracy: 0.01)
        XCTAssertEqual(model.view.centerX, 150, accuracy: 0.01)
        XCTAssertEqual(model.view.centerY, 225, accuracy: 0.01)
        XCTAssertEqual(model.view.rotation, 0)
    }

    func testPlacingSeveralFilesMakesALayerEachInOrder() {
        let model = makeModel(width: 800, height: 500)
        model.createFrameAnimation()
        model.placeAll((1...3).map { sample("drop-\($0).png") }, embedded: false)
        wait("three layers") { model.layers.count == 4 && !model.busy }
        XCTAssertEqual(model.layers.map(\.name), ["drop-3", "drop-2", "drop-1", "Background"])
        XCTAssertNil(model.transform, "committed as they land")
    }
}
