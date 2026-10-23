import XCTest

/// Selections: the Marquee's Feather and Anti-alias, Select › Modify, saving and loading a
/// selection, a mask back into a selection, the Polygonal Lasso's last point, and Quick
/// Selection's Sample All Layers. See `docs/ios-walkthroughs/selections.md` for each step and
/// where it lives in the app.
final class SelectionsTests: WalkthroughTestCase {
    var selection: [String: Any] { probe("document.stats", ["of": "selection"]) }
    var soft: Double { selection["soft"] as? Double ?? -1 }
    var bounds: [Double] { (inspect["selectionBounds"] as? [NSNumber])?.map(\.doubleValue) ?? [] }

    func testSelections() {
        var (w, h) = (1600.0, 900.0)
        step("Open the photo; Rectangular Marquee with Feather 10 px: a soft-edged selection") {
            openSample("seaside")
            (w, h) = docSize
            tool(group: "Rectangular Marquee", pick: "Rectangular Marquee")
            replace(app.textFields["option.feather"], with: "10\n")
            drag(doc: (w * 0.3, h * 0.3), to: (w * 0.6, h * 0.7))
            waitIdle()
            XCTAssertGreaterThan(soft, 0.02, "feathered edge")
        }

        step("Elliptical Marquee, Feather 0, Anti-alias off: every pixel in or out") {
            app.buttons["Deselect"].firstMatch.tap()
            tool(group: "Rectangular Marquee", pick: "Elliptical Marquee")
            replace(app.textFields["option.feather"], with: "0\n")
            app.buttons["Anti-alias"].tap()
            drag(doc: (w * 0.3, h * 0.3), to: (w * 0.6, h * 0.7))
            waitIdle()
            XCTAssertEqual(soft, 0, accuracy: 0.0001, "a hard edge")
        }

        var oval: [Double] = []
        step("Select › Modify › Expand 20 px: a bigger selection") {
            let before = bounds
            menu("Select", "Modify", "Expand…")
            replace(app.textFields["settings.radius"], with: "20")
            app.buttons["settings.run"].tap()
            waitIdle()
            oval = bounds
            XCTAssert(before.count == 4 && oval.count == 4 && oval[2] >= before[2] + 30, "\(before) → \(oval)")
        }

        step("Select › Save Selection… as oval, Deselect, Select › Load Selection › oval: it comes back") {
            menu("Select", "Save Selection…")
            replace(app.textFields["settings.name"], with: "oval")
            app.buttons["settings.run"].tap()
            waitIdle()
            menu("Select", "Deselect")
            XCTAssertEqual(inspect["hasSelection"] as? Bool, false)
            menu("Select", "Load Selection", "oval")
            waitIdle()
            XCTAssertEqual(bounds, oval, "the same selection")
        }

        step("The mask button, then hold the mask › Load as Selection: the mask's shape selected again") {
            app.buttons["layers"].tap()
            app.buttons["layer.lock.Background"].tap()
            app.buttons["layers.mask"].tap()
            waitIdle()
            XCTAssertEqual(inspect["hasSelection"] as? Bool, false, "the mask took the selection")
            let thumb = show(app.descendants(matching: .any)["layer.mask.Layer 0"].firstMatch, "the mask")
            for _ in 0..<3 {
                thumb.press(forDuration: 1.0)
                if app.buttons["Load as Selection"].waitForExistence(timeout: 3) { break }
            }
            Thread.sleep(forTimeInterval: 0.4)
            app.buttons["Load as Selection"].tap()
            waitIdle()
            XCTAssertEqual(bounds, oval)
            closeSheet()
            menu("Select", "Deselect")
        }

        step("Polygonal Lasso: a wrong point, Undo Last Point, then close the shape") {
            tool(group: "Lasso", pick: "Polygonal Lasso")
            for (x, y) in [(0.1, 0.1), (0.3, 0.1), (0.9, 0.9)] { at(w * x, h * y).tap() }
            app.buttons["Undo Last Point"].tap()
            for (x, y) in [(0.3, 0.3), (0.1, 0.3), (0.1, 0.1)] { at(w * x, h * y).tap() }
            if app.buttons["Commit"].exists { app.buttons["Commit"].tap() }
            waitIdle()
            let b = bounds
            XCTAssert(b.count == 4 && b[0] + b[2] < w * 0.35 && b[1] + b[3] < h * 0.35, "the wrong point is gone: \(b)")
            app.buttons["Deselect"].firstMatch.tap()
        }

        step("A new empty layer; Quick Selection with Sample All Layers on: it sees the photo below") {
            app.buttons["layers"].tap()
            app.buttons["layers.new"].tap()
            waitIdle()
            closeSheet()
            tool(group: "Object Selection", pick: "Quick Selection")
            app.buttons["Sample All Layers"].tap()
            drag(doc: (w * 0.56, h * 0.5), to: (w * 0.58, h * 0.7))
            XCTAssert(app.buttons["Deselect"].waitForExistence(timeout: 30), "a selection on the empty layer")
            XCTAssertEqual(inspect["hasSelection"] as? Bool, true)
        }
    }
}
