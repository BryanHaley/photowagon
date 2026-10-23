import XCTest
@testable import PhotoWagon

/// Develop's settings, Auto and white balance, and opening a file into Develop.
@MainActor
final class DevelopSettingsTests: XCTestCase {
    func testSettingsRoundTripTheEngineParams() throws {
        var s = DevelopSettings()
        s["exposure"] = 1.234
        s["hslSat.3"] = 40
        s["vignetteMidpoint"] = 70
        s["contrast"] = 500
        s.setCurve("pointCurveRed", [CGPoint(x: 0, y: 0), CGPoint(x: 128, y: 160), CGPoint(x: 255, y: 255)])
        s.monochrome = true
        s.saveSnapshot("  first ")
        s["exposure"] = -1
        let p = s.params()
        XCTAssertEqual(p["exposure"] as? Double, -1)
        XCTAssertEqual(p["contrast"] as? Double, 100, "kept in range")
        XCTAssertEqual((p["hslSat"] as? [Double])?[3], 40)
        XCTAssertEqual((p["pointCurve"] as? [Any])?.count, 0, "a straight curve is sent empty")
        XCTAssertEqual(p["sharpenDetail"] as? Double, 25, "defaults are sent too")

        let back = DevelopSettings(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: p)) as? [String: Any]))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.snapshots.map(\.name), ["first"])

        var shown = back
        shown.restore(try XCTUnwrap(back.snapshots.first))
        XCTAssertEqual(shown["exposure"], 1.23, "the snapshot's settings")

        shown.hidden = ["Light", "Curve"]
        let off = shown.params()
        XCTAssertEqual(off["exposure"] as? Double, 0, "a panel turned off is left out")
        XCTAssertEqual((off["pointCurveRed"] as? [Any])?.count, 0)
        XCTAssertEqual((off["hslSat"] as? [Double])?[3], 40, "other panels stay")
    }

    func testPresetAmountAndResetToDefault() {
        var s = DevelopSettings()
        s["clarity"] = 30
        s.saveSnapshot("kept")
        s.apply(["contrast": 20, "vignetteMidpoint": 70], amount: 50)
        XCTAssertEqual(s["contrast"], 10)
        XCTAssertEqual(s["vignetteMidpoint"], 60, "scaled from the slider's default")
        XCTAssertEqual(s["clarity"], 0, "a preset sets every other slider back")
        s.reset()
        XCTAssertEqual(s.values, [:])
        XCTAssertEqual(s.snapshots.map(\.name), ["kept"], "snapshots stay")
    }

    func testAutoAndWhiteBalanceComeFromTheImage() throws {
        let dark = [SIMD3<Float>](repeating: SIMD3(40, 40, 40), count: 90) + [SIMD3<Float>](repeating: SIMD3(90, 90, 90), count: 10)
        let auto = DevelopSettings.auto(dark)
        XCTAssertGreaterThan(auto["exposure"] ?? 0, 0.5, "a dark image is brightened")
        XCTAssertLessThan(auto["blacks"] ?? 0, 0, "and its darkest pixels set to black")
        XCTAssertEqual(DevelopSettings.auto([]), [:])

        // Warm: the picked colour comes out gray through the engine's gains.
        let warm = [0.7, 0.62, 0.55]
        let wb = try XCTUnwrap(DevelopSettings.whiteBalance(warm))
        XCTAssertLessThan(wb.temperature, 0)
        let lin = warm.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let (t, n) = (wb.temperature / 100, wb.tint / 100)
        let out = [lin[0] * (1 + 0.35 * t), lin[1] * (1 - 0.25 * n), lin[2] * (1 - 0.35 * t)]
        XCTAssertEqual(out[0], out[2], accuracy: 0.01)
        XCTAssertEqual(out[1], out[0], accuracy: 0.02)

        let blueish = [SIMD3<Float>](repeating: SIMD3(90, 110, 160), count: 20)
        XCTAssertGreaterThan(try XCTUnwrap(DevelopSettings.autoWhiteBalance(blueish)).temperature, 0, "a blue cast is warmed")
        // Blue sky over warm sand: the sand decides.
        let beach = [SIMD3<Float>](repeating: SIMD3(60, 120, 220), count: 80) + [SIMD3<Float>](repeating: SIMD3(200, 185, 165), count: 20)
        XCTAssertLessThan(try XCTUnwrap(DevelopSettings.autoWhiteBalance(beach)).temperature, 0, "the sky isn't a cast")
    }

    func testFilesOpenInDevelopAndDoneKeepsTheirSettings() throws {
        XCTAssert(EditorModel.opensInDevelop("IMG_1.DNG", jpeg: false))
        XCTAssertFalse(EditorModel.opensInDevelop("a.jpg", jpeg: false))
        XCTAssert(EditorModel.opensInDevelop("a.heic", jpeg: true))
        XCTAssertFalse(EditorModel.opensInDevelop("a.png", jpeg: true))

        let model = makeModel()
        open("seaside.jpg", in: model)
        XCTAssertNil(model.developOpen, "JPEG opens straight away at first")
        model.closeActive()

        model.developJPEG = true
        open("seaside.jpg", in: model)
        let o = try XCTUnwrap(model.developOpen)
        XCTAssert(o.initial.isEmpty)
        model.liveBegin()
        model.live("filter.cameraRaw", ["exposure": 1])
        model.developDone(["exposure": 1])
        idle(model)
        XCTAssertNil(model.doc, "Done closes the file")
        XCTAssertNil(model.developOpen)

        open("seaside.jpg", in: model)
        XCTAssertEqual(model.developOpen?.initial["exposure"] as? Int, 1, "the kept settings")
        model.liveBegin()
        model.developCancel()
        idle(model)
        XCTAssertNil(model.doc)
    }

    func testOpenAsObjectKeepsALiveFilterAndOpenAppliesTheWorkflow() throws {
        let model = makeModel()
        model.developJPEG = true
        open("seaside.jpg", in: model)
        let before = model.pixel(100, 100)
        model.liveBegin()
        model.live("filter.cameraRaw", ["convertToGrayscale": true])
        model.developOpenImage(["convertToGrayscale": true], asObject: true)
        idle(model)
        let f = try XCTUnwrap(model.activeLayer?.smartFilters.first)
        XCTAssertEqual(f.command, "filter.cameraRaw")
        XCTAssertEqual(f.params["convertToGrayscale"] as? Bool, true)
        let p = model.pixel(100, 100)
        XCTAssertEqual(p[0], p[2], accuracy: 0.01, "Monochrome")
        XCTAssertNotEqual(p, before)
        XCTAssertEqual(model.historyNames.filter { $0 == "Develop" }.count, 1, "the try was taken back")

        open("seaside.jpg", in: model)
        model.liveBegin()
        model.developOpenImage(["exposure": 0.5], asObject: false, space: "srgb", depth: 16)
        idle(model)
        XCTAssertNil(model.activeLayer?.smartFilters.first)
        XCTAssertEqual((model.query("document.inspect") as? [String: Any])?["depth"] as? Int, 16)
        XCTAssert(model.historyNames.contains("Develop"))
    }
}
