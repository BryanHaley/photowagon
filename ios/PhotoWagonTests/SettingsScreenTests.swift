import XCTest
@testable import PhotoWagon

/// The settings screens of their own: Curves' points and spline, Shear's curve, the plain form's
/// colours, and the small sums the screens show.
@MainActor
final class SettingsScreenTests: XCTestCase {
    func testCurveMatchesWhatTheEngineApplies() throws {
        let model = makeModel()
        model.newDocument(["width": 4, "height": 4, "background": "#646464"])
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 64, y: 40), CGPoint(x: 192, y: 220), CGPoint(x: 255, y: 255)]
        model.run("image.adjustments.curves", CurvesValues(curves: ["": points]).params(keys: [""]))
        let stats = try XCTUnwrap(model.query("document.stats", [:]) as? [String: Any])
        let mean = try XCTUnwrap(numbers(stats["mean"])?.first)
        XCTAssertEqual(mean * 255, CurvesValues.spline(points)[100], accuracy: 1.5)
        XCTAssertEqual(CurvesValues.spline(CurvesValues.identity), (0..<256).map(Double.init))
    }

    func testPointsStayInOrderAndWithinTheGraph() {
        var pts = CurvesValues.identity
        XCTAssertEqual(CurvesValues.insert(&pts, CGPoint(x: 100, y: 150)), 1)
        XCTAssertNil(CurvesValues.insert(&pts, CGPoint(x: 102, y: 10)), "too close to another point")
        CurvesValues.move(&pts, 1, to: CGPoint(x: 300, y: -20))
        XCTAssertEqual(pts[1], CGPoint(x: 254, y: 0), "stops before the white point, and at the bottom")
        CurvesValues.move(&pts, 0, to: CGPoint(x: 40, y: 10))
        XCTAssertEqual(pts[0], CGPoint(x: 40, y: 10))
        for x in stride(from: 110, to: 250, by: 10) { _ = CurvesValues.insert(&pts, CGPoint(x: x, y: x)) }
        XCTAssertEqual(pts.count, CurvesValues.maxPoints)
    }

    func testCurvesParamsRoundTripInBothModes() {
        var v = CurvesValues(curves: ["": [CGPoint(x: 0, y: 20), CGPoint(x: 255, y: 230)], "red": [CGPoint(x: 0, y: 0), CGPoint(x: 128, y: 160), CGPoint(x: 255, y: 255)]])
        var back = CurvesValues(v.params(keys: ["", "red", "green", "blue"]))
        XCTAssertEqual(back[""], v[""])
        XCTAssertEqual(back["red"], v["red"])
        XCTAssertEqual(back["green"], CurvesValues.identity)
        v.pencil = true
        v.maps[""] = CurvesValues.smooth((0..<256).map { $0 < 128 ? 0 : 255 })
        back = CurvesValues(v.params(keys: [""]))
        XCTAssertTrue(back.pencil)
        XCTAssertEqual(back.map("")[127], 127.5, accuracy: 30, "smoothed across the step")
        XCTAssertEqual(CurvesValues.points(fitting: back.map("")).count, 6)
    }

    func testAutoMethods() {
        // Blue-ish pixels from 40 to 200, one stray black and one white.
        var rgb = (0..<1000).map { i -> SIMD3<Float> in let v = Float(40 + i % 161); return SIMD3(v * 0.8, v * 0.9, v) }
        rgb += [SIMD3(0, 0, 0), SIMD3(255, 255, 255)]
        let px = AutoPixels(rgb: rgb)
        var o = AutoOptions()
        let per = px.auto(o, color: true)
        XCTAssertEqual(per.channels["blue"]?.black, 40, "0.1% clipped: the stray pixels don't count")
        XCTAssertEqual(per.channels["red"]?.white, 160)
        o.method = .monochromatic
        let mono = px.auto(o, color: true)
        XCTAssertEqual(Array(mono.channels.keys), [""], "the same for every channel")
        o.method = .darkLight
        o.shadows = 1
        let dl = px.auto(o, color: true)
        XCTAssertLessThan(dl.channels["red"]?.black ?? 255, dl.channels["blue"]?.black ?? 0, "the darkest color, not each channel's darkest")
        o = AutoOptions(method: .perChannel, snapNeutral: true)
        // Green lifted in the midtones only: stretching alone leaves the cast.
        let cast = (0..<512).map { i -> SIMD3<Float> in let v = Float(i % 256); return SIMD3(v, 255 * pow(v / 255, 0.8), v) }
        let snapped = AutoPixels(rgb: cast).auto(o, color: true)
        XCTAssertLessThan(snapped.channels["green"]?.gamma ?? 1, 0.95, "green's midtones come down")
        XCTAssertEqual(snapped.channels["red"]?.gamma ?? 0, 1.05, accuracy: 0.05)
        XCTAssertEqual(AutoPixels(rgb: rgb).auto(AutoOptions(), color: false).channels.keys.first, "", "not RGB: the composite")
        XCTAssertEqual(AutoPixels(rgb: []).auto(AutoOptions(), color: true).channels[""], .init(black: 0, white: 255))
    }

    func testAutoBecomesLevelsAndCurves() {
        let r = AutoPixels.Result(channels: ["red": .init(black: 20, white: 220, gamma: 2)])
        XCTAssertEqual(LevelsValues(auto: r)["red"], .init(inBlack: 20, gamma: 2, inWhite: 220))
        let curve = CurvesValues(auto: r)["red"]
        XCTAssertEqual(curve.count, 3)
        XCTAssertEqual(CurvesValues.spline(curve)[Int(curve[1].x)], 128, accuracy: 1)
    }

    func testClipStatsCountWhatComesOutBlackOrWhite() {
        var bins = [Int](repeating: 0, count: 256)
        bins[10] = 50
        bins[100] = 25
        bins[250] = 25
        var v = LevelsValues()
        v[""].inBlack = 20
        v[""].inWhite = 240
        let c = ClipStats(bins: bins, outputs: v.outputs(""))
        XCTAssertEqual(c.shadows, 50)
        XCTAssertEqual(c.highlights, 25)
        XCTAssertTrue(c.dark[10] && !c.dark[100] && c.light[250])
        XCTAssertEqual(c.text, "Shadows 50.0% · Highlights 25.0%")
    }

    func testClipOutlinesGoRoundTheClippedCells() {
        // A 2×1 block clipped in a 3×3 grid: its outline is 6 cell sides.
        let mask = [true, true, false, false, false, false, false, false, false]
        XCTAssertEqual(ClipOutline.edges(mask, width: 3, height: 3).count, 6)
        XCTAssertTrue(ClipOutline.edges([Bool](repeating: false, count: 4), width: 2, height: 2).isEmpty)
    }

    func testAutoOptionsAreSaved() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "tests.\(UUID().uuidString)"))
        XCTAssertEqual(AutoOptions.saved(d), AutoOptions())
        let o = AutoOptions(method: .darkLight, snapNeutral: true, shadows: 0.5, highlights: 1)
        o.save(d)
        XCTAssertEqual(AutoOptions.saved(d), o)
    }

    func testShearOffsetPassesThroughItsPoints() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0, y: 1)]
        XCTAssertEqual(ShearEditor.offset(pts, at: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ShearEditor.offset(pts, at: 0), 0)
        XCTAssertGreaterThan(ShearEditor.offset(pts, at: 0.25), 0.1)
        XCTAssertEqual(ShearEditor.offset(ShearEditor.straight, at: 0.7), 0)
    }

    func testColourFieldsAreLeftOutUntilPicked() {
        let fields = [ParamField(name: "color", kind: .color(options: [], value: "")),
                      ParamField(name: "extensionColor", kind: .color(options: ["background", "white"], value: "background"))]
        let d = CommandSettings.defaults(fields: fields, initial: [:])
        let p = CommandSettings.params(numbers: d.numbers, choices: d.choices, toggles: d.toggles, texts: d.texts)
        XCTAssertNil(p["color"])
        XCTAssertEqual(p["extensionColor"] as? String, "background")
        XCTAssertEqual(ColorRow.hex([1, 0.5, 0]), "#ff8000")
    }

    func testAnchorArrowsPointAwayFromTheAnchor() {
        XCTAssertEqual(AnchorGrid.symbol(0, anchor: 0), "circle.fill")
        XCTAssertEqual(AnchorGrid.symbol(1, anchor: 0), "arrow.right")
        XCTAssertEqual(AnchorGrid.symbol(4, anchor: 0), "arrow.down.right")
        XCTAssertEqual(AnchorGrid.symbol(8, anchor: 0), "", "too far for an arrow")
        XCTAssertEqual(AnchorGrid.symbol(1, anchor: 4), "arrow.up")
    }

    func testSmallSums() {
        XCTAssertEqual(ChannelMixerEditor.total([40, 40, 20, 50]), 100, "the constant isn't a source")
        XCTAssertEqual(ReplaceColorEditor.result("#ff0000", hue: 120, saturation: 0, lightness: 0), "#00ff00")
        XCTAssertEqual(ReplaceColorEditor.result("#ff0000", hue: 0, saturation: -100, lightness: 0), "#ffffff")
        XCTAssertEqual(ReplaceColorEditor.result("#808080", hue: 0, saturation: 0, lightness: -100), "#000000")
        XCTAssertEqual(PreviewPane.fitted(CGSize(width: 200, height: 100), in: CGSize(width: 100, height: 100)), CGRect(x: 0, y: 25, width: 100, height: 50))
    }
}
