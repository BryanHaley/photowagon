import XCTest
@testable import PhotoWagon

/// Window › Actions: record, list, switch steps off, play, save and load
/// (GettingStartedTests' actions steps).
@MainActor
final class ActionsTests: XCTestCase {
    /// Actions live in the app's presets, shared by every model: each test uses its own names
    /// and deletes them.
    private func named(_ name: String, in model: EditorModel) -> ActionsPanel.Action? {
        model.actionList()?.first { $0.name == name }
    }

    private func cleanUp(_ names: [String], _ model: EditorModel) {
        addTeardownBlock { @MainActor in
            for n in names { _ = try? model.editor.execute(id: "actions.delete", params: json(["action": n])) }
        }
    }

    func testRecordPlaySaveAndLoad() throws {
        let model = makeModel(width: 200, height: 200)
        let name = "Paint \(UUID().uuidString.prefix(8))"
        cleanUp([name], model)
        model.run("actions.record", ["name": name])
        XCTAssertNotNil(named(name, in: model))
        XCTAssertEqual(model.recordingAction, name, "the status bar shows the recording")
        model.run("layer.new.layer")
        model.tool = .brush
        CanvasUIView(model: model).drag(pt(20, 20), pt(180, 180))
        model.run("actions.stop")
        let action = try XCTUnwrap(named(name, in: model))
        XCTAssertNil(model.recordingAction)
        XCTAssertEqual(action.steps.map(\.label), ["Make Layer", "Brush Tool"], "Photoshop's step names")
        XCTAssertEqual(action.set, "Actions")
        XCTAssertFalse(action.hasSet)
        XCTAssertTrue(action.on)

        model.run("actions.toggle", ["action": name, "step": 1])
        XCTAssertEqual(named(name, in: model)?.steps.map(\.on), [true, false])
        XCTAssertEqual(named(name, in: model)?.on, false)
        model.run("actions.toggle", ["action": name, "step": 1])

        model.playAction(name)
        idle(model)
        XCTAssertEqual(model.layerCount, 3, "the steps run again")
        XCTAssertEqual(model.historyNames.suffix(2), ["New Layer", "Brush Tool"])

        let set = "Set \(UUID().uuidString.prefix(8))"
        model.run("actions.assignSet", ["action": name, "set": set])
        let saved = try XCTUnwrap(model.run("actions.save", ["set": set, "skipUnsupported": true]) as? [String: Any])
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(saved["data"] as? String)))
        let url = try tempFolder().appendingPathComponent("\(set).atn")
        try data.write(to: url)
        model.run("actions.delete", ["action": name])
        XCTAssertNil(named(name, in: model))
        model.loadActions(url)
        XCTAssertEqual(model.toast, "Loaded 1 action")
        XCTAssertEqual(named(name, in: model)?.set, set, "Load Actions brings it back, in its set")
        XCTAssertEqual(named(name, in: model)?.hasSet, true)

        model.loadActions(URL(fileURLWithPath: "/nonexistent/x.atn"))
        XCTAssertNotEqual(model.toast, "Loaded 1 action", "a missing file says so")
    }

    func testPlayingSaysWhereItStopped() throws {
        let model = makeModel(width: 50, height: 50)
        let name = "Fails \(UUID().uuidString.prefix(8))"
        cleanUp([name], model)
        model.run("layer.new.layer", ["name": "temp"])
        model.run("actions.record", ["name": name])
        model.run("select.all")
        model.run("layer.select", ["name": "temp"])
        model.run("actions.stop")
        XCTAssertEqual(named(name, in: model)?.steps.count, 2)
        // The layer the second step picks is gone.
        model.run("layer.delete")
        model.playAction(name)
        idle(model)
        XCTAssertEqual(model.toast?.hasPrefix("Stopped at step 2"), true, model.toast ?? "no message")
    }
}
