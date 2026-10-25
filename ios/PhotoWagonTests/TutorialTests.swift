import XCTest
@testable import PhotoWagon

/// The first-time tour: when it starts, its steps, and that it stays away once done or skipped.
@MainActor
final class TutorialTests: XCTestCase {
    func testTheTourStartsOnceAndShowsTheGroupWhileItsTipDoes() {
        XCTAssertNil({ let m = makeModel(); m.startTutorialIfNew(); return m.tutorialStep }(), "not without a document")
        let model = makeModel(width: 100, height: 100)
        model.tool = .brush
        model.startTutorialIfNew()
        XCTAssertEqual(model.tutorialStep, .toolGroups)
        model.nextTutorialStep()
        XCTAssertEqual(model.tutorialStep, .groupTools)
        XCTAssertEqual(model.pickingGroup, Tool.groups.firstIndex { $0.contains(.brush) }, "the brush group's tools are listed")
        model.nextTutorialStep()
        XCTAssertEqual(model.tutorialStep, .toolOptions)
        XCTAssertNil(model.pickingGroup, "the tool's options show again")

        model.showTutorial(.colors)
        model.nextTutorialStep()
        XCTAssertNil(model.tutorialStep, "the last tip ends it")
        XCTAssert(model.tutorialDone)
        model.startTutorialIfNew()
        XCTAssertNil(model.tutorialStep, "and it doesn't come back")
    }

    func testSkipEndsTheTour() {
        let model = makeModel(width: 100, height: 100)
        model.startTutorialIfNew()
        model.endTutorial()
        XCTAssertNil(model.tutorialStep)
        XCTAssert(model.tutorialDone)
        model.showTutorial(.toolGroups)
        XCTAssertEqual(model.tutorialStep, .toolGroups, "Help › Tutorial still shows it")
    }

    /// The Menus tip lets you open the menu, and closing it moves the tour on.
    func testClosingTheMenuMovesTheMenusTipOn() {
        let model = makeModel(width: 100, height: 100)
        XCTAssertTrue(TutorialStep.menu.touchesTarget)
        XCTAssertFalse(TutorialStep.undo.touchesTarget)
        model.showTutorial(.home)
        model.menuClosed()
        XCTAssertEqual(model.tutorialStep, .home, "only on the Menus tip")
        model.showTutorial(.menu)
        model.menuClosed()
        XCTAssertEqual(model.tutorialStep, .undo)
    }
}
