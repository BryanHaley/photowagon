import XCTest

/// Develop: opening a photo into Develop (File Handling's setting), Auto, Done keeping the
/// settings for next time, white balance, Open as Object, and changing the live filter later with
/// a profile, Effects, Curve, Color Mixer and a snapshot. See `docs/ios-walkthroughs/develop.md`
/// for each step and where it lives in the app.
final class DevelopTests: WalkthroughTestCase {
    func value(_ key: String) -> String { app.descendants(matching: .any)["raw.\(key).name"].firstMatch.value as? String ?? "" }

    /// Open a Develop panel (they start closed, but Light).
    func panel(_ name: String) {
        let header = show(app.buttons["raw.panel.\(name)"].firstMatch, "the \(name) panel")
        header.tap()
    }

    var develop: [String: Any] {
        let f = (layer(named: topName)?["smartFilters"] as? [[String: Any]] ?? []).first { $0["command"] as? String == "filter.cameraRaw" }
        return f?["params"] as? [String: Any] ?? [:]
    }

    func reopenDevelop() {
        app.buttons["layers"].tap()
        let row = show(app.descendants(matching: .any)["filter.\(topName).Develop"].firstMatch, "the Develop filter")
        row.doubleTap()
        if !app.buttons["raw.ok"].waitForExistence(timeout: 4) { row.doubleTap() }
        XCTAssert(app.buttons["raw.ok"].waitForExistence(timeout: 5), "Develop again")
    }

    func testDevelop() {
        step("Home › Preferences: File Handling, Open JPEG and HEIC in Develop") {
            XCTAssert(app.buttons["home.preferences"].waitForExistence(timeout: 10))
            app.buttons["home.preferences"].tap()
            flip("prefs.developJPEG")
            XCTAssertEqual(app.switches["prefs.developJPEG"].value as? String, "1")
            closeSheet()
        }

        var original: [Double] = []
        // The preview fits the photo's height, so a pick 0.9 down its middle lands about here.
        let sand = [770, 780, 830, 840]
        var sandBefore: [Double] = []
        var auto = ""
        step("Open the photo: it opens in Develop. Auto sets the Light sliders") {
            openSample("seaside")
            XCTAssert(app.buttons["raw.open"].waitForExistence(timeout: 10), "Develop, with Open")
            original = stats().mean
            sandBefore = stats(sand).mean
            XCTAssertEqual(value("exposure"), "0.00")
            app.buttons["raw.auto"].tap()
            waitIdle()
            auto = value("exposure")
            XCTAssertNotEqual(auto, "0.00", "Auto moved Exposure")
            XCTAssertNotEqual(stats().mean[1], original[1], accuracy: 0.002, "and the preview shows it")
        }

        step("⋯ › Done: the photo closes") {
            pick(menu: "raw.more", "Done (Keep Settings, Don't Open)")
            XCTAssert(app.buttons["home.open"].waitForExistence(timeout: 10), "the photo closed")
        }

        step("Open it again: the settings are back. Color › White Balance Auto, then the White Balance Tool on the preview") {
            openSample("seaside")
            XCTAssert(app.buttons["raw.open"].waitForExistence(timeout: 10))
            XCTAssertEqual(value("exposure"), auto, "kept from Done")
            panel("Color")
            pick(app.buttons["raw.whiteBalance"], "Auto")
            let balanced = value("temperature")
            XCTAssertNotEqual(balanced, "0", "a balance from the photo's near-gray parts")
            app.buttons["raw.wbPicker"].tap()
            let preview = app.descendants(matching: .any)["preview.pick"].firstMatch
            XCTAssert(preview.waitForExistence(timeout: 5))
            // The pale sand at the bottom.
            preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).press(forDuration: 0.6)
            waitIdle()
            XCTAssertNotEqual(value("temperature"), balanced, "picked from the sand")
        }

        step("Hold Open › Open as Object: an embedded layer with Develop as its live filter") {
            let open = app.buttons["raw.open"]
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: open.frame.midX, dy: open.frame.midY)).press(forDuration: 1.2)
            let item = app.buttons["Open as Object"].firstMatch
            XCTAssert(item.waitForExistence(timeout: 5))
            item.tap()
            waitIdle()
            noErrorToast()
            XCTAssertNotEqual(develop["temperature"] as? Double ?? 0, 0, "the white balance is in the filter")
            XCTAssertNotEqual(stats().mean[2], original[2], accuracy: 0.005)
            let spot = stats(sand).mean
            XCTAssertLessThan(abs(spot[0] - spot[2]), abs(sandBefore[0] - sandBefore[2]) / 2, "the picked sand nearer gray: \(sandBefore) → \(spot)")
        }

        step("Double-tap the Develop filter: Profile Monochrome, Effects › Vignette") {
            reopenDevelop()
            pick(app.buttons["raw.profile"], "Monochrome")
            panel("Effects")
            let vignette = show(app.sliders["raw.vignetteAmount"].firstMatch, "Vignette")
            vignette.adjust(toNormalizedSliderPosition: 0.15)
            XCTAssertLessThan(Int(value("vignetteAmount")) ?? 0, -40)
        }

        step("OK: gray, with darker corners") {
            app.buttons["raw.ok"].tap()
            waitIdle()
            let m = stats([700, 400, 900, 500]).mean
            XCTAssertEqual(m[0], m[2], accuracy: 0.01, "gray")
            XCTAssertLessThan(stats([0, 0, 100, 100]).mean[1], stats([750, 400, 850, 500]).mean[1], "corners darkened")
            XCTAssertEqual(develop["convertToGrayscale"] as? Bool, true)
        }

        step("Develop again: Curve, the middle raised") {
            reopenDevelop()
            panel("Curve")
            let graph = show(app.descendants(matching: .any)["curves.graph"].firstMatch, "the curve")
            graph.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: graph.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }

        step("Color Mixer › Saturation, Blue up") {
            panel("Color Mixer")
            app.buttons["Saturation"].firstMatch.tap()
            show(app.sliders["raw.hslSat.5"].firstMatch, "Blue").adjust(toNormalizedSliderPosition: 0.9)
        }

        step("OK: the curve and the mixer are in the filter") {
            app.buttons["raw.ok"].tap()
            waitIdle()
            XCTAssertEqual((develop["pointCurve"] as? [Any])?.count, 3, "a point added to the curve")
            XCTAssertGreaterThan((develop["hslSat"] as? [Double])?[5] ?? 0, 50)
        }

        step("Develop again: Save Snapshot, … › Reset to Default") {
            reopenDevelop()
            show(app.buttons["raw.saveSnapshot"].firstMatch, "Save Snapshot").tap()
            let alert = app.alerts["Save Snapshot"]
            XCTAssert(alert.waitForExistence(timeout: 5))
            alert.textFields.firstMatch.typeText("mono")
            alert.buttons["Save"].tap()
            pick(menu: "raw.more", "Reset to Default")
            let profile = { self.show(self.app.buttons["raw.profile"].firstMatch, "Profile").label }
            XCTAssert(profile().contains("Color"), profile())
        }

        step("Tap the snapshot: it all comes back") {
            let profile = { self.show(self.app.buttons["raw.profile"].firstMatch, "Profile").label }
            show(app.buttons["raw.snapshot.mono"].firstMatch, "the snapshot").tap()
            XCTAssert(profile().contains("Monochrome"), profile())
        }

        step("OK: the snapshot is kept in the filter") {
            app.buttons["raw.ok"].tap()
            waitIdle()
            XCTAssertEqual(develop["convertToGrayscale"] as? Bool, true)
            XCTAssertEqual((develop["__snapshots"] as? [[String: Any]])?.first?["name"] as? String, "mono", "kept in the filter")
        }
    }
}
