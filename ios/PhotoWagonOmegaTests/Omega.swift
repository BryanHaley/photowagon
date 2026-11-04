import Foundation
import UIKit
import XCTest
@testable import PhotoWagon

/// One Omega case: a command, its settings and the document it runs on.
struct OmegaCase {
    var command: String
    var fixture: Fixture
    var params: [String: Any]

    var paramsJSON: String { json(params) }
    var id: String { "\(command)|\(fixture.name)|\(paramsJSON)" }
}

/// What a case did and what went wrong, one JSON line in `results.jsonl`.
struct OmegaResult: Codable {
    var id: String
    var command: String
    var fixture: String
    var params: String
    /// ok, refused, fixture (the document couldn't be built), hang, crash
    var outcome: String
    var message: String?
    var undoSteps: Int?
    var problems: [String]
    var ms: Int
}

/// Tier B: runs cases inside the app through the same engine and `EditorModel` the buttons use,
/// and checks each one (section 5.3 of plan/omega-e2e.md).
@MainActor
final class Omega {
    /// A fresh one for each command, so nothing one command leaves behind (settings, presets,
    /// swatches) changes how the next one behaves.
    private(set) var model = Omega.freshModel()

    static func freshModel() -> EditorModel {
        // Presets and recorded actions live on disk, not in the defaults.
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("Presets"))
        }
        return EditorModel(defaults: UserDefaults(suiteName: "omega.\(UUID().uuidString)") ?? .standard)
    }

    func resetModel() { model = Self.freshModel() }
    let folder: URL
    private var done = Set<String>()
    /// Cases that hung in this run (each left its editor behind and went on with a new one).
    private(set) var hung = 0
    /// Cases with problems, earlier attempts at this section included.
    private(set) var failed = 0

    /// Results go to `$OMEGA_OUT/<iOS version>/<shard>` (the runner sets it), else a temporary folder.
    init(shard: String) {
        let root = ProcessInfo.processInfo.environment["OMEGA_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("omega")
        folder = root.appendingPathComponent(UIDevice.current.systemVersion).appendingPathComponent(shard)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let s = try? String(contentsOf: results, encoding: .utf8) {
            for line in s.split(separator: "\n") {
                if let r = try? JSONDecoder().decode(OmegaResult.self, from: Data(line.utf8)) {
                    done.insert(r.id)
                    if !r.problems.isEmpty { failed += 1 }
                }
            }
        }
        // A case that started and never wrote its result crashed the app.
        if let id = try? String(contentsOf: current, encoding: .utf8), !id.isEmpty, !done.contains(id) {
            let parts = id.split(separator: "|", maxSplits: 2).map(String.init)
            write(OmegaResult(id: id, command: parts.first ?? id, fixture: parts.count > 1 ? parts[1] : "", params: parts.count > 2 ? parts[2] : "",
                              outcome: "crash", message: nil, undoSteps: nil, problems: ["the app crashed or was stopped during this case"], ms: 0))
        }
    }

    /// Written when the section finishes: a section without it crashed or hung.
    func finish() {
        let status: [String: Any] = ["status": failed > 0 ? "fail" : "pass", "cases": done.count, "failed": failed, "hung": hung]
        try? JSONSerialization.data(withJSONObject: status).write(to: folder.appendingPathComponent("status.json"))
        // The Rust core's line counts, in a coverage build (`OMEGA_RUST_COVERAGE` is their folder).
        if let dir = ProcessInfo.processInfo.environment["OMEGA_RUST_COVERAGE"] {
            _ = coverageWrite(path: "\(dir)/\(folder.lastPathComponent)-\(UUID().uuidString).profraw")
        }
    }

    private var results: URL { folder.appendingPathComponent("results.jsonl") }
    private var current: URL { folder.appendingPathComponent("current.txt") }

    private func write(_ r: OmegaResult) {
        done.insert(r.id)
        if !r.problems.isEmpty { failed += 1 }
        guard let data = try? JSONEncoder().encode(r) else { return }
        if let h = try? FileHandle(forWritingTo: results) {
            h.seekToEndOfFile()
            h.write(data + Data("\n".utf8))
            try? h.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: results)
        }
    }

    // MARK: - Cases

    /// Each command's cases: every pair of the document's factors and the command's own settings.
    func cases(for command: CommandInfo) -> [OmegaCase] {
        let fields = model.editor.commandFields(id: command.id)
        let fieldValues = fields.map { Self.values($0.kind) }
        let sizes = Fixture.factors.map(\.values.count) + fieldValues.map(\.count)
        let fixed = OmegaCatalog.fixedParams[command.id] ?? [:]
        return Pairs.rows(sizes).map { row in
            let f = Fixture(Fixture.factors.indices.map { Fixture.factors[$0].values[row[$0]] })
            var params = fixed
            for (i, field) in fields.enumerated() where params[field.name] == nil {
                params[field.name] = fieldValues[i][row[Fixture.factors.count + i]]
            }
            return OmegaCase(command: command.id, fixture: f, params: params)
        }
    }

    /// A setting's values: its default, its ends and one odd value; every choice; both toggles.
    static func values(_ kind: FieldKind) -> [Any] {
        switch kind {
        case let .number(min, max, value, whole):
            var v = [value]
            if let min { v.append(min) }
            if let max { v.append(max) }
            let lo = min ?? value - 10, hi = max ?? value + 10
            v.append(whole ? ((lo + hi) / 3).rounded() : lo + (hi - lo) * 0.37)
            return unique(v.map { whole ? $0.rounded() : $0 })
        case let .choice(options, value):
            return capped(unique([value] + options))
        case let .toggle(value):
            return [value, !value]
        case let .text(value):
            return unique([value, "", "Omega ✓ ünïcode text"])
        case let .color(options, value):
            return capped(unique([value.isEmpty ? "#ff0000" : value, "#00ff80"] + options))
        }
    }

    private static func unique<T: Hashable>(_ v: [T]) -> [T] {
        var seen = Set<T>()
        return v.filter { seen.insert($0).inserted }
    }

    /// Very long lists (every font): an even spread of 16, so pairs stay affordable.
    private static func capped(_ v: [String]) -> [String] {
        guard v.count > 16 else { return v }
        return (0..<16).map { v[$0 * v.count / 16] }
    }

    // MARK: - Running

    /// Runs the cases of every command `include` picks, skipping those already done.
    func runCommands(where include: (CommandInfo) -> Bool) {
        let commands = model.editor.allCommands().filter { include($0) && OmegaCatalog.skipped[$0.id] == nil }
        for c in commands {
            let left = cases(for: c).filter { !done.contains($0.id) }
            if left.isEmpty { continue }
            resetModel()
            for k in left {
                autoreleasepool { run(k) }
            }
        }
    }

    /// Runs one case unless it's already done: notes it as started (so a crash is seen), times it
    /// and writes what `body` found.
    func record(id: String, command: String, fixture: String, params: String, _ body: (inout OmegaResult) -> Void) {
        guard !done.contains(id) else { return }
        let start = Date()
        try? Data(id.utf8).write(to: current)
        var r = OmegaResult(id: id, command: command, fixture: fixture, params: params, outcome: "ok", problems: [], ms: 0)
        autoreleasepool { body(&r) }
        r.ms = Int(Date().timeIntervalSince(start) * 1000)
        write(r)
    }

    func isDone(_ id: String) -> Bool { done.contains(id) }

    func run(_ k: OmegaCase) {
        record(id: k.id, command: k.command, fixture: k.fixture.name, params: k.paramsJSON) { r in check(k, &r) }
    }

    private func check(_ k: OmegaCase, _ r: inout OmegaResult) {
        _ = try? model.editor.execute(id: "file.closeAll", params: "{}")
        model.sync()
        if let why = k.fixture.build(in: model) {
            r.outcome = "fixture"
            r.message = why
            return
        }
        let out = folder.appendingPathComponent("out")
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let fill = { (v: [String: Any]) in self.resolve(v, k.fixture, out: out) as? [String: Any] ?? v }
        for (id, p) in OmegaCatalog.setup[k.command] ?? [] {
            do { noteSetup(try model.editor.execute(id: id, params: json(fill(p)))) } catch {
                r.outcome = "fixture"
                r.message = "setup \(id): \(error)"
                return
            }
        }
        model.sync()
        let params = json(fill(k.params))
        r.params = params
        let before = fingerprint()
        let enabled = model.editor.allCommands().first { $0.id == k.command }
        let docID = model.doc?.id

        switch execute(k.command, params) {
        case .none:
            // The stuck command keeps the old editor; the next case gets a fresh one.
            r.outcome = "hang"
            r.problems.append("no answer within \(Int(Self.deadline)) s")
            hung += 1
            resetModel()
            return
        case let .some(.failure(error)):
            r.outcome = "refused"
            model.show(error)
            r.message = model.toast
        case .some(.success):
            break
        }
        model.sync()
        r.problems += Self.messageProblems(r.message)

        // Only where a person can reach the command: in a menu the app shows.
        if r.outcome == "refused", let enabled, enabled.enabled, !enabled.menu.isEmpty, MenuTree.shows(enabled),
           r.message?.contains(k.command) == true {
            r.problems.append("internal command name in the message")
        }
        let mayRunGreyed = OmegaCatalog.runsWhenGreyed[k.command].map { k.params[$0.param] as? Bool == true } ?? false
        if r.outcome == "ok", enabled?.enabled == false, !mayRunGreyed {
            r.problems.append("ran although greyed out (\(enabled?.reason ?? "no reason"))")
        }
        // Another document in front (New, Duplicate, Close): its own state, nothing to compare.
        guard model.doc?.id == docID, let before else { return }
        let after = fingerprint()
        if r.outcome == "refused" {
            if after != before { r.problems.append("refused but changed the document") }
            return
        }
        // Which layer is active isn't a history step: Undo and Redo compare the document only.
        guard let after, Self.document(after) != Self.document(before) else { return }
        if OmegaCatalog.historyCommands.contains(k.command) || OmegaCatalog.notUndoable[k.command] != nil { return }
        r.undoSteps = undo(to: before, max: 8)
        if r.undoSteps == nil {
            r.problems.append("Undo doesn't bring back the document")
        } else if let n = r.undoSteps, redo(n).map(Self.document) != Self.document(after) {
            r.problems.append("Redo doesn't bring back the result")
        }
    }

    // MARK: - Placeholders (see OmegaCatalog.fixedParams)

    static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PhotoWagonUITests/Samples")

    /// A folder of two JPEGs, made once.
    private lazy var jpgs: URL = {
        let dir = folder.appendingPathComponent("jpgs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in ["beach.jpg", "bee.jpg"] {
            try? FileManager.default.copyItem(at: Self.samples.appendingPathComponent(f), to: dir.appendingPathComponent(f))
        }
        return dir
    }()

    /// Two overlapping photos of one size, made once.
    private lazy var overlap: URL = {
        let dir = folder.appendingPathComponent("overlap")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = UIImage(contentsOfFile: Self.samples.appendingPathComponent("seaside.jpg").path)?.cgImage
        for (name, x) in [("a.jpg", 300), ("b.jpg", 540)] {
            if let part = photo?.cropping(to: CGRect(x: x, y: 300, width: 480, height: 360)) {
                try? UIImage(cgImage: part).jpegData(compressionQuality: 0.9)?.write(to: dir.appendingPathComponent(name))
            }
        }
        return dir
    }()

    /// A small presets file.
    private lazy var presets: URL = {
        let file = folder.appendingPathComponent("presets.json")
        try? Data(#"{"gradients":[]}"#.utf8).write(to: file)
        return file
    }()

    /// What the last setup step answered, for "$RESULT:key".
    var setupResult: [String: Any] = [:]

    func noteSetup(_ answer: String) {
        setupResult = (try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any]) ?? [:]
    }

    func resolve(_ v: Any, _ f: Fixture, out: URL, key: String = "") -> Any {
        switch v {
        case let d as [String: Any]:
            return d.reduce(into: [String: Any]()) { $0[$1.key] = resolve($1.value, f, out: out, key: $1.key) }
        case let a as [Any]:
            let r = a.map { resolve($0, f, out: out) }
            // A rect's width and height are at least 1.
            if key == "rect", r.count == 4, let w = r[2] as? Int, let h = r[3] as? Int { return [r[0], r[1], max(w, 1), max(h, 1)] }
            return r
        case let s as String:
            if s.hasPrefix("@x:") || s.hasPrefix("@y:"), let frac = Double(s.dropFirst(3)) {
                let side = s.hasPrefix("@x") ? f.width : f.height
                let n = min(Int(frac * Double(side)), frac >= 1 ? side : side - 1)
                return ["width", "height"].contains(key) ? max(n, 1) : n
            }
            switch s {
            case "$LAYER": return model.activeLayer?.id ?? 0
            case "$OTHER": return model.layers.first { $0.id != model.activeLayer?.id }?.id ?? 0
            case "$IMAGE": return Self.samples.appendingPathComponent("star.png").path
            case "$PSD": return Self.samples.appendingPathComponent("design.psd").path
            case "$GBR": return Self.samples.appendingPathComponent("speckle.gbr").path
            case "$JPGS": return jpgs.path
            case "$PHOTO": return Self.samples.appendingPathComponent("seaside.jpg").path
            case "$OVERLAP": return overlap.path
            case "$PRESETS": return presets.path
            case _ where s.hasPrefix("$RESULT:"): return setupResult[String(s.dropFirst(8))] ?? 0
            case "$ATN": return Self.formats.appendingPathComponent("many-steps.atn").path
            case "$ABR": return Self.formats.appendingPathComponent("brushes-v6.abr").path
            case "$GRD": return Self.formats.appendingPathComponent("gradients.grd").path
            case "$ACO": return Self.formats.appendingPathComponent("swatches.aco").path
            case "$NOTES": return Self.formats.appendingPathComponent("notes.psd").path
            case "$CSV": return Self.formats.appendingPathComponent("datasets.csv").path
            case "$GIF": return Self.formats.appendingPathComponent("clip.gif").path
            case "$FRAMES": return Self.formats.appendingPathComponent("frames").path
            case "$WASM": return Self.formats.appendingPathComponent("omega-invert.wasm").path
            case "$FORMATS": return Self.formats.path
            default: return s.hasPrefix("$OUT") ? out.path + s.dropFirst(4) : s
            }
        default:
            return v
        }
    }

    // MARK: - Checks

    /// A Rust coverage build runs the engine several times slower.
    static let deadline: TimeInterval = ProcessInfo.processInfo.environment["OMEGA_RUST_COVERAGE"] == nil ? 60 : 300

    /// Runs off the main thread so a hang can be caught; `nil` if it didn't finish in time.
    func execute(_ id: String, _ params: String, deadline: TimeInterval = Omega.deadline) -> Result<String, Error>? {
        let editor = model.editor
        let box = OmegaBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(Result { try editor.execute(id: id, params: params) })
            done.signal()
        }
        // Keep the main run loop turning: some commands hop to it.
        let end = Date().addingTimeInterval(deadline)
        while done.wait(timeout: .now()) == .timedOut {
            if Date() > end { return nil }
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        return box.get()
    }

    func fingerprint() -> String? {
        guard case let .success(out)? = execute("document.fingerprint", "{}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { return nil }
        return "\(obj["hash"] ?? "")/\(obj["activeLayer"] ?? "-")"
    }

    /// The document's part of a fingerprint, without the active layer.
    static func document(_ fingerprint: String) -> Substring { fingerprint.split(separator: "/").first ?? "" }

    /// Undo until the document matches `target`: how many steps that took, or `nil`.
    func undo(to target: String, max: Int) -> Int? {
        for n in 1...max {
            guard (try? model.editor.execute(id: "edit.undo", params: "{}")) != nil else { return nil }
            if fingerprint().map(Self.document) == Self.document(target) { return n }
        }
        return nil
    }

    func redo(_ n: Int) -> String? {
        for _ in 0..<n { _ = try? model.editor.execute(id: "edit.redo", params: "{}") }
        return fingerprint()
    }

    /// A refusal must say something a person can act on.
    static func messageProblems(_ message: String?) -> [String] {
        guard let m = message else { return [] }
        var p: [String] = []
        let t = m.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { p.append("empty error message") }
        if t.lowercased() == "error" || t.lowercased().hasSuffix("error") && t.count < 12 { p.append("bare error message") }
        if m.contains("panicked") || m.contains("panic") { p.append("panic: \(m)") }
        if m.contains("Some(") || m.contains("Err(") || m.contains("unwrap") || m.contains("RUST_BACKTRACE") { p.append("developer text in the message") }
        if m.count > 400 { p.append("message over 400 characters") }
        return p
    }
}

/// Hands a result from a worker thread back to the main thread.
final class OmegaBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<String, Error>?
    func set(_ v: Result<String, Error>) { lock.lock(); value = v; lock.unlock() }
    func get() -> Result<String, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}
