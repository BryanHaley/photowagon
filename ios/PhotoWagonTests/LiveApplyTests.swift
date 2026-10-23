import XCTest
@testable import PhotoWagon

/// A filter's settings apply as you change them; OK keeps the last try as one step, Cancel takes
/// it back (LivePreviewTests' model side).
@MainActor
final class LiveApplyTests: XCTestCase {
    private let blur = "filter.blur.gaussianBlur"
    private let area = [200, 300, 1200, 600]

    private func beach() -> EditorModel {
        let model = makeModel()
        open("beach.jpg", in: model)
        return model
    }

    private func blurs(_ model: EditorModel) -> Int { model.historyNames.filter { $0 == "Gaussian Blur" }.count }

    func testTriesThenOKKeepOneStep() {
        let model = beach()
        let original = model.stddev(area)
        model.liveBegin()
        model.live(blur, ["radius": 2])
        idle(model)
        let first = model.stddev(area)
        XCTAssertLessThan(first, original, "blurred while the settings are open")
        model.live(blur, ["radius": 8])
        idle(model)
        XCTAssertLessThan(model.stddev(area), first - 0.005, "a stronger blur replaces the first")
        XCTAssertEqual(blurs(model), 1, "one step, not one per try: \(model.historyNames)")
        let revision = model.doc?.revision
        model.liveFinish(blur, ["radius": 8])
        idle(model)
        XCTAssertEqual(model.doc?.revision, revision, "OK with the settings already showing runs nothing")
        XCTAssertEqual(blurs(model), 1)
        XCTAssertEqual(model.historyNames.last, "Gaussian Blur")

        // The next settings screen starts afresh: its try doesn't undo the kept blur.
        model.liveBegin()
        model.live(blur, ["radius": 3])
        idle(model)
        model.liveCancel()
        idle(model)
        XCTAssertEqual(blurs(model), 1, "\(model.historyNames)")
    }

    func testCancelTakesTheTryBack() {
        let model = beach()
        let original = model.stddev(area)
        let history = model.historyNames
        model.liveBegin()
        model.live(blur, ["radius": 4])
        model.live(blur, ["radius": 6])
        idle(model)
        model.liveCancel()
        idle(model)
        XCTAssertEqual(model.stddev(area), original, accuracy: 0.0005, "the photo as it was")
        XCTAssertEqual(model.historyNames, history)
    }

    func testOKWithoutATryRunsOnce() {
        let model = beach()
        model.liveBegin()
        model.liveFinish(blur, ["radius": 5])
        idle(model)
        XCTAssertEqual(blurs(model), 1)
    }

    func testATryAfterTheScreenClosedIsIgnored() {
        let model = beach()
        let revision = model.doc?.revision
        // A field losing focus as its screen closes calls `live` once more.
        model.live(blur, ["radius": 4])
        idle(model)
        XCTAssertEqual(model.doc?.revision, revision)
        XCTAssertFalse(model.liveBusy)
    }

    func testDoneWhileATryRunsKeepsIt() {
        let model = beach()
        model.liveBegin()
        model.live(blur, ["radius": 4])
        // Closed some other way while the blur is still running.
        model.liveKeep()
        idle(model)
        XCTAssertEqual(blurs(model), 1)
        model.liveBegin()
        model.live(blur, ["radius": 2])
        idle(model)
        model.liveKeep()
        XCTAssertEqual(blurs(model), 2, "the kept blur isn't undone by the next screen's try: \(model.historyNames)")
    }

    func testPreviewOffShowsTheImageWithoutTheTryAndOKStillApplies() {
        let model = beach()
        let original = model.stddev(area)
        model.liveBegin()
        model.live(blur, ["radius": 4])
        idle(model)
        model.setLivePreview(false)
        idle(model)
        XCTAssertEqual(model.stddev(area), original, accuracy: 0.0005, "the try is taken back")
        model.live(blur, ["radius": 6])
        idle(model)
        XCTAssertEqual(model.stddev(area), original, accuracy: 0.0005, "changes wait while Preview is off")
        model.setLivePreview(true)
        idle(model)
        let shown = model.stddev(area)
        XCTAssertLessThan(shown, original - 0.005, "the latest settings come back")
        model.setLivePreview(false)
        idle(model)
        model.liveFinish(blur, ["radius": 6])
        idle(model)
        XCTAssertEqual(model.stddev(area), shown, accuracy: 0.0005, "OK applies them")
        XCTAssertEqual(blurs(model), 1)
    }

    func testCanvasPickGivesAFractionOfTheImage() {
        let model = makeModel(width: 200, height: 100)
        var got: CGPoint?
        model.beginPick(.canvas, prompt: "Tap") { got = $0 }
        model.canvasPicked(Point(x: 300, y: 50))
        XCTAssertNil(got, "off the image: still picking")
        XCTAssertNotNil(model.canvasPick)
        model.canvasPicked(Point(x: 50, y: 25))
        XCTAssertEqual(got, CGPoint(x: 0.25, y: 0.25))
        XCTAssertNil(model.canvasPick, "one pick, then the settings come back")
    }
}
