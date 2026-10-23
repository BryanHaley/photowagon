import XCTest
@testable import PhotoWagon

/// The Levels screen: its params, handles, Auto and eyedroppers.
@MainActor
final class LevelsTests: XCTestCase {
    func testMidtoneHandleAndGammaAgree() {
        XCTAssertEqual(LevelsValues.midtone(gamma: 1), 0.5)
        XCTAssertEqual(LevelsValues.gamma(midtone: 0.5), 1)
        XCTAssertGreaterThan(LevelsValues.gamma(midtone: 0.25), 1, "left brightens")
        XCTAssertEqual(LevelsValues.gamma(midtone: LevelsValues.midtone(gamma: 2.4)), 2.4, accuracy: 0.01)
        XCTAssertEqual(LevelsValues.gamma(midtone: 0), 9.97, accuracy: 0.03, "an end stays in range")
        XCTAssertEqual(LevelsValues.gamma(midtone: 1), 0.01)
    }

    func testParamsRoundTripAndResetUnsetChannels() {
        var v = LevelsValues(["inBlack": 10, "gamma": 1.2, "red": ["inWhite": 200, "outBlack": 5]])
        XCTAssertEqual(v[""].inBlack, 10)
        XCTAssertEqual(v["red"].inWhite, 200)
        XCTAssertEqual(v["green"], .init())
        v["blue"].gamma = 0.8
        let p = v.params(keys: ["", "red", "green", "blue"])
        XCTAssertEqual(p["gamma"] as? Double, 1.2)
        XCTAssertEqual((p["green"] as? [String: Any])?["inWhite"] as? Double, 255, "a preset clears the old channel")
        let back = LevelsValues(p)
        for k in ["", "red", "green", "blue"] { XCTAssertEqual(back[k], v[k], k) }
    }

    func testToneInfoFromTheEngine() throws {
        let model = makeModel()
        model.newDocument(["width": 20, "height": 20, "background": "#3366cc"])
        let tone = try XCTUnwrap(ToneInfo(model.query("image.toneHistogram")))
        XCTAssertEqual(tone.channels.map(\.name), ["RGB", "Red", "Green", "Blue"])
        XCTAssertTrue(tone.eyedroppers && tone.grayPicker && tone.isRGB)
    }

    func testOutputsApplyTheChannelThenTheComposite() {
        var v = LevelsValues()
        v["red"].inWhite = 128
        v[""].outBlack = 100
        let out = v.outputs("red")
        XCTAssertEqual(out[0], 100)
        XCTAssertEqual(out[128], 255)
        XCTAssertEqual(v.outputs("")[255], 255)
    }

    func testEyedropperOnAnAdjustmentLayerSamplesBelowIt() throws {
        let model = makeModel()
        model.newDocument(["width": 20, "height": 20, "background": "#3366cc"])
        model.run("layer.newAdjustmentLayer.levels", ["gamma": 3])
        let layer = try XCTUnwrap(model.activeLayer?.id)
        let out = try XCTUnwrap(model.run("image.adjustmentEyedropper", ["kind": "levels", "eyedropper": ["point": "white", "at": [5, 5]], "layer": layer]) as? [String: Any])
        XCTAssertEqual(LevelsValues(out)["red"].inWhite, 51, accuracy: 1)
    }

    func testPreviewTapsMapOntoTheFittedImage() {
        // A 200×100 image fitted into 100×100: 50 high, centred.
        let size = CGSize(width: 100, height: 100), image = CGSize(width: 200, height: 100)
        XCTAssertEqual(PreviewPane.imagePoint(CGPoint(x: 50, y: 50), in: size, image: image), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(PreviewPane.imagePoint(CGPoint(x: 0, y: 25), in: size, image: image), CGPoint(x: 0, y: 0))
        XCTAssertNil(PreviewPane.imagePoint(CGPoint(x: 50, y: 10), in: size, image: image), "the bar above the image")
    }

    func testSnapshotColour() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 1), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            UIColor.blue.setFill(); c.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        }
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(PreviewSampler.color(cg, at: CGPoint(x: 0.9, y: 0.5)), [0, 0, 1])
        XCTAssertEqual(PreviewSampler.color(cg, at: CGPoint(x: 0.1, y: 0.5)), [1, 0, 0])
        XCTAssertNil(PreviewSampler.color(cg, at: CGPoint(x: 1.5, y: 0.5)))
    }
}
