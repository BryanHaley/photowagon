import XCTest
@testable import PhotoWagon

/// Frame animation: making frames, a move that belongs to one frame, delays, playing, and Save
/// for Web's GIF that opens again as frames (AnimatedGifTests' model side).
@MainActor
final class AnimationTests: XCTestCase {
    /// A transparent document with the eight drop frames as layers.
    private func drops() -> EditorModel {
        let model = makeModel(width: 800, height: 500)
        model.placeAll((1...8).map { sample("drop-\($0).png") }, embedded: false)
        wait("eight layers on the Background") { model.layers.count == 9 && !model.busy }
        if let bg = model.layers.first(where: \.isBackground) { model.run("layer.delete", ["layer": bg.id]) }
        XCTAssertEqual(model.layers.count, 8)
        return model
    }

    private func alpha(_ model: EditorModel, _ rect: [Int]) -> Double {
        let s = model.query("document.stats", ["rect": rect]) as? [String: Any]
        return numbers(s?["mean"])?.last ?? -1
    }

    /// Where the first frame's drop sits in the 800 × 500 document.
    private let dropTop = [370, 110, 430, 190]

    func testFramesFromLayersAndAMoveInOneFrame() throws {
        let model = drops()
        model.createFrameAnimation()
        model.makeFramesFromLayers()
        XCTAssertEqual(model.animation?.count, 8)
        XCTAssertEqual(model.layers.filter(\.visible).map(\.name), ["drop-1"])
        XCTAssertGreaterThan(alpha(model, dropTop), 0.05)
        // A new frame, its drop moved down.
        model.run("layer.select", ["layer": try XCTUnwrap(model.layers.first { $0.name == "drop-1" }?.id)])
        model.newFrame()
        XCTAssertEqual(model.animation?.current, 1)
        model.run("layer.translate", ["dy": 140])
        XCTAssertLessThan(alpha(model, dropTop), 0.01)
        model.selectFrame(0)
        XCTAssertGreaterThan(alpha(model, dropTop), 0.05, "the first frame keeps it at the top")
        XCTAssertEqual(model.animation?.count, 9)
    }

    func testDelaysApplyToTheSelectedFrames() {
        let model = drops()
        model.makeFramesFromLayers()
        XCTAssertEqual(model.animation?.delays.first ?? 0, 0.1, accuracy: 1e-6, "0.1 s to start with")
        model.selectedFrames = Set(0..<8)
        model.setDelay(0.2)
        XCTAssertEqual(model.animation?.delays.map { ($0 * 10).rounded() / 10 }, Array(repeating: 0.2, count: 8))
        model.selectFrame(3)
        model.setDelay(1)
        XCTAssertEqual(model.animation?.delays[3], 1)
        XCTAssertEqual(model.animation?.delays[2] ?? 0, 0.2, accuracy: 1e-6)
        model.setLoops(3)
        XCTAssertEqual(model.animation?.loops, 3)
        model.selectedFrames = [0, 1]
        model.deleteFrames()
        XCTAssertEqual(model.animation?.count, 6)
    }

    func testPlayingStepsThroughTheFramesAndStops() {
        let model = drops()
        model.makeFramesFromLayers()
        model.setLoops(1)
        model.startPlaying()
        wait("it plays to the end once", timeout: 5) { !model.playing }
        XCTAssertEqual(model.animation?.current, 7, "stops on the last frame")
        XCTAssertEqual(model.selectedFrames, [7])
    }

    func testPlaybackOrder() {
        XCTAssertEqual(AnimationInfo.next(after: 0, count: 3, loops: 0, played: 0)?.frame, 1)
        XCTAssertEqual(AnimationInfo.next(after: 2, count: 3, loops: 0, played: 5)?.frame, 0, "forever")
        XCTAssertEqual(AnimationInfo.next(after: 2, count: 3, loops: 2, played: 0)?.played, 1)
        XCTAssertNil(AnimationInfo.next(after: 2, count: 3, loops: 2, played: 1), "two plays done")
        XCTAssertNil(AnimationInfo.next(after: 0, count: 1, loops: 0, played: 0), "one frame doesn't play")
        XCTAssertEqual(AnimationInfo.onScreen(0), 1.0 / 30)
        XCTAssertEqual(AnimationInfo.label(0.2), "0.2 s")
        XCTAssertEqual(AnimationInfo.label(2), "2 s")
        XCTAssertEqual(AnimationInfo.loopsLabel(0), "Forever")
    }

    func testSaveForWebWritesAGifThatOpensAsFrames() throws {
        let model = drops()
        model.makeFramesFromLayers()
        model.selectedFrames = Set(0..<8)
        model.setDelay(0.2)
        let file = try tempFolder().appendingPathComponent("drop.gif")
        var p = SaveForWebSheet.params(format: "gif", colors: 256, palette: "selective", dither: "diffusion", transparency: true, quality: 60, percent: 100, loops: 0)
        p["path"] = file.path
        let out = model.run("file.export.saveForWebLegacy", p) as? [String: Any]
        XCTAssertEqual(out?["frames"] as? Int, 8)
        model.open(url: file)
        wait("the GIF opened") { model.doc?.name == "drop.gif" && !model.busy }
        XCTAssertEqual(model.animation?.count, 8)
        XCTAssertEqual(model.animation?.loops, 0)
        XCTAssertEqual(model.animation?.delays.first ?? 0, 0.2, accuracy: 0.01)
        XCTAssertEqual(alpha(model, [0, 0, 40, 40]), 0, accuracy: 0.001, "transparent")
        XCTAssertNil(SaveForWebSheet.params(format: "png24", colors: 256, palette: "selective", dither: "none", transparency: true, quality: 60, percent: 50, loops: nil)["colors"])
    }
}
