import XCTest

/// The Remove tool: on a new layer with Sample All Layers, Remove After Each Stroke off with a
/// straight line and Commit, then on, over the boats. See `docs/ios-walkthroughs/remove-tool.md`
/// for each step and where it lives in the app.
final class RemoveToolTests: WalkthroughTestCase {
    func blue(_ rect: [Int], layer: String? = nil) -> Double {
        (layer == nil ? stats(rect) : stats(rect, of: "pixels", layer: layer)).mean.dropFirst(2).first ?? -1
    }

    /// High on the white boats, low on the blue sea and sky.
    func red(_ rect: [Int]) -> Double { stats(rect).mean.first ?? -1 }

    func testRemoveTool() {
        // The wire runs from (0, 150) to (1600, 250).
        let wire = [700, 186, 760, 206], sky = [700, 150, 760, 170]
        step("Open the photo, a new layer, then the Remove tool with Sample All Layers") {
            openSample("wire")
            app.buttons["layers"].tap()
            app.buttons["layers.new"].tap()
            waitIdle()
            XCTAssertEqual(layers.count, 2)
            closeSheet()
            tool(group: "Spot Repair Brush", pick: "Quick Fill")
            app.buttons["Sample All Layers"].tap()
            XCTAssertLessThan(blue(wire), blue(sky) - 0.05, "the wire darkens the sky")
        }

        step("Remove After Each Stroke off, Straight Line on: tap both ends of the wire, then Commit") {
            app.buttons["Remove After Each Stroke"].tap()
            app.buttons["Straight Line"].tap()
            at(8, 150).tap()
            at(1592, 250).tap()
            XCTAssert(app.buttons["Commit"].waitForExistence(timeout: 5), "waits for Commit")
            XCTAssertLessThan(blue(wire), blue(sky) - 0.05, "nothing removed yet")
            tapChip(app.buttons["Commit"])
            waitIdle()
            noErrorToast()
            XCTAssertEqual(blue(wire), blue(sky), accuracy: 0.03, "the wire is gone")
            XCTAssertLessThan(blue(wire, layer: "Background"), blue(sky, layer: "Background") - 0.05, "the photo below keeps it")
        }

        step("Remove After Each Stroke on: paint over the boats, each stroke removes on release") {
            app.buttons["Straight Line"].tap()
            app.buttons["Remove After Each Stroke"].tap()
            let hulls = [905, 396, 970, 408]
            XCTAssertGreaterThan(red(hulls), 0.5, "a white boat")
            drag(doc: (845, 300), to: (845, 410))
            waitIdle()
            drag(doc: (812, 402), to: (978, 402))
            waitIdle()
            noErrorToast()
            XCTAssertLessThan(red(hulls), 0.3, "the boats are gone")
        }
    }
}
