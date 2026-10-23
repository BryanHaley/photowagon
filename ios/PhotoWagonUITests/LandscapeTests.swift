import XCTest

/// The workspace turned sideways: tools down the left, the options bar on top, and on iPad the
/// Layers sheet at full height.
final class LandscapeTests: WalkthroughTestCase {

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testLandscapeWorkspace() {
        step("Open a photo, turn the device sideways: tools down the left") {
            app.buttons["home.open"].tap()
            pickFile("beach")
            waitForCanvas()
            XCUIDevice.shared.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 1)
            let tools = app.scrollViews["toolbar"].firstMatch
            XCTAssert(tools.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(tools.frame.height, tools.frame.width * 2, "a column: \(tools.frame)")
            XCTAssertLessThan(tools.frame.midX, canvas.frame.minX + 1, "left of the canvas")
            XCTAssertGreaterThan(canvas.frame.height, app.windows.firstMatch.frame.height * 0.5, "the canvas has room: \(canvas.frame)")
        }

        step("Pick a tool and paint in landscape") {
            tool(group: "Brush", pick: "Brush")
            let before = stats([300, 300, 1100, 500]).mean
            drag(doc: (300, 400), to: (1100, 400))
            XCTAssertNotEqual(stats([300, 300, 1100, 500]).mean, before, "painted")
        }

        step("Layers opens with its rows in view") {
            app.buttons["layers"].tap()
            let row = app.descendants(matching: .any)["layer.Background"].firstMatch
            XCTAssert(row.waitForExistence(timeout: 5))
            // Inside the sheet, not clipped below it.
            let sheet = app.navigationBars["Layers"].firstMatch
            XCTAssert(sheet.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(row.frame.minY, sheet.frame.maxY)
            XCTAssertLessThan(row.frame.maxY, app.windows.firstMatch.frame.maxY - 20, "the Background row shows: \(row.frame)")
            XCTAssertGreaterThan(sheet.frame.width, app.windows.firstMatch.frame.width * 0.5, "a big sheet on iPad: \(sheet.frame)")
            closeSheet()
        }

        step("Back to portrait: tools along the bottom") {
            XCUIDevice.shared.orientation = .portrait
            Thread.sleep(forTimeInterval: 1)
            let tools = app.scrollViews["toolbar"].firstMatch
            XCTAssertGreaterThan(tools.frame.width, tools.frame.height * 2, "a row: \(tools.frame)")
            XCTAssertGreaterThan(tools.frame.minY, canvas.frame.maxY - 1, "below the canvas")
        }
    }
}
