import XCTest

/// Omega part 2 (plan/omega-e2e.md, section 8): what only a real iPhone or iPad can check. Run by
/// `cargo xtask omega device`, which first copies `subject.jpg`, `seaside.jpg` and a 24 MP
/// `big.jpg` into the app's Documents. The app shows its state on a hidden element
/// (`-omegaDeviceProbe`), since a test on a device can't read the app's files.
final class DeviceOmegaTests: WalkthroughTestCase {
    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-omegaDeviceProbe", "YES", "-skipTutorial", "YES"]
        app.launch()
    }

    private var state: [String: Any] {
        let label = app.otherElements["omega.state"].firstMatch.label
        return (try? JSONSerialization.jsonObject(with: Data(label.utf8)) as? [String: Any]) ?? [:]
    }

    private func waitIdle(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        Thread.sleep(forTimeInterval: 1)
        while (state["busy"] as? Bool) == true, Date() < end { Thread.sleep(forTimeInterval: 0.5) }
    }

    private func openFile(_ name: String) {
        let file = app.buttons["file.\(name)"]
        for _ in 0..<3 where !file.exists {
            openFromHome()
            _ = file.waitForExistence(timeout: 5)
        }
        pickFile(name)
        waitForCanvas()
    }

    private func noError() {
        if let t = state["toast"] as? String { XCTAssertFalse(t.lowercased().contains("error") || t.contains("panic"), t) }
    }

    func testSelectSubjectWithVision() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("a real device only")
        #endif
        openFile("subject")
        menu("Select", "Subject")
        waitIdle(60)
        XCTAssertEqual(state["selection"] as? Bool, true, "a subject is selected")
        noError()
    }

    func testRemoveBackground() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("a real device only")
        #endif
        openFile("seaside")
        let history = state["history"] as? Int ?? 0
        menu("Window", "Properties")
        let button = app.buttons["Remove Background"].firstMatch
        XCTAssert(button.waitForExistence(timeout: 5), "Properties › Remove Background")
        button.tap()
        waitIdle(60)
        XCTAssertGreaterThan(state["history"] as? Int ?? 0, history, "a history step")
        noError()
    }

    /// The first run downloads the model, so it gets five minutes.
    func testAIRemoveASelection() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("a real device only")
        #endif
        openFile("seaside")
        tool(group: "Rectangular Marquee", pick: nil)
        drag(from: (0.4, 0.45), to: (0.55, 0.6))
        XCTAssertEqual(state["selection"] as? Bool, true, "a box is selected")
        tool(group: "Spot Repair Brush", pick: "AI Remove")
        let history = state["history"] as? Int ?? 0
        let chip = app.buttons["Remove Selection"].firstMatch
        XCTAssert(chip.waitForExistence(timeout: 5), "Remove Selection")
        chip.tap()
        waitIdle(300)
        XCTAssertGreaterThan(state["history"] as? Int ?? 0, history, "the selection was filled")
        noError()
    }

    /// A 24 MP photo through a few heavy steps without the app being stopped for memory.
    func testBigPhotoSession() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("a real device only")
        #endif
        openFile("big")
        XCTAssertEqual(state["width"] as? Int, 6000)
        let history = state["history"] as? Int ?? 0
        for path in [["Image", "Adjustments", "Invert"], ["Filter", "Sharpen", "Sharpen"], ["Image", "Auto Tone"], ["Layer", "Duplicate Layer…"]] {
            menu(path: path)
            if app.navigationBars.firstMatch.waitForExistence(timeout: 2) { closeSheet() }
            waitIdle(120)
            XCTAssertEqual(app.state, .runningForeground, "still running after \(path.joined(separator: " › "))")
        }
        XCTAssertGreaterThan(state["history"] as? Int ?? 0, history + 2, "the steps were done")
        noError()
    }
}
