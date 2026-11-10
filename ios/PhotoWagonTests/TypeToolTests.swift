import XCTest
@testable import PhotoWagon

/// The Type tool on placed text: its box moves, sizes and turns it; its colour; several lines.
@MainActor
final class TypeToolTests: XCTestCase {
    private func info(_ model: EditorModel) throws -> [String: Any] {
        let id = try XCTUnwrap(model.activeLayer?.id)
        let out = try model.editor.execute(id: "type.info", params: json(["layer": id]))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func size(_ model: EditorModel) throws -> Double {
        let style = try XCTUnwrap(((try info(model))["runs"] as? [[String: Any]])?.first?["style"] as? [String: Any])
        return try XCTUnwrap(style["size_pt"] as? Double)
    }

    private func matrix(_ model: EditorModel) throws -> [Double] {
        try XCTUnwrap((try info(model))["transform"] as? [Double])
    }

    private func typed(_ text: String = "Hello") -> EditorModel {
        let model = makeModel(width: 400, height: 300)
        model.run("type.create", ["x": 50, "y": 150, "text": text, "size": 40])
        model.tool = .type
        return model
    }

    func testTheBoxMovesTheTextAndItsCornerChangesTheSize() throws {
        let model = typed()
        let canvas = CanvasUIView(model: model)
        let box = try XCTUnwrap(model.typeBox).box
        XCTAssertEqual(box.angle, 0)
        XCTAssert(box.x0 <= 52 && box.x1 > 100 && box.y0 < 150 && box.y1 > 150, "\(box)")

        let steps = model.history.past.count
        canvas.drag(box.center, pt(box.center.x + 30, box.center.y + 10))
        XCTAssertFalse(model.typeDrag)
        XCTAssertNil(model.transform)
        XCTAssertEqual(try matrix(model)[4], 80, accuracy: 0.5)
        XCTAssertEqual(try matrix(model)[5], 160, accuracy: 0.5)
        XCTAssertEqual(try size(model), 40)
        XCTAssertEqual(model.history.past.count, steps + 1, "one step")

        // The bottom-right corner twice as far from the top-left: twice the size, top-left kept.
        let moved = try XCTUnwrap(model.typeBox).box.quad
        let (tl, br) = (moved[0], moved[2])
        canvas.drag(br, pt(br.x + (br.x - tl.x), br.y + (br.y - tl.y)))
        XCTAssertEqual(try size(model), 80, accuracy: 1)
        XCTAssertEqual(model.typeSize, 80, accuracy: 1, "the options bar shows the new size")
        XCTAssertNear(model.typeBox?.box.quad[0], tl, accuracy: 3)
        XCTAssertEqual(model.history.past.count, steps + 2)
    }

    func testTurningKeepsTheSizeAndTurnsAboutTheCentre() throws {
        let model = typed()
        let before = try XCTUnwrap(model.typeBox)
        var t = before.box
        t.angle = .pi / 2
        model.typeDrag = true
        model.transform = t
        model.commitTypeBox()
        let m = try matrix(model)
        XCTAssertEqual(m[0], 0, accuracy: 1e-5)
        XCTAssertEqual(m[1], 1, accuracy: 1e-5)
        XCTAssertEqual(try size(model), 40)
        let after = try XCTUnwrap(model.typeBox).box
        XCTAssertEqual(after.angle, .pi / 2, accuracy: 1e-4)
        XCTAssertNear(after.map(after.center), before.box.map(before.box.center), accuracy: 2)
        XCTAssertNil(TypeBox(info: try info(model))?.edit(after), "an unchanged box edits nothing")
    }

    func testATapStillEditsTheTextOnSeveralLines() throws {
        let model = typed()
        let canvas = CanvasUIView(model: model)
        canvas.tap(try XCTUnwrap(model.typeBox).box.center)
        let prompt = try XCTUnwrap(model.prompt)
        XCTAssertEqual(prompt.title, "Edit Text")
        XCTAssertTrue(prompt.multiline)
        prompt.done("Hello\nthere")
        let lines = try XCTUnwrap((try info(model))["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.count, 2)
        XCTAssertNil(model.transform)
        // Away from the box the tool adds text as before.
        model.prompt = nil
        canvas.tap(pt(300, 50))
        XCTAssertEqual(model.prompt?.title, "Text")
    }

    func testDoneLetsGoOfTheTextUntilItIsTappedAgain() throws {
        let model = typed()
        let canvas = CanvasUIView(model: model)
        let center = try XCTUnwrap(model.typeBox).box.center
        model.finishEditingText()
        XCTAssertNil(model.typeBox, "no box")
        XCTAssertNil(model.editingText)
        model.setTypeColor([1, 0, 0], edit: 1)
        XCTAssertEqual(model.foreground.hex, "#ff0000", "the options are for new text")
        canvas.tap(center)
        XCTAssertEqual(model.prompt?.title, "Edit Text")
        XCTAssertNotNil(model.typeBox, "tapping the text works on it again")
        // Text added next is worked on straight away.
        model.prompt = nil
        model.finishEditingText()
        model.run("type.create", ["x": 50, "y": 260, "text": "More", "size": 30])
        XCTAssertNotNil(model.editingText)
        XCTAssertNotNil(model.typeBox)
    }

    func testTextColourChangesTheSelectedTextInOneStepElseTheForeground() throws {
        let model = typed()
        let id = try XCTUnwrap(model.activeLayer?.id)
        model.loadTypeOptions(layer: id)
        XCTAssertEqual(model.typeColor, [0, 0, 0])
        let steps = model.history.past.count
        model.setTypeColor([1, 0, 0], edit: 1)
        model.setTypeColor([0, 0, 1], edit: 1)
        XCTAssertEqual(model.history.past.count, steps + 1, "one picker session, one step")
        model.loadTypeOptions(layer: id)
        XCTAssertEqual(model.typeColor, [0, 0, 1])

        model.run("layer.new.layer")
        model.setTypeColor([0, 1, 0], edit: 2)
        XCTAssertEqual(model.foreground.hex, "#00ff00", "new text takes the foreground")
        XCTAssertNil(model.typeBox, "no text layer selected")
    }

    func testTextBackgroundAddsALinkedBoxUnderTheTextInOneStep() throws {
        let model = typed()
        let id = try XCTUnwrap(model.activeLayer?.id)
        let count = model.layers.count
        let steps = model.history.past.count
        model.setTypeBackground(["color": "#ffff00"], edit: 1)
        model.setTypeBackground(["color": "#00ffff"], edit: 1)
        XCTAssertEqual(model.history.past.count, steps + 1, "one picker session, one step")
        XCTAssertEqual(model.layers.count, count + 1)
        XCTAssertEqual(model.activeLayer?.id, id, "the text stays selected")
        XCTAssertEqual(model.typeBackground?.color, [0, 1, 1])

        model.setTypeBackground(["padding": 20, "radius": 0], edit: 2)
        model.typeBackground = nil
        model.loadTypeOptions(layer: id)
        let bg = try XCTUnwrap(model.typeBackground)
        XCTAssertEqual(bg.padding, 20, accuracy: 0.5)
        XCTAssertEqual(bg.radius, 0, "square corners")
        XCTAssertEqual(bg.color, [0, 1, 1], "the colour stays")

        model.removeTypeBackground()
        XCTAssertEqual(model.layers.count, count)
        model.loadTypeOptions(layer: id)
        XCTAssertNil(model.typeBackground)
    }

    func testEmojiStickerPlacesTheFirstEmojiAndOpensFreeTransform() throws {
        XCTAssertEqual(EditorModel.firstEmoji("ab👍🏽c"), "👍🏽", "with its skin tone")
        XCTAssertEqual(EditorModel.firstEmoji("👨‍👩‍👧"), "👨‍👩‍👧")
        XCTAssertNil(EditorModel.firstEmoji("abc 123"))
        XCTAssertEqual(EditorModel.stickerSide(width: 6000, height: 4000), 1024)
        XCTAssertEqual(EditorModel.stickerSide(width: 90, height: 90), 64)

        let model = makeModel(width: 600, height: 300)
        model.emojiSticker(at: Point(x: 450, y: 100))
        let prompt = try XCTUnwrap(model.prompt)
        XCTAssertTrue(prompt.emoji)
        let count = model.layerCount
        prompt.done("hello")
        XCTAssertEqual(model.layerCount, count, "no emoji: nothing placed")
        prompt.done("🤠")
        let placed = expectation(description: "placed")
        Task { while model.transform == nil { try? await Task.sleep(for: .milliseconds(20)) }; placed.fulfill() }
        wait(for: [placed], timeout: 10)
        let t = try XCTUnwrap(model.transform, "Free Transform to move and size it")
        XCTAssertEqual(t.center.x + t.dx, 450, accuracy: 1, "centred where the tool was tapped")
        XCTAssertEqual(t.center.y + t.dy, 100, accuracy: 1)
        model.commitPending()
        let b = try XCTUnwrap(model.activeLayer?.bounds)
        XCTAssertGreaterThan(b[2], 40, "drawn, not empty")
    }

    func testTheBackgroundSwitchAddsAWhiteBoxQuickly() throws {
        let model = typed()
        let start = Date()
        model.setTypeBackground([:], edit: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(model.typeBackground?.color, [1, 1, 1])
        XCTAssertNil(model.toast)
    }

    func testTextTurnsByQuarterTurnsAndTypedAngles() throws {
        let model = typed()
        XCTAssertEqual(try XCTUnwrap(model.typeAngle), 0, accuracy: 0.01)
        model.rotateText(by: 90)
        XCTAssertEqual(try XCTUnwrap(model.typeAngle), 90, accuracy: 0.01)
        model.rotateText(by: -180)
        XCTAssertEqual(try XCTUnwrap(model.typeAngle), 270, accuracy: 0.01, "-90 reads 270")
        let steps = model.history.past.count
        model.setTextAngle(30, key: "a")
        model.setTextAngle(45, key: "a")
        XCTAssertEqual(try XCTUnwrap(model.typeAngle), 45, accuracy: 0.05)
        XCTAssertEqual(model.history.past.count, steps + 1, "typing is one step")
    }
}
