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
}
