import Foundation
import UIKit
@testable import PhotoWagon

/// The app's own stored settings crossed with each other (plan/omega-e2e.md, section 5.4): each
/// all-pairs row sets them, starts a fresh model, and runs a short fixed set of steps.
extension Omega {
    /// Each stored setting's values (`OmegaCatalog.settings`: the unit test there says when one is
    /// missing here).
    static let settingValues: [(key: String, values: [Any])] = [
        ("canvasColor", CanvasColor.allCases.map(\.rawValue)),
        ("canvasCustom", [[0.3, 0.3, 0.32], [1.0, 0.0, 0.0]] as [[Double]]),
        ("layerThumbnails", ThumbnailSize.allCases.map(\.rawValue)),
        ("openJPEGInDevelop", [false, true]),
        ("pencilOnly", [false, true]),
        ("pencilSqueeze", PencilAction.allCases.map(\.rawValue)),
        ("pencilTap", PencilAction.allCases.map(\.rawValue)),
        ("recoveryMinutes", [10, 0, 1]),
        ("snap", [true, false]),
        ("statusInfo", StatusBar.Info.allCases.map(\.rawValue)),
        ("tutorialDone", [false, true]),
        ("autoOptions", [Data()]),
        ("developFiles", [[String]()]),
        ("developPresets", [[Any]()]),
        ("recentFiles", [[String]()]),
    ]

    /// The steps each settings row runs.
    static let settingSteps: [(String, [String: Any])] = [
        ("layer.new.layer", [:]),
        ("paint.stroke", ["points": [[2, 2], [30, 20]], "size": 4]),
        ("select.all", [:]),
        ("filter.blur.gaussianBlur", ["radius": 2]),
        ("image.adjustments.invert", [:]),
        ("layer.flattenImage", [:]),
    ]

    func runSettings() {
        let standard = UserDefaults.standard
        let saved = Self.settingValues.map { ($0.key, standard.object(forKey: $0.key)) }
        defer { for (k, v) in saved { standard.set(v, forKey: k) } }
        record(id: "settings|every setting", command: "settings", fixture: "", params: "") { r in
            let listed = Set(Self.settingValues.map(\.key))
            let missing = OmegaCatalog.settings.subtracting(listed)
            if !missing.isEmpty { r.problems.append("settings with no values here: \(missing.sorted())") }
        }
        for (n, row) in Pairs.rows(Self.settingValues.map(\.values.count)).enumerated() {
            let id = "settings|\(n)"
            if isDone(id) { continue }
            let chosen = zip(Self.settingValues, row).map { ($0.key, $0.values[$1]) }
            record(id: id, command: "settings", fixture: "rgb8 37 × 23", params: chosen.map { "\($0.0)=\($0.1)" }.joined(separator: " ")) { r in
                // Some settings live in the app's standard defaults, some in the model's own.
                let suite = UserDefaults(suiteName: "omega.settings.\(n)") ?? .standard
                for (k, v) in chosen {
                    standard.set(v, forKey: k)
                    suite.set(v, forKey: k)
                }
                let m = EditorModel(defaults: suite)
                m.newDocument(["width": 37, "height": 23])
                m.canvasResized(width: 400, height: 400, scale: 1)
                for (sid, p) in Self.settingSteps {
                    do { _ = try m.editor.execute(id: sid, params: json(p)) } catch {
                        r.problems.append("\(sid) refused: \(error)")
                    }
                    m.sync()
                }
                if m.doc == nil { r.problems.append("no document after the steps") }
                if let t = m.toast { r.problems += Self.messageProblems(t) }
                suite.removePersistentDomain(forName: "omega.settings.\(n)")
            }
        }
    }
}
