import Foundation
@testable import PhotoWagon

/// The documents Omega's cases run on, built by engine commands so they're the same every run.
struct Fixture: Codable, Hashable {
    var mode: String
    var depth: Int
    var layer: String
    var selection: String
    var mask: Bool
    var extra: String
    var size: String

    /// The factors and their values, in the order `Pairs` crosses them.
    static let factors: [(name: String, values: [String])] = [
        ("mode", ["rgb", "grayscale", "cmyk", "lab"]),
        ("depth", ["8", "16", "32"]),
        ("layer", ["background", "pixel", "empty", "text", "shape", "group", "adjustment", "fill", "embedded"]),
        ("selection", ["none", "rect", "feathered"]),
        ("mask", ["no", "yes"]),
        ("extra", ["none", "timeline", "animation", "artboard", "slices", "path", "guides", "channel", "notes", "comps", "frame"]),
        ("size", ["small", "tiny", "tall"]),
    ]

    init(_ values: [String]) {
        mode = values[0]
        depth = Int(values[1]) ?? 8
        layer = values[2]
        selection = values[3]
        mask = values[4] == "yes"
        extra = values[5]
        size = values[6]
    }

    var name: String { "\(mode)\(depth)-\(layer)-\(selection)\(mask ? "-mask" : "")-\(extra)-\(size)" }

    /// "big" isn't one of the factors: the speed section's 24 MP document.
    var width: Int { size == "tiny" ? 1 : size == "tall" ? 9 : size == "big" ? 6000 : 37 }
    var height: Int { size == "tiny" ? 1 : size == "tall" ? 300 : size == "big" ? 4000 : 23 }

    /// A rectangle as fractions of the document, in whole pixels, at least 1 × 1.
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [String: Any] {
        let (W, H) = (Double(width), Double(height))
        let x0 = min(Int(x * W), width - 1), y0 = min(Int(y * H), height - 1)
        return ["x": x0, "y": y0, "width": max(1, min(Int(w * W), width - x0)), "height": max(1, min(Int(h * H), height - y0))]
    }

    private func point(_ x: Double, _ y: Double) -> [Int] { [min(Int(x * Double(width)), width - 1), min(Int(y * Double(height)), height - 1)] }

    private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [Int] {
        let r = rect(x, y, w, h)
        return [r["x"], r["y"], r["width"], r["height"]].compactMap { $0 as? Int }
    }

    /// Builds the fixture as the front document, or says which step the engine refused.
    @MainActor
    func build(in model: EditorModel) -> String? {
        let after: [(String, [String: Any])?] = [
            mode == "rgb" ? nil : ("image.mode.\(mode)", [:]),
            depth == 8 ? nil : ("image.mode.bits\(depth)", [:]),
            mask ? ("layer.layerMask.revealAll", [:]) : nil,
            selection == "none" ? nil : ("select.rect", rect(0.16, 0.22, 0.38, 0.4)),
            selection == "feathered" ? ("select.modify.feather", ["radius": 2]) : nil,
        ]
        let base: [(String, [String: Any])] = [
            ("file.new", ["width": width, "height": height, "name": name]),
            ("select.rect", rect(0.1, 0.13, 0.55, 0.52)),
            ("edit.fill", ["color": "#c04020"]),
            ("select.deselect", [:]),
            ("paint.stroke", ["points": [point(0.05, 0.87), point(0.8, 0.17)], "color": "#2060d0", "size": 5]),
        ]
        let steps = base + layerSteps + extraSteps + after.compactMap { $0 }
        for (id, p) in steps {
            do { _ = try model.editor.execute(id: id, params: json(p)) } catch {
                return "\(id): \(error)"
            }
        }
        model.sync()
        return nil
    }

    private var layerSteps: [(String, [String: Any])] {
        switch layer {
        case "background": []
        case "pixel": [("layer.new.layer", [:]), ("paint.stroke", ["points": [point(0.14, 0.22), point(0.68, 0.65)], "color": "#30a040", "size": 4])]
        case "empty": [("layer.new.layer", [:])]
        case "text": [("type.create", ["x": point(0.08, 0.7)[0], "y": point(0.08, 0.7)[1], "text": "Omega", "size": 10])]
        case "shape": [("shape.create", ["kind": "rect", "rect": box(0.2, 0.25, 0.55, 0.5), "fill": "#ff0000"])]
        case "group": [("layer.new.layer", [:]), ("layer.groupLayers", [:])]
        case "adjustment": [("layer.newAdjustmentLayer.invert", [:])]
        case "fill": [("layer.newFillLayer.solidColor", ["color": "#808000"])]
        case "embedded": [("layer.new.layer", [:]), ("paint.stroke", ["points": [point(0.14, 0.22), point(0.68, 0.65)], "color": "#30a040", "size": 4]),
                          ("layer.smartObjects.convertToSmartObject", [:])]
        default: []
        }
    }

    private var extraSteps: [(String, [String: Any])] {
        switch extra {
        case "timeline": [("timeline.create", ["duration": 24, "fps": 24.0])]
        case "animation": [("animation.create", [:]), ("animation.newFrame", [:])]
        case "artboard": [("layer.new.artboard", ["rect": [0, 0, width, height]])]
        case "slices": [("slice.new", ["rect": box(0.1, 0.1, 0.4, 0.4), "name": "omega"])]
        case "path": [("select.rect", rect(0.2, 0.2, 0.5, 0.5)), ("select.toWorkPath", [:]), ("select.deselect", [:])]
        case "guides": [("view.newGuide", ["orientation": "horizontal", "position": height / 2]),
                        ("view.newGuide", ["orientation": "vertical", "position": width / 3])]
        case "channel": [("select.rect", rect(0.3, 0.3, 0.4, 0.4)), ("select.saveSelection", ["name": "Omega"]), ("select.deselect", [:])]
        case "notes": [("notes.add", ["x": point(0.5, 0.5)[0], "y": point(0.5, 0.5)[1], "text": "Omega note"])]
        case "comps": [("layerComp.new", ["name": "Omega"])]
        case "frame": [("layer.new.frame", rect(0.1, 0.1, 0.6, 0.6))]
        default: []
        }
    }
}
