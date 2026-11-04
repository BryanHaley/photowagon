import Foundation
import UIKit
@testable import PhotoWagon

/// Long random sessions (plan/omega-e2e.md, section 5.5) and every tool through the canvas's own
/// touch handling (section 5.6).
extension Omega {
    struct Step: Codable {
        var id: String
        var params: String
    }

    /// Same seed, same numbers (SplitMix64).
    struct Seeded {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func pick(_ n: Int) -> Int { n > 0 ? Int(next() % UInt64(n)) : 0 }
    }

    /// `count` sessions of `steps` random commands with random settings. A session that goes
    /// wrong is shrunk to the shortest run of steps that still goes wrong, kept in its message.
    func runSessions(count: Int, steps: Int) {
        // Sizes a person works at: a 100,000 × 300,000 document is allowed, but every step on it
        // takes minutes, so the session would only measure that.
        let realistic = { (name: String, values: [Any]) -> [Any] in
            guard ["width", "height"].contains(name) else { return values }
            let small = values.filter { ($0 as? Double).map { $0 <= 4000 } ?? true }
            return small.isEmpty ? [1000.0] : small
        }
        let commands = model.editor.allCommands().filter { OmegaCatalog.skipped[$0.id] == nil }
            .map { c in (c.id, model.editor.commandFields(id: c.id).map { ($0.name, realistic($0.name, Self.values($0.kind))) }) }
        let rows = Pairs.rows(Fixture.factors.map(\.values.count))
        for n in 0..<count {
            let id = "session|\(n)"
            if isDone(id) { continue }
            let f = Fixture(Fixture.factors.indices.map { Fixture.factors[$0].values[rows[n % rows.count][$0]] })
            record(id: id, command: "session", fixture: f.name, params: "seed \(n)") { r in
                var rng = Seeded(state: UInt64(n))
                var plan: [Step] = []
                let out = folder.appendingPathComponent("out")
                for _ in 0..<steps {
                    let (cid, fields) = commands[rng.pick(commands.count)]
                    var p = OmegaCatalog.fixedParams[cid] ?? [:]
                    for (name, values) in fields where p[name] == nil { p[name] = values[rng.pick(values.count)] }
                    plan.append(Step(id: cid, params: json(resolve(p, f, out: out) as? [String: Any] ?? p)))
                }
                guard let (at, problem) = replay(plan, on: f) else { return }
                r.problems.append("step \(at + 1) (\(plan[at].id)): \(problem)")
                // Shrinking a hang would wait out the time limit on every try.
                let shortest = problem == "hang" ? Array(plan[...at]) : shrink(Array(plan[...at]), on: f, problem: problem)
                r.message = "shortest: " + shortest.map { "\($0.id) \($0.params)" }.joined(separator: " ; ")
                // A stuck session keeps its editor; the next session makes a new one.
            }
        }
    }

    /// Runs `plan` on a fresh `f`: the first step that goes wrong and how, or nil.
    func replay(_ plan: [Step], on f: Fixture) -> (Int, String)? {
        resetModel()
        guard f.build(in: model) == nil else { return nil }
        for (i, s) in plan.enumerated() {
            // A step that closed the document: start a new one, as a person would.
            if model.doc == nil, f.build(in: model) != nil { return nil }
            let docID = model.doc?.id
            let before = fingerprint()
            // Random settings can be slow on purpose (Minimum at radius 500): only this long is stuck.
            switch execute(s.id, s.params, deadline: max(Omega.deadline, 180)) {
            case .none:
                return (i, "hang")
            case let .some(.failure(error)):
                model.show(error)
                if let panic = Self.messageProblems(model.toast).first(where: { $0.hasPrefix("panic") }) { return (i, panic) }
                model.sync()
                if model.doc?.id == docID, let before, fingerprint() != before { return (i, "refused but changed the document") }
            case .some(.success):
                model.sync()
                // Every fifth step: Undo and Redo round trip.
                guard i % 5 == 0, model.doc?.id == docID, let before, let after = fingerprint(),
                      Self.document(after) != Self.document(before),
                      !OmegaCatalog.historyCommands.contains(s.id), OmegaCatalog.notUndoable[s.id] == nil else { continue }
                guard let n = undo(to: before, max: 8) else { return (i, "Undo doesn't bring back the document") }
                if redo(n).map(Self.document) != Self.document(after) { return (i, "Redo doesn't bring back the result") }
            }
        }
        return nil
    }

    /// Drops steps while the same problem still happens (at most 200 replays).
    func shrink(_ plan: [Step], on f: Fixture, problem: String) -> [Step] {
        var plan = plan
        var chunk = max(plan.count / 2, 1)
        var tries = 0
        while chunk >= 1, tries < 200 {
            var removed = false
            var start = 0
            while start < plan.count - 1, tries < 200 {
                let candidate = Array(plan[..<start]) + Array(plan[min(start + chunk, plan.count - 1)...])
                tries += 1
                if let (_, p) = replay(candidate, on: f), p == problem {
                    plan = candidate
                    removed = true
                } else {
                    start += chunk
                }
            }
            if !removed { chunk /= 2 }
        }
        return plan
    }

    // MARK: - Tools

    static let toolFactors: [(name: String, values: [String])] = [
        ("mode", ["rgb", "cmyk", "grayscale"]),
        ("depth", ["8", "16", "32"]),
        ("layer", ["background", "pixel", "empty", "text", "shape", "embedded"]),
        ("selection", ["none", "rect"]),
        ("selectionMode", SelectionMode.allCases.map(\.rawValue)),
        ("sampleAllLayers", ["no", "yes"]),
        ("size", ["1", "30", "400"]),
        ("gesture", ["tap", "drag", "loop", "edge", "outside", "hold"]),
    ]

    /// Every tool, with every pair of these options, through the canvas's touch handlers.
    func runTools() {
        let rows = Pairs.rows(Self.toolFactors.map(\.values.count))
        for tool in Tool.allCases {
            let ids = rows.map { row in "tool|\(tool.rawValue)|" + Self.toolFactors.indices.map { Self.toolFactors[$0].values[row[$0]] }.joined(separator: "-") }
            if ids.allSatisfy(isDone) { continue }
            resetModel()
            var changedOnce = false
            let ranAll = ids.allSatisfy { !isDone($0) }
            for (row, id) in zip(rows, ids) {
                let v = Self.toolFactors.indices.map { Self.toolFactors[$0].values[row[$0]] }
                // What the tool works on: a selection to patch, a path's anchors, slices.
                let selection = [.patch, .contentAwareMove].contains(tool) ? "rect" : v[3]
                let extra = [.addAnchor, .deleteAnchor, .convertPoint, .pathSelect, .directSelect].contains(tool) ? "path" : tool == .sliceSelect ? "slices" : "none"
                let f = Fixture([v[0], v[1], v[2], selection, "no", extra, "small"])
                record(id: id, command: "tool.\(tool.rawValue)", fixture: f.name, params: v[4...].joined(separator: " ")) { r in
                    _ = try? model.editor.execute(id: "file.closeAll", params: "{}")
                    model.sync()
                    if let why = f.build(in: model) { r.outcome = "fixture"; r.message = why; return }
                    model.canvasResized(width: 400, height: 400, scale: 1)
                    let canvas = CanvasUIView(model: model)
                    canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
                    model.tool = tool
                    model.selectionMode = SelectionMode(rawValue: v[4]) ?? .replace
                    model.sampleAllLayers = v[5] == "yes"
                    model.setBrush("size", Double(v[6]) ?? 30)
                    model.toast = nil
                    let docID = model.doc?.id
                    let before = fingerprint()
                    // Tools that need something first: a source, or separate taps.
                    if [.clone, .heal, .patternStamp].contains(tool) {
                        canvas.mode = .tool
                        canvas.held(Point(x: 1, y: 1))
                    }
                    if tool == .perspectiveCrop {
                        let (w, h) = (Float(f.width), Float(f.height))
                        for (x, y) in [(0.1, 0.1), (0.9, 0.15), (0.85, 0.9), (0.15, 0.85)] as [(Float, Float)] { canvas.omegaTap(Point(x: x * w, y: y * h)) }
                    }
                    if tool == .polygonLasso {
                        let (w, h) = (Float(f.width), Float(f.height))
                        for (x, y) in [(0.2, 0.2), (0.8, 0.3), (0.5, 0.8), (0.2, 0.2)] as [(Float, Float)] { canvas.omegaTap(Point(x: x * w, y: y * h)) }
                    }
                    if [.patch, .contentAwareMove].contains(tool) {
                        // Grab the selection and move it, inside the canvas.
                        let (w, h) = (Float(f.width), Float(f.height))
                        canvas.omegaDrag([Point(x: 0.3 * w, y: 0.4 * h), Point(x: 0.6 * w, y: 0.6 * h)])
                    } else if tool != .perspectiveCrop {
                        // Perspective Crop's four corners are in: another touch would start again.
                        gesture(v[7], on: canvas, f)
                    }
                    // A tool that asks for text (Type, Note) gets some, as a person would type it.
                    if let prompt = model.prompt {
                        model.prompt = nil
                        prompt.done("Omega")
                    }
                    // The Frame tool asks for a picture for its box: one from the Place sheet.
                    if model.request == .placeFiles, model.pendingFrame != nil {
                        model.request = nil
                        model.placeAll([Self.samples.appendingPathComponent("bee.jpg")])
                    }
                    model.commitPending()
                    let end = Date().addingTimeInterval(Self.deadline)
                    while model.busy || model.liveBusy {
                        if Date() > end { r.outcome = "hang"; r.problems.append("still busy after \(Int(Self.deadline)) s"); resetModel(); return }
                        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                    }
                    model.sync()
                    r.message = model.toast
                    r.problems += Self.messageProblems(model.toast)
                    guard model.doc?.id == docID, let before, let after = fingerprint(), Self.document(after) != Self.document(before) else { return }
                    changedOnce = true
                    r.undoSteps = undo(to: before, max: 8)
                    if r.undoSteps == nil {
                        r.problems.append("Undo doesn't bring back the document")
                    } else if let n = r.undoSteps, redo(n).map(Self.document) != Self.document(after) {
                        r.problems.append("Redo doesn't bring back the result")
                    }
                }
            }
            // Only from a full set of this tool's cases: a resumed run has some from before.
            if OmegaCatalog.toolsThatOnlyLook[tool.rawValue] == nil, ranAll {
                record(id: "tool|\(tool.rawValue)|changes something", command: "tool.\(tool.rawValue)", fixture: "", params: "") { r in
                    if !changedOnce { r.problems.append("changed the document in none of its \(rows.count) cases") }
                }
            }
        }
    }

    private func gesture(_ kind: String, on canvas: CanvasUIView, _ f: Fixture) {
        let (w, h) = (Float(f.width), Float(f.height))
        let p = { (x: Float, y: Float) in Point(x: x * w, y: y * h) }
        switch kind {
        case "tap": canvas.omegaTap(p(0.5, 0.5))
        case "drag": canvas.omegaDrag([p(0.2, 0.3), p(0.8, 0.7)])
        case "loop": canvas.omegaDrag([p(0.3, 0.3), p(0.7, 0.3), p(0.7, 0.7), p(0.3, 0.7), p(0.3, 0.32)], steps: 16)
        case "edge": canvas.omegaDrag([p(0, 0), p(1, 1)])
        case "outside": canvas.omegaDrag([p(-0.5, -0.5), p(1.5, 0.4)])
        default: canvas.omegaDrag([p(0.5, 0.5), p(0.5, 0.5)], steps: 2, hold: 0.8)
        }
    }
}

@MainActor
extension CanvasUIView {
    /// One finger through `points` (document coordinates), as the tool unit tests drive it.
    func omegaDrag(_ points: [Point], steps: Int = 6, hold: Double = 0) {
        guard let first = points.first else { return }
        gesture = (1, 0, false)
        var time = 100.0
        toolBegan(ToolTouch(toScreen(first), time: time), modifiers: [], alt: false)
        time += hold
        for (a, b) in zip(points, points.dropFirst()) {
            let (pa, pb) = (toScreen(a), toScreen(b))
            for i in 1...max(steps, 1) {
                time += 0.02
                let t = CGFloat(i) / CGFloat(max(steps, 1))
                toolMoved(ToolTouch(CGPoint(x: pa.x + (pb.x - pa.x) * t, y: pa.y + (pb.y - pa.y) * t), time: time), modifiers: [])
            }
        }
        toolEnded(ToolTouch(toScreen(points.last ?? first), time: time + 0.02), modifiers: [])
    }

    func omegaTap(_ p: Point) {
        gesture = (1, 0, false)
        toolBegan(ToolTouch(toScreen(p), time: 100), modifiers: [], alt: false)
        toolEnded(ToolTouch(toScreen(p), time: 100.1), modifiers: [])
    }
}
