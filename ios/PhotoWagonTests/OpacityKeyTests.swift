import XCTest
@testable import PhotoWagon

/// Number keys set opacity. A UI test can't type two keys close enough
/// together, so this hands the canvas the key presses with their times.
@MainActor
final class OpacityKeyTests: XCTestCase {
    func testOneDigitIsTensTwoQuickDigitsAreExact() throws {
        let model = EditorModel()
        model.run("file.new", ["width": 32, "height": 32])
        model.run("layer.new.layer")
        model.tool = .move
        let canvas = CanvasUIView(model: model)
        let opacity = { (model.query("document.inspect") as? [String: Any]).flatMap { ($0["layers"] as? [[String: Any]])?.first?["opacity"] as? Double } ?? -1 }
        canvas.opacityKey(4, shift: false, time: 10)
        XCTAssertEqual(opacity(), 0.4, accuracy: 0.001)
        canvas.opacityKey(7, shift: false, time: 20)
        canvas.opacityKey(4, shift: false, time: 20.3)
        XCTAssertEqual(opacity(), 0.74, accuracy: 0.001, "7 then 4 quickly")
        canvas.opacityKey(5, shift: false, time: 30)
        canvas.opacityKey(6, shift: false, time: 32)
        XCTAssertEqual(opacity(), 0.6, accuracy: 0.001, "6 on its own, later")
        canvas.opacityKey(0, shift: false, time: 40)
        XCTAssertEqual(opacity(), 1, accuracy: 0.001)
    }
}
