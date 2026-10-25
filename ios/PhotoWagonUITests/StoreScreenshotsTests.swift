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
        openSample("wander")
        step("layers-canvas") { waitIdle() }
        step("layers") {
            app.buttons["layers"].tap()
            XCTAssert(app.buttons["layers.menu"].waitForExistence(timeout: 5))
            expandSheet()
        }
    }

    func test4Develop() {
        openSample("balloon-sunset")
        menu("Filter", "Develop…")
        XCTAssert(app.buttons["raw.ok"].waitForExistence(timeout: 10))
        let light = app.buttons["raw.panel.Light"]
        bringToTop(light)
        // A real edit: brighter, more contrast, highlights held back, shadows opened up.
        for (key, value, range) in [("exposure", 0.35, 5.0), ("contrast", 22, 100), ("highlights", -45, 100), ("shadows", 38, 100), ("whites", 14, 100), ("blacks", -20, 100)] {
            app.sliders["raw.\(key)"].slide(to: CGFloat((value + range) / (2 * range)))
        }
        let curve = app.buttons["raw.panel.Curve"]
        bringToTop(curve)
        curve.tap()
        let graph = app.descendants(matching: .any)["curves.graph"]
        bringToTop(curve)
        XCTAssert(graph.waitForExistence(timeout: 5))
        step("develop-curve") {
            // A gentle S: shadows down, highlights up.
            for (x, y, dy) in [(0.27, 0.73, 0.06), (0.73, 0.27, -0.06)] {
                let from = graph.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
                from.press(forDuration: 0.05, thenDragTo: graph.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y + dy)), withVelocity: .slow, thenHoldForDuration: 0.1)
            }
            sleep(2)
        }
        step("develop") {
            bringToTop(light, back: true)
            sleep(2)
        }
    }

    /// Scrolls Develop's settings until `element` sits just under the preview, looking further
    /// down the list (or back up) while it isn't built yet.
    private func bringToTop(_ element: XCUIElement, back: Bool = false) {
        let form = app.collectionViews.firstMatch
        let target = form.frame.minY + 24
        for _ in 0..<12 {
            let dy = element.exists ? element.frame.midY - target : (back ? -1 : 1) * form.frame.height * 0.5
            if abs(dy) < 12 { return }
            let step = max(min(dy, form.frame.height * 0.6), -form.frame.height * 0.6)
            // In the left margin, clear of the sliders.
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: step > 0 ? 0.8 : 0.2))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -step)), withVelocity: .slow, thenHoldForDuration: 0.4)
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
