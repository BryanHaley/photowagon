import XCTest
@testable import PhotoWagon

/// Apple Pencil: double-tap and squeeze actions, painting with the Pencil only, its pressure
/// response, and samples held for their final pressure.
@MainActor
final class PencilTests: XCTestCase {
    func testDoubleTapAndSqueezeRunTheirActions() {
        XCTAssertEqual(PencilAction.from(.switchEraser), .eraser)
        XCTAssertEqual(PencilAction.from(.showColorPalette), .colors)
        XCTAssertEqual(PencilAction.from(.ignore), .off)
        let model = makeModel(width: 100, height: 100)
        XCTAssertEqual(model.resolve(.system, system: .switchPrevious), .previousTool, "As in Settings")
        XCTAssertEqual(model.resolve(.undo, system: .switchEraser), .undo, "our own choice wins")

        model.tool = .smudge
        model.perform(.eraser, at: nil)
        XCTAssertEqual(model.tool, .eraser)
        model.perform(.eraser, at: nil)
        XCTAssertEqual(model.tool, .smudge, "back to the tool before")
        model.tool = .brush
        model.perform(.previousTool, at: nil)
        XCTAssertEqual(model.tool, .smudge)

        model.perform(.palette, at: CGPoint(x: 50, y: 60))
        XCTAssertEqual(model.pencilPalette, CGPoint(x: 50, y: 60))

        model.run("edit.fill")
        let steps = model.historyNames.count
        model.perform(.undo, at: nil)
        XCTAssertEqual(model.historyNames.count, steps - 1)
    }

    func testOnlyThePencilPaintsWhenSet() {
        XCTAssert(EditorModel.fingerPans(.direct, tool: .brush, pencilOnly: true))
        XCTAssertFalse(EditorModel.fingerPans(.pencil, tool: .brush, pencilOnly: true))
        XCTAssertFalse(EditorModel.fingerPans(.direct, tool: .brush, pencilOnly: false))
        XCTAssertFalse(EditorModel.fingerPans(.direct, tool: .marquee, pencilOnly: true), "selection tools still take a finger")
    }

    func testPressurePresetsSetTheEngineCurve() {
        let model = makeModel()
        XCTAssertEqual(model.pencilPressure, .normal)
        model.pencilPressure = .firm
        XCTAssertEqual(model.pencilPressure, .firm)
        model.setPref("tools.pressureCurve", [[0, 0], [0.5, 0.9], [1, 1]])
        XCTAssertNil(model.pencilPressure, "a curve of your own")
    }

    func testSamplesWaitForTheirFinalPressure() {
        func p(_ x: Double) -> StrokePoint { StrokePoint(x: x, y: 0, pressure: 0.2, tiltX: 0, tiltY: 0, rotation: 0, timeMs: 0) }
        var q = PendingPoints()
        q.append(p(1))
        q.append(p(2), update: 7, time: 10)
        q.append(p(3))
        XCTAssertEqual(q.takeReady(now: 10.01).map(\.x), [1], "held at the estimate")
        q.update(7, pressure: 0.9, tilt: (10, 20), rotation: 30)
        let ready = q.takeReady(now: 10.02)
        XCTAssertEqual(ready.map(\.x), [2, 3])
        XCTAssertEqual(ready.first?.pressure, 0.9)
        XCTAssertEqual(ready.first?.rotation, 30)

        q.append(p(4), update: 8, time: 20)
        XCTAssertEqual(q.takeReady(now: 20.1).map(\.x), [4], "not held for ever")
        q.update(8, pressure: 1, tilt: (0, 0), rotation: 0)
        XCTAssert(q.isEmpty)
    }

    func testThePreciseCursorIsACrossOnly() {
        let outline = CanvasUIView.cursorPath(at: CGPoint(x: 100, y: 100), radius: 40, precise: false).boundingBox
        XCTAssertEqual(outline.width, 80, accuracy: 0.5)
        let cross = CanvasUIView.cursorPath(at: CGPoint(x: 100, y: 100), radius: 40, precise: true).boundingBox
        XCTAssertEqual(cross.width, 18, accuracy: 0.5)
    }
}
