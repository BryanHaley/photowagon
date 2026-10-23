import XCTest
@testable import PhotoWagon

/// Zoom, pan, rotation and fitting (GettingStartedTests' zoom and Fit on Screen, LandscapeTests'
/// refit on a turn).
@MainActor
final class ViewTests: XCTestCase {
    func testZoomKeepsThePointUnderTheFingerAndStaysInRange() {
        let model = makeModel(width: 1000, height: 800)
        let p = CGPoint(x: 300, y: 900)
        let before = screenToDoc(view: model.view, x: 300, y: 900)
        model.zoom(by: 2.5, at: p)
        // Within half a screen pixel: screenToDoc reads pixel centres, place() doesn't.
        XCTAssertNear(screenToDoc(view: model.view, x: 300, y: 900), before, accuracy: 0.25)
        model.zoom(by: 1000)
        XCTAssertEqual(model.view.zoom, 64)
        model.zoom(by: 0.000001)
        XCTAssertEqual(model.view.zoom, 0.01)
        model.noteView()
        XCTAssertEqual(model.zoomPercent, 1)
    }

    func testPanFollowsTheFingerWhateverTheRotation() {
        let model = makeModel(width: 1000, height: 800)
        model.view.rotation = .pi / 2
        let doc = screenToDoc(view: model.view, x: 600, y: 600)
        model.pan(dx: 50, dy: -20)
        XCTAssertNear(screenToDoc(view: model.view, x: 650, y: 580), doc, accuracy: 0.01)
        let centre = screenToDoc(view: model.view, x: 600, y: 600)
        model.straighten()
        XCTAssertEqual(model.view.rotation, 0)
        XCTAssertNear(screenToDoc(view: model.view, x: 600, y: 600), centre, accuracy: 0.25, "Straighten View keeps the centre")
    }

    func testFitAndActualSize() throws {
        let model = makeModel(width: 1000, height: 500)
        XCTAssertEqual(model.fitZoom, 1200.0 / 1000 * 0.94, accuracy: 0.0001)
        let actual = try XCTUnwrap(model.viewActions.first { $0.title == "Actual Size" })
        actual.run()
        XCTAssertEqual(model.view.zoom, 1, accuracy: 0.0001)
        model.view.rotation = 1
        try XCTUnwrap(model.viewActions.first { $0.title == "Fit on Screen" }).run()
        XCTAssertEqual(model.view.zoom, model.fitZoom)
        XCTAssertEqual(model.view.rotation, 0)
        XCTAssertNear(screenToDoc(view: model.view, x: 600, y: 600), pt(500, 250), "centred")
    }

    func testAFittedViewRefitsWhenTheCanvasChangesSize() {
        // LandscapeTests: turning the device keeps the whole image in view.
        let model = makeModel(width: 1000, height: 500)
        model.canvasResized(width: 2400, height: 1000, scale: 3)
        XCTAssertEqual(model.view.zoom, model.fitZoom, accuracy: 0.0001)
        XCTAssertEqual(model.view.zoom, 1.88, accuracy: 0.0001)
        model.zoom(by: 2)
        let zoomed = model.view.zoom
        model.canvasResized(width: 1200, height: 1200, scale: 3)
        XCTAssertEqual(model.view.zoom, zoomed, "a zoomed-in view keeps its zoom")
        // A crop changes the document's size: fit it again.
        model.fit()
        model.run("image.crop", ["x": 0, "y": 0, "width": 100, "height": 100])
        XCTAssertEqual(model.view.zoom, model.fitZoom, accuracy: 0.0001)
    }

    func testCanvasPointsRoundTripAtAnyRotation() {
        let model = makeModel(width: 1000, height: 800)
        model.view.rotation = 0.7
        model.zoom(by: 1.7)
        let canvas = CanvasUIView(model: model)
        let d = pt(123, 456)
        XCTAssertNear(canvas.toDoc(canvas.toScreen(d)), d, accuracy: 0.01)
        XCTAssertEqual(canvas.screenDistance(pt(0, 0), pt(100, 0)), CGFloat(100 * model.view.zoom) / 3, accuracy: 0.01)
    }

    /// An unrotated view ignores twists within ±20°, then follows smoothly; a rotated one turns at once.
    func testTwoFingersTurnTheViewOnlyPastADeadZone() {
        let twenty: Float = 20 * .pi / 180
        var from: Float?
        XCTAssertEqual(CanvasUIView.navTurn(twist: 0.33, rotated: false, from: &from), 0, "19° does nothing")
        XCTAssertEqual(CanvasUIView.navTurn(twist: 0.5, rotated: false, from: &from), 0.5 - twenty, accuracy: 0.0001, "past 20°: from there")
        XCTAssertEqual(CanvasUIView.navTurn(twist: 0, rotated: false, from: &from), -twenty, accuracy: 0.0001, "and back the other way")
        var turned: Float?
        XCTAssertEqual(CanvasUIView.navTurn(twist: 0.02, rotated: true, from: &turned), 0.02, accuracy: 0.0001, "no dead zone once rotated")
    }

    /// The top bar's view menu: each reset undoes only its own part.
    func testResetTiltPositionAndZoomSeparately() {
        let model = makeModel(width: 400, height: 300)
        model.fit()
        let fitted = model.view
        model.view.rotation = 0.5
        model.zoom(by: 3, at: CGPoint(x: 10, y: 10))
        model.pan(dx: 80, dy: -40)
        model.resetZoom()
        XCTAssertEqual(model.view.zoom, fitted.zoom, accuracy: 0.0001)
        XCTAssertEqual(model.view.rotation, 0.5, "tilt kept")
        model.resetPosition()
        let mid = screenToDoc(view: model.view, x: Float(model.view.width) / 2, y: Float(model.view.height) / 2)
        XCTAssertEqual(mid.x, 200, accuracy: 0.01)
        XCTAssertEqual(mid.y, 150, accuracy: 0.01)
        model.straighten()
        XCTAssertEqual(model.view.rotation, 0)
        XCTAssertEqual(model.view.zoom, fitted.zoom, accuracy: 0.0001)
    }
}
