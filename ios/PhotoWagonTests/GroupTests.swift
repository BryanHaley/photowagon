import XCTest
@testable import PhotoWagon

/// Layer groups from the Layers panel: making one, opening and closing it, deleting it.
@MainActor
final class GroupTests: XCTestCase {
    func testAGroupBesideTheBackgroundOpensClosesAndDeletes() throws {
        let model = makeModel(width: 40, height: 30)
        model.newGroup()
        let group = try XCTUnwrap(model.layers.first { $0.isGroup }, "\(model.layers.map(\.name))")
        XCTAssertEqual(model.layers.count, 2, "an empty group beside the Background: \(model.layers.map { ($0.name, $0.depth) })")
        XCTAssertTrue(model.layers.contains { $0.isBackground && $0.depth == 0 }, "the Background stays out of the group")

        let open = group.expanded
        model.toggleGroup(group.id)
        XCTAssertEqual(model.layers.first { $0.id == group.id }?.expanded, !open, "the chevron follows")

        model.targetLayer(group.id)
        XCTAssertEqual(model.activeLayer?.id, group.id)
        model.run("layer.delete")
        XCTAssertFalse(model.layers.contains { $0.id == group.id }, "deleted: \(model.layers.map(\.name)), toast \(model.toast ?? "")")
        XCTAssertEqual(model.layers.count, 1)
    }

    func testDraggingALayerJustUnderAGroupPutsItInAndAboveTakesItOut() throws {
        let model = makeModel(width: 40, height: 30)
        model.newGroup()
        model.run("layer.new.layer")
        let layer = try XCTUnwrap(model.activeLayer?.id)
        // Rows top first: the new layer, the group, the Background. Drop the layer just under the group.
        let rows = { model.layers.map { ($0.name, $0.depth) } }
        let from = try XCTUnwrap(model.layers.firstIndex { $0.id == layer }, "\(rows())")
        let group = try XCTUnwrap(model.layers.firstIndex { $0.isGroup }, "\(rows())")
        model.moveLayer(from: from, to: group + 1)
        XCTAssertEqual(model.layers.first { $0.id == layer }?.depth, 1, "inside the group: \(rows())")
        XCTAssertEqual(model.parentGroup(of: layer)?.isGroup, true)

        // Back out: dragged above the group's row, then in and out by the layer's menu.
        let inside = try XCTUnwrap(model.layers.firstIndex { $0.id == layer })
        let groupRow = try XCTUnwrap(model.layers.firstIndex { $0.isGroup })
        model.moveLayer(from: inside, to: groupRow)
        XCTAssertEqual(model.layers.first { $0.id == layer }?.depth, 0, "out of the group: \(rows())")
        let g = try XCTUnwrap(model.layers.first { $0.isGroup }).id
        model.moveLayer(layer, into: g)
        XCTAssertEqual(model.parentGroup(of: layer)?.id, g)
        model.moveOutOfGroup(layer)
        XCTAssertNil(model.parentGroup(of: layer), "\(rows())")
    }

    /// Layer › New › From Photos and From Files: in the menu, and the picture comes in as a plain
    /// pixel layer, ready to size.
    func testANewLayerFromAPictureIsAPixelLayer() throws {
        let model = makeModel(width: 40, height: 30)
        let new = MainMenu(model: model).items("Layer").compactMap { $0 as? UIMenu }.first { $0.title == "New" }
        let titles = (new?.children ?? []).flatMap { ($0 as? UIMenu)?.children ?? [$0] }.compactMap { ($0 as? UIAction)?.title }
        XCTAssert(titles.contains("From Photos…") && titles.contains("From Files…"), "\(titles)")

        let data = try Data(contentsOf: sample("bee.jpg"))
        model.place(data: data, name: "bee.jpg", embedded: false)
        wait("placed") { !model.busy && model.transform != nil }
        model.commitPending()
        wait("committed") { !model.busy && model.transform == nil }
        XCTAssertEqual(model.activeLayer?.kind, "Pixel", "\(model.layers.map { ($0.name, $0.kind) })")
        XCTAssertEqual(model.layers.count, 2)
    }

    /// Image › Canvas Size asks for a width and height, starting at the document's size.
    func testCanvasSizeStartsAtTheDocumentsSize() throws {
        let model = makeModel(width: 40, height: 30)
        let fields = model.editor.commandFields(id: "image.canvasSize")
        XCTAssertEqual(Array(fields.map(\.name).prefix(2)), ["width", "height"])
        let start = model.startingValues(fields)
        XCTAssertEqual(start["width"] as? Int, 40)
        XCTAssertEqual(start["height"] as? Int, 30)
        model.run("image.canvasSize", ["width": 60, "height": 30])
        XCTAssertEqual(model.doc?.width, 60)
        // Image Size likewise; Rename Layer starts at the layer's name; Crop shows no size of its own.
        XCTAssertEqual(model.startingValues(model.editor.commandFields(id: "image.imageSize"))["width"] as? Int, 60)
        model.run("layer.new.layer")
        XCTAssertEqual(model.startingValues(model.editor.commandFields(id: "layer.renameLayer"))["name"] as? String, model.activeLayer?.name)
        XCTAssertFalse(model.editor.commandFields(id: "image.crop").contains { $0.name == "targetWidth" })
    }
}
