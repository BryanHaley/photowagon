import XCTest
@testable import PhotoWagon

/// Artboards: a new document of artboards, the Artboard tool's "+", names and drags, sizes and
/// orientation, layers moving between boards, colour labels, guides on a board, saved presets
/// and export (ArtboardsTests' model side).
@MainActor
final class ArtboardTests: XCTestCase {
    private func boards() -> (EditorModel, CanvasUIView) {
        let model = makeModel()
        model.newDocument(["width": 1080, "height": 1350, "artboard": true])
        model.canvasResized(width: 1200, height: 1200, scale: 3)
        let canvas = CanvasUIView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        return (model, canvas)
    }

    func testANewArtboardDocumentAndItsSizes() {
        let (model, _) = boards()
        XCTAssertEqual(model.artboards.map(\.name), ["Artboard 1"])
        XCTAssertEqual(model.artboards.first?.rect, CGRect(x: 0, y: 0, width: 1080, height: 1350))
        XCTAssertTrue(model.onlyArtboards)
        XCTAssertEqual(model.activeArtboard?.name, "Artboard 1")
        XCTAssertEqual(model.historyNames.count, 1, "nothing to undo")

        model.run("layer.new.artboard", ["width": 1080, "height": 1080, "name": "Banner"])
        XCTAssertEqual(model.artboards.map(\.name), ["Banner", "Artboard 1"])
        XCTAssertEqual(model.activeArtboard?.name, "Banner")
        model.orientArtboard(portrait: true)
        XCTAssertEqual(model.activeArtboard?.rect.size, CGSize(width: 1080, height: 1080), "a square doesn't turn")
        model.resizeArtboard(width: 1080, height: 1920)
        model.orientArtboard(portrait: false)
        XCTAssertEqual(model.activeArtboard?.rect.size, CGSize(width: 1920, height: 1080))

        model.addArtboard(beside: "bottom")
        XCTAssertEqual(model.artboards.count, 3)
        let added = model.activeArtboard?.rect ?? .zero
        XCTAssertEqual(added.size, CGSize(width: 1920, height: 1080), "the same size")
        XCTAssertGreaterThan(added.minY, 1080, "below")
    }

    func testTheOverlayNamesBoardsAndItsPlusAddsOne() {
        let (model, canvas) = boards()
        model.tool = .artboard
        canvas.updateBoards()
        XCTAssertEqual(canvas.boardOverlay.nameRects.map(\.0), model.artboards.map(\.id))
        XCTAssertEqual(canvas.boardOverlay.plusPoints.map(\.0), ["top", "right", "bottom", "left"])
        XCTAssertNotNil(canvas.boardOverlay.pasteboard.path, "the space around the board")

        let right = canvas.boardOverlay.plusPoints[1].1
        XCTAssertTrue(canvas.boardTouched(at: right))
        XCTAssertEqual(model.artboards.count, 2)
        canvas.updateBoards()
        XCTAssertFalse(canvas.boardOverlay.plusPoints.map(\.0).contains("left"), "a + that would sit on the first board isn't offered")

        // A tap on the first board's name selects it.
        let first = model.artboards.last?.id ?? 0
        let name = canvas.boardOverlay.nameRects.first { $0.0 == first }?.1 ?? .zero
        XCTAssertTrue(canvas.boardTouched(at: CGPoint(x: name.midX, y: name.midY)))
        XCTAssertEqual(model.activeArtboard?.id, first)
    }

    func testTheArtboardToolDragsABoardItStartsOnAndDrawsOneOutside() {
        let (model, canvas) = boards()
        model.tool = .artboard
        canvas.drag(pt(500, 500), pt(500, 700))
        XCTAssertEqual(model.artboards.count, 1, "moved, not drawn")
        XCTAssertEqual(model.activeArtboard?.rect.minY ?? 0, 200, accuracy: 2)
        XCTAssertEqual(model.historyNames.last, "Move")
        canvas.drag(pt(1300, 200), pt(1700, 600))
        XCTAssertEqual(model.artboards.count, 2, "drawn on the empty space")
    }

    func testTheViewStaysPutWhenBoardsGrowTheCanvas() {
        let (model, canvas) = boards()
        model.tool = .artboard
        let zoom = model.view.zoom
        canvas.updateBoards()
        canvas.boardTouched(at: canvas.boardOverlay.plusPoints[1].1)
        XCTAssertEqual(model.view.zoom, zoom, "adding a board keeps the zoom")
        // Drag the new board past the left edge: the canvas grows left and everything shifts.
        let first = model.artboards.last { $0.name == "Artboard 1" }?.rect ?? .zero
        let screen = canvas.toScreen(Point(x: Float(first.minX), y: Float(first.minY)))
        let board = model.activeArtboard?.rect ?? .zero
        canvas.drag(pt(Float(board.midX), 300), pt(Float(board.midX) - Float(board.maxX) - 300, 300))
        let moved = model.artboards.first { $0.name == "Artboard 1" }?.rect ?? .zero
        XCTAssertGreaterThan(moved.minX, first.minX, "the canvas grew left: Artboard 1 shifted")
        let after = canvas.toScreen(Point(x: Float(moved.minX), y: Float(moved.minY)))
        XCTAssertEqual(after.x, screen.x, accuracy: 1, "but it stays put on screen")
        XCTAssertEqual(model.view.zoom, zoom)
        XCTAssertEqual(model.activeArtboard?.rect.minX ?? 1, 0, accuracy: 2, "the dragged board at the new left edge")
    }

    func testANewLayerGoesIntoTheBoardAndAMoveTakesItToAnother() {
        let (model, canvas) = boards()
        model.run("layer.new.artboard", ["name": "Cover"])
        let cover = model.artboards.first { $0.name == "Cover" }?.rect ?? .zero
        model.run("layer.select", ["layer": model.artboards.first { $0.name == "Artboard 1" }?.id ?? 0])
        model.run("layer.new.layer")
        XCTAssertEqual(model.parentGroup(of: model.activeLayer?.id ?? 0)?.name, "Artboard 1")
        model.run("select.rect", ["x": 100, "y": 100, "width": 200, "height": 200])
        model.run("edit.fill", ["contents": "color", "color": "#ff0000"])
        model.run("select.deselect")
        let layer = model.activeLayer?.id ?? 0

        plainMove(model)
        model.tool = .move
        let steps = model.historyNames.count
        canvas.drag(pt(200, 200), pt(Float(cover.minX) + 200, 200))
        XCTAssertEqual(model.parentGroup(of: layer)?.name, "Cover", "dropped on Cover")
        XCTAssertEqual(model.historyNames.count, steps + 1, "one undo step")
        XCTAssertGreaterThan(model.pixel(Int(cover.minX) + 200, 200).first ?? 0, 0.9, "shows on Cover")

        // Off every board: out of its board.
        canvas.drag(pt(Float(cover.minX) + 200, 200), pt(Float(cover.minX) + 200, 1700))
        XCTAssertNil(model.parentGroup(of: layer))
    }

    func testLabelsGuidesAndSelectedBoards() {
        let (model, _) = boards()
        let board = model.artboards[0].id
        model.setLabelColor("red", of: board)
        XCTAssertEqual(model.layers.first { $0.id == board }?.labelColor, "red")
        XCTAssertEqual(model.selectedArtboardIds, [board])
        model.run("layer.new.artboard", ["name": "Cover"])
        model.run("layer.select", ["layer": board])
        model.run("view.newGuideLayout", ["columns": 3, "target": "selectedArtboards"])
        XCTAssertGreaterThanOrEqual(model.guides.vertical.count, 2)
        XCTAssert(model.guides.vertical.allSatisfy { $0 >= 0 && $0 <= 1080 }, "\(model.guides.vertical)")
    }

    func testSavedPresetsAndExport() throws {
        SavedPresets.reset()
        addTeardownBlock { SavedPresets.reset() }
        SavedPresets.save(DocPreset(name: "Card", width: 800, height: 600, resolution: 72))
        SavedPresets.save(DocPreset(name: "Card", width: 900, height: 600, resolution: 72))
        XCTAssertEqual(SavedPresets.all.map(\.width), [900], "same name: replaced")
        let (model, _) = boards()
        XCTAssertEqual(model.artboardSizes.first?.name, "Card", "saved sizes first")
        XCTAssertEqual(NewDocumentSheet.preset("Card")?.width, 900)

        let files = model.exportArtboards(format: "png", quality: 10, prefix: "abtest", only: nil)
        addTeardownBlock { for f in files { try? FileManager.default.removeItem(atPath: f) } }
        XCTAssertEqual(files.count, 1)
        XCTAssert(files.first?.hasSuffix("abtest_0000_Artboard 1.png") == true, "\(files)")
        XCTAssert(FileManager.default.fileExists(atPath: files.first ?? ""))
    }
}
