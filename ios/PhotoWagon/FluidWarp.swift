import Foundation

/// Filter › Fluid Warp on the canvas: strokes painted with its tools show as a preview until
/// Commit. Two fingers still zoom and pan.
struct FluidWarp {
    let layer: UInt64
    /// The live filter being changed; it's hidden while it's redone.
    var filter: Int?
    var strokes: [[String: Any]] = []
    var tool = "forwardWarp"
    var size = 100.0
    var pressure = 50.0
    /// How much of the warp shows, 0–100 (Reconstruct All for the rest).
    var amount = 100.0

    static let tools: [(id: String, title: String, symbol: String)] = [
        ("forwardWarp", "Forward Warp", "hand.point.up.left"), ("reconstruct", "Reconstruct", "arrow.uturn.backward"),
        ("smooth", "Smooth", "scribble"), ("twirlCw", "Twirl", "arrow.clockwise"),
        ("pucker", "Pucker", "arrow.down.right.and.arrow.up.left"), ("bloat", "Bloat", "arrow.up.left.and.arrow.down.right"),
    ]

    /// `filter.liquify`'s strokes: the painted ones, then a Reconstruct All for any amount under 100%.
    var strokeParams: [[String: Any]] {
        strokes + (amount < 100 ? [["tool": "reconstructAll", "amount": 100 - amount]] : [])
    }

    /// A stroke through `points` (document pixels) with the current tool.
    mutating func add(_ points: [[Double]]) {
        guard !points.isEmpty else { return }
        strokes.append(["tool": tool, "size": size.rounded(), "pressure": pressure.rounded(), "points": points])
    }

    /// Back to where a live filter's `params` left it.
    mutating func load(_ params: [String: Any]) {
        var list = params["strokes"] as? [[String: Any]] ?? []
        if let last = list.last, last["tool"] as? String == "reconstructAll" {
            amount = 100 - (number(last["amount"]) ?? 100)
            list.removeLast()
        }
        strokes = list
    }
}

extension EditorModel {
    /// Filter › Fluid Warp on the active layer.
    func beginFluidWarp() {
        guard let l = activeLayer, ["Pixel", "Embedded"].contains(l.kind) else {
            toast = "Pick a layer with pixels to warp"
            return
        }
        fluidWarp = FluidWarp(layer: l.id)
    }

    /// Change a Fluid Warp live filter on the canvas.
    func editFluidWarp(layer: UInt64, filter: SmartFilterRow) {
        run("layer.select", ["layer": layer])
        run("layer.smartFilter.setVisible", ["layer": layer, "index": filter.index, "visible": false])
        var w = FluidWarp(layer: layer, filter: filter.index)
        w.load(filter.params)
        fluidWarp = w
    }

    func commitFluidWarp() {
        guard let w = fluidWarp else { return }
        fluidWarp = nil
        let end: ([String: Any]?) -> Void = { [weak self] _ in self?.editor.endPreview() }
        if let i = w.filter {
            // Takes back the hiding.
            run("edit.undo")
            runInBackground("layer.smartFilter.setParams", ["layer": w.layer, "index": i, "params": ["strokes": w.strokeParams]], then: end)
        } else if !w.strokes.isEmpty {
            runInBackground("filter.liquify", ["layer": w.layer, "strokes": w.strokeParams], then: end)
        } else {
            editor.endPreview()
            needsDraw = true
        }
    }

    func cancelFluidWarp() {
        guard let w = fluidWarp else { return }
        fluidWarp = nil
        if w.filter != nil { run("edit.undo") }
        editor.endPreview()
        needsDraw = true
    }

    /// Show the warp so far; the latest strokes win.
    func previewFluidWarp() {
        guard let w = fluidWarp else { return }
        let params = json(["layer": w.layer, "strokes": w.strokeParams])
        if fluidRunning {
            fluidNext = params
        } else {
            startFluid(params)
        }
    }

    private func startFluid(_ params: String) {
        fluidRunning = true
        let editor = editor
        Task.detached {
            try? editor.previewLiquify(params: params)
            await MainActor.run {
                self.fluidRunning = false
                self.needsDraw = true
                if let next = self.fluidNext {
                    self.fluidNext = nil
                    if self.fluidWarp != nil { self.startFluid(next) }
                }
            }
        }
    }
}
