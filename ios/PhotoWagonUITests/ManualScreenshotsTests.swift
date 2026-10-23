import XCTest

/// Pictures for Help › Manual: one step per picture, named for its file in ios/Manual/images.
/// Runs only with `TEST_RUNNER_MANUAL_SHOTS=1`; the pictures are cut down by ios/Manual/shots.sh.
final class ManualScreenshotsTests: WalkthroughTestCase {
    func testManualScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MANUAL_SHOTS"] == "1", "set TEST_RUNNER_MANUAL_SHOTS=1")
        let cancel = { self.app.buttons["Cancel"].firstMatch.tap() }
        let dismiss = { if self.app.buttons["Cancel"].firstMatch.exists { cancel() } else { self.closeSheet() } }

        step("home") { XCTAssert(app.buttons["home.open"].waitForExistence(timeout: 10)) }
        step("editor") { openSample("seaside") }
        step("tool-group") {
            app.buttons["group.Brush"].tap()
            XCTAssert(app.buttons["Pencil"].waitForExistence(timeout: 5))
        }
        step("options-bar") {
            app.buttons["group.Brush"].tap()
            waitIdle()
        }
        step("menu") {
            app.buttons["menu"].tap()
            XCTAssert(app.collectionViews.buttons["Filter"].waitForExistence(timeout: 5))
        }
        step("layers") {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            app.buttons["layers"].tap()
            XCTAssert(app.buttons["layers.menu"].waitForExistence(timeout: 5))
        }
        step("history") {
            closeSheet()
            drag(doc: (300, 200), to: (900, 250))
            waitIdle()
            app.buttons["history"].tap()
            XCTAssert(app.buttons["history.1"].waitForExistence(timeout: 5))
        }
        step("brush-settings") {
            closeSheet()
            app.buttons["undo"].tap()
            menu("Window", "Brush Settings")
            XCTAssert(app.descendants(matching: .any)["brushSettings.preview"].waitForExistence(timeout: 5))
        }
        step("filter-dialog") {
            closeSheet()
            menu("Filter", "Blur", "Gaussian Blur…")
            sleep(2)
        }
        step("adjustments") {
            cancel()
            menu("Image", "Adjustments", "Levels…")
            sleep(2)
        }
        step("develop") {
            cancel()
            menu("Filter", "Develop…")
            sleep(3)
        }
        step("selection") {
            cancel()
            tool(group: "Rectangular Marquee", pick: "Rectangular Marquee")
            drag(doc: (500, 250), to: (1100, 650))
            XCTAssert(app.buttons["Deselect"].waitForExistence(timeout: 5))
        }
        step("transform") {
            menu("Edit", "Free Transform")
            sleep(1)
        }
        step("type") {
            app.buttons["Cancel"].firstMatch.tap()
            app.buttons["Deselect"].firstMatch.tap()
            tool(group: "Horizontal Type", pick: "Horizontal Type")
            at(300, 200).tap()
            app.typeText("Hello")
            sleep(1)
        }
        step("ai-remove") {
            app.buttons["OK"].firstMatch.tap()
            if app.buttons["Commit"].waitForExistence(timeout: 2) { tapChip(app.buttons["Commit"]) }
            app.buttons["undo"].tap()
            tool(group: "Spot Repair Brush", pick: "AI Remove")
            waitIdle()
        }
        step("export") {
            menu("File", "Export", "Export As…")
            sleep(2)
        }
        step("layer-style") {
            dismiss()
            menu("Layer", "Layer Style", "Blending Options…")
            sleep(2)
        }
        step("preferences") {
            dismiss()
            menu("Edit", "Preferences", "General…")
            sleep(2)
        }
    }
}
