import XCTest

/// The Brush: its mode, Flow and Smoothing, Brush Settings (spacing, Shape Dynamics,
/// Scattering) saved as a new preset, Pressure for Size, painting symmetry, Define Brush Preset,
/// and the Apple Pencil preferences. See `docs/ios-walkthroughs/brush.md` for each step and where
/// it lives in the app.
final class BrushTests: WalkthroughTestCase {
    var brushJSON: [String: Any] { probe("brush.get") }
    func get(_ path: String) -> Any? { path.split(separator: ".").reduce(brushJSON as Any?) { ($0 as? [String: Any])?[String($1)] } }
    var presetNames: [String] { (probe("brush.presets.list")["presets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
    var top: String { topName }

    /// The bar's "…" › `path` (a phone keeps Mode, the pressure buttons and Symmetry there).
    func more(_ path: String...) {
        for (i, name) in path.enumerated() {
            let item = app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            for _ in 0..<3 where !item.exists {
                // A long submenu opens at its checked item; from the bottom bar it runs upward.
                if i == 0 { tapAt(app.buttons["brush.more"]) } else { app.collectionViews.element(boundBy: max(app.collectionViews.count - 1, 0)).swipeUp() }
                _ = item.waitForExistence(timeout: 3)
            }
            XCTAssert(item.exists, "… › \(name)")
            item.tap()
        }
    }

    func testBrush() {
        step("Open the photo, a new layer; Brush › Mode Difference in white: paint, then paint over it again") {
            openSample("seaside")
            newLayer()
            brush("Hard Round", size: 0.3)
            foreground(black: false)
            more("Mode", "Difference")
            XCTAssertEqual(get("mode") as? String, "Difference")
            drag(doc: (300, 300), to: (900, 300))
            waitIdle()
            XCTAssertGreaterThan(stats([500, 290, 700, 310], of: "pixels", layer: top).mean[0], 0.9, "white on the empty layer")
            drag(doc: (300, 300), to: (900, 300))
            waitIdle()
            let m = stats([500, 290, 700, 310], of: "pixels", layer: top).mean
            XCTAssertLessThan(m[0], 0.1, "white minus white: black \(m)")
        }

        step("… › Mode › Normal; … › Brush Settings…: Flow 10%, Smoothing about half") {
            more("Mode", "Normal")
            XCTAssertEqual(get("mode") as? String, "Normal")
            more("Brush Settings")
            XCTAssert(app.descendants(matching: .any)["brushSettings.preview"].waitForExistence(timeout: 5), "the stroke preview")
            show(app.sliders["brushSettings.flow"].firstMatch, "Flow").adjust(toNormalizedSliderPosition: 0.1)
            show(app.sliders["brushSettings.smoothing.amount"].firstMatch, "Smoothing").adjust(toNormalizedSliderPosition: 0.5)
            waitIdle()
            XCTAssertEqual((get("flow") as? Double) ?? 0, 0.1, accuracy: 0.03)
            XCTAssertEqual((get("smoothing.amount") as? Double) ?? 0, 0.5, accuracy: 0.05)
        }

        step("Brush Settings: Shape Dynamics › Size Jitter, Control Pen Pressure; Scattering › Count") {
            flip("brushSettings.shapeDynamics")
            show(app.sliders["brushSettings.shapeDynamics.size.jitter"].firstMatch, "Size Jitter").adjust(toNormalizedSliderPosition: 0.8)
            pick(show(app.buttons["brushSettings.shapeDynamics.size.control"].firstMatch, "Control"), "Pen Pressure")
            flip("brushSettings.scattering")
            // A drag while the list still coasts is lost: once more if nothing changed.
            for _ in 0..<2 where (get("scattering.count") as? Int ?? 1) <= 1 {
                show(app.sliders["brushSettings.scattering.count"].firstMatch, "Count").adjust(toNormalizedSliderPosition: 0.3)
                waitIdle()
            }
            XCTAssertEqual(get("shapeDynamics.enabled") as? Bool, true)
            XCTAssertGreaterThan((get("shapeDynamics.size.jitter") as? Double) ?? 0, 0.6)
            XCTAssertEqual(get("shapeDynamics.size.control") as? String, "penPressure")
            XCTAssertGreaterThan((get("scattering.count") as? Int) ?? 0, 1)
        }

        step("New Brush Preset…: ‘dust’, with tool settings") {
            show(app.buttons["brushSettings.newPreset"].firstMatch, "New Brush Preset").tap()
            let alert = app.alerts["New Brush Preset"]
            XCTAssert(alert.waitForExistence(timeout: 5))
            alert.textFields.firstMatch.typeText("dust")
            alert.buttons["OK"].tap()
            closeSheet()
            XCTAssert(presetNames.contains("dust"))
        }

        step("… › Brush Angle…: Turn 15° Clockwise, then drag the dial straight up") {
            more("Brush Angle")
            let right = app.buttons["brushAngle.right"].firstMatch
            XCTAssert(right.waitForExistence(timeout: 5), "the dial")
            let start = (get("angle") as? Double) ?? 0
            right.tap()
            XCTAssertEqual((get("angle") as? Double) ?? 0, BrushAngleWrap.wrapped(start - 15), accuracy: 0.5)
            let dial = app.descendants(matching: .any)["brushAngle.dial"].firstMatch
            dial.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: dial.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
            XCTAssertEqual((get("angle") as? Double) ?? 0, 90, accuracy: 3, "up: 90° anticlockwise")
        }

        step("Pressure for Size on; Symmetry › Vertical: one stroke paints its mirror too") {
            // Close the dial.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            tool(group: "Brush", pick: "Brush")
            brushTip("General", "Hard Round")
            more("Pressure for Size")
            XCTAssertEqual(get("pressureSize") as? Bool, true)
            more("Symmetry", "Vertical")
            XCTAssertEqual((probe("document.inspect")["symmetry"] as? [String: Any])?["mode"] as? String, "vertical")
            drag(doc: (200, 600), to: (400, 600))
            waitIdle()
            // Flow is still 10%: a light stroke, but there.
            XCTAssertGreaterThan(stats([1250, 590, 1350, 610], of: "pixels", layer: top).mean[3], 0.05, "the mirror image across the middle")
            XCTAssertLessThan(stats([1250, 690, 1350, 710], of: "pixels", layer: top).mean[3], 0.01, "only where it mirrors")
            more("Symmetry", "Off")
        }

        step("Rectangular Marquee round the black stroke, Edit › Define Brush Preset…: it's a new brush tip") {
            tool(group: "Rectangular Marquee", pick: "Rectangular Marquee")
            drag(doc: (250, 270), to: (950, 330))
            menu("Edit", "Define Brush Preset…")
            let alert = app.alerts["Brush Name"]
            XCTAssert(alert.waitForExistence(timeout: 5))
            alert.textFields.firstMatch.typeText("stroke")
            alert.buttons["OK"].tap()
            waitIdle()
            noErrorToast()
            XCTAssert(presetNames.contains("stroke"), "\(presetNames.suffix(3))")
        }

        step("Edit › Preferences › General…: Apple Pencil, Double-Tap › Switch to Eraser, Only Apple Pencil Paints") {
            menu("Edit", "Preferences", "General…")
            pick(show(app.buttons["prefs.pencilTap"].firstMatch, "Double-Tap"), "Switch to Eraser")
            XCTAssert(app.buttons["prefs.pencilTap"].firstMatch.label.contains("Switch to Eraser"))
            flip("prefs.pencilOnly")
            XCTAssertEqual(app.switches["prefs.pencilOnly"].firstMatch.value as? String, "1")
        }
    }
}

/// −180…180, as the dial keeps the angle.
enum BrushAngleWrap {
    static func wrapped(_ a: Double) -> Double {
        let w = (a + 180).truncatingRemainder(dividingBy: 360)
        return (w < 0 ? w + 360 : w) - 180
    }
}
