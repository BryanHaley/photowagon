import XCTest

/// Opening the ☰ menu must not bring up the on-screen keyboard.
final class MenuKeyboardTests: WalkthroughTestCase {
    func testMenuShowsNoKeyboard() {
        step("Open a photo, then ☰: the menu shows, no keyboard") {
            openSample("seaside")
            tapAt(app.buttons["menu"])
            XCTAssert(app.collectionViews.buttons["File"].waitForExistence(timeout: 5), "the menu opened")
            Thread.sleep(forTimeInterval: 1.5)
            XCTAssertEqual(app.keyboards.count, 0, "no keyboard over the menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)).tap()
        }
        step("Pick the Brush, paint, then ☰: still no keyboard") {
            tool(group: "Brush", pick: "Brush")
            drag(doc: (300, 300), to: (600, 400))
            tapAt(app.buttons["menu"])
            XCTAssert(app.collectionViews.buttons["File"].waitForExistence(timeout: 5), "the menu opened")
            Thread.sleep(forTimeInterval: 1.5)
            XCTAssertEqual(app.keyboards.count, 0, "no keyboard over the menu")
        }
    }
}
