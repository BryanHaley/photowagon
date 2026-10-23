import XCTest

/// Pictures for the App Store page, one scene per test, with the photos in docs/store-page/photos
/// (kept locally, not in git). Runs only with `TEST_RUNNER_STORE_SHOTS=1`; docs/store-page/make.sh
/// frames them.
final class StoreScreenshotsTests: WalkthroughTestCase {
    override var samplesFolder: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/store-page/photos").standardized.path
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STORE_SHOTS"] == "1", "set TEST_RUNNER_STORE_SHOTS=1")
    }

    func test1Wagon() {
        step("wagon") { openSample("photo-wagon") }
    }

    func test2AIRemove() {
        openSample("balloons")
        // The three balloons in clear sky on the left.
        let balloons = [((20.0, 600.0), (235.0, 790.0)), ((2.0, 830.0), (235.0, 1215.0))]
        step("remove-before") { tool(group: "Rectangular Marquee", pick: "Rectangular Marquee") }
        step("remove-after") {
            for (n, (a, b)) in balloons.enumerated() {
                drag(doc: a, to: b)
                XCTAssert(app.buttons["Deselect"].waitForExistence(timeout: 5))
                tapChip(app.buttons["AI Remove"])
                let offer = app.alerts["Download AI Remove?"]
                if offer.waitForExistence(timeout: 3) { offer.buttons["aiRemove.download"].tap() }
                let done = expectation(for: NSPredicate { _, _ in ((self.inspect["history"] as? [String]) ?? []).filter { $0 == "AI Remove" }.count == n + 1 }, evaluatedWith: nil)
                wait(for: [done], timeout: 300)
                app.buttons["Deselect"].tap()
                waitIdle()
            }
        }
    }

    func test3Layers() {
        openSample("tulips")
        step("layers") {
            if UIDevice.current.userInterfaceIdiom == .pad {
                menu("Layer", "Duplicate Layer…")
                if app.buttons["OK"].waitForExistence(timeout: 3) { app.buttons["OK"].firstMatch.tap() }
            } else {
                tool(group: "Horizontal Type", pick: "Horizontal Type")
                at(500, 500).tap()
                app.typeText("Spring")
                app.buttons["OK"].firstMatch.tap()
                if app.buttons["Commit"].waitForExistence(timeout: 2) { tapChip(app.buttons["Commit"]) }
            }
            menu("Layer", "New Adjustment Layer", "Vibrance…")
            if app.buttons["OK"].waitForExistence(timeout: 3) { app.buttons["OK"].firstMatch.tap() }
            waitIdle()
            app.buttons["layers"].tap()
            XCTAssert(app.buttons["layers.menu"].waitForExistence(timeout: 5))
        }
    }

    func test4Develop() {
        openSample("balloon-sunset")
        step("develop") {
            menu("Filter", "Develop…")
            sleep(3)
        }
    }

    func test5Filters() {
        openSample("skyline-night")
        step("filters") {
            menu("Filter", "Filter Gallery…")
            sleep(3)
        }
    }

    func test6Editor() {
        openSample("alpine-lake")
        step("editor") {
            app.buttons["group.Brush"].tap()
            XCTAssert(app.buttons["Pencil"].waitForExistence(timeout: 5))
        }
    }

}
