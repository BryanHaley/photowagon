import XCTest

/// Home's Back to Workspace, and copying a selection from one image into another with the
/// selection buttons.
final class ClipboardTests: WalkthroughTestCase {
    func testCopyIntoAnotherImage() {
        step("Open the seaside; Home has Back to Workspace") {
            openSample("seaside")
            goHome()
            XCTAssert(app.buttons["home.workspace"].exists)
            backToWorkspace()
        }

        step("Select, then Copy") {
            tool(group: "Rectangular Marquee", pick: "Rectangular Marquee")
            XCTAssert(app.buttons["Select All"].waitForExistence(timeout: 5), "Select All with no selection")
            drag(doc: (100, 100), to: (400, 300))
            XCTAssert(app.buttons["Deselect"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Paste"].exists, "nothing copied yet")
            tapChip(app.buttons["Copy"])
            XCTAssert(app.buttons["Paste"].waitForExistence(timeout: 5), "Paste once something is copied")
        }

        step("Open the bee, Paste: a new layer") {
            openSample("bee")
            XCTAssertEqual(layers.count, 1)
            tool(group: "Rectangular Marquee", pick: "Rectangular Marquee")
            tapChip(app.buttons["Paste"])
            waitIdle()
            XCTAssertEqual(layers.count, 2, "pasted from the seaside")
            noErrorToast()
        }
    }
}
