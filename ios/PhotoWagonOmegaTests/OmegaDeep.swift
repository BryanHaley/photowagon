import Foundation
import UIKit
@testable import PhotoWagon

/// The deeper checks (plan/omega-e2e.md, section 5.3, checks 5 to 9): each command once per kind
/// of document, then saved and reopened, compared across bit depths, compared with its reference
/// picture, and timed on a big document.
extension Omega {
    /// Every command Omega runs, with its default settings filled in.
    func commandsWithDefaults(where include: (CommandInfo) -> Bool = { _ in true }) -> [(CommandInfo, [String: Any])] {
        model.editor.allCommands().filter { include($0) && OmegaCatalog.skipped[$0.id] == nil }.map { c in
            var p = OmegaCatalog.fixedParams[c.id] ?? [:]
            for f in model.editor.commandFields(id: c.id) where p[f.name] == nil {
                p[f.name] = Self.values(f.kind).first
            }
            return (c, p)
        }
    }

    /// Builds `f`, runs the command's setup and the command: nil if it worked, else why not
    /// (`outcome` says which step).
    func prepareAndRun(_ id: String, _ params: [String: Any], on f: Fixture, _ r: inout OmegaResult, deadline: TimeInterval = Omega.deadline) -> Bool {
        _ = try? model.editor.execute(id: "file.closeAll", params: "{}")
        model.sync()
        if let why = f.build(in: model) {
            r.outcome = "fixture"
            r.message = why
            return false
        }
        let out = folder.appendingPathComponent("out")
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (sid, sp) in OmegaCatalog.setup[id] ?? [] {
            guard let answer = try? model.editor.execute(id: sid, params: json(resolve(sp, f, out: out) as? [String: Any] ?? sp)) else {
                r.outcome = "fixture"
                r.message = "setup \(sid) refused"
                return false
            }
            noteSetup(answer)
        }
        let p = json(resolve(params, f, out: out) as? [String: Any] ?? params)
        r.params = p
        switch execute(id, p, deadline: deadline) {
        case .none:
            r.outcome = "hang"
            r.problems.append("no answer within \(Int(deadline)) s")
            resetModel()
            return false
        case let .some(.failure(error)):
            r.outcome = "refused"
            model.show(error)
            r.message = model.toast
            r.problems += Self.messageProblems(r.message)
            return false
        case .some(.success):
            model.sync()
            return true
        }
    }

    func contentFingerprint() -> String? {
        guard let out = try? model.editor.execute(id: "document.fingerprint", params: json(["content": true])),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { return nil }
        return obj["hash"] as? String
    }

    /// Composite mean per channel and spread of the front document.
    func composite() -> [Double]? {
        guard let out = try? model.editor.execute(id: "document.stats", params: "{}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let mean = obj["mean"] as? [Double], let sd = obj["stddev"] as? [Double] else { return nil }
        return mean + sd
    }

    // MARK: - Check 5: save and reopen

    static let roundTripFixtures: [Fixture] = [
        Fixture(["rgb", "8", "pixel", "rect", "yes", "none", "small"]),
        Fixture(["cmyk", "16", "text", "none", "no", "channel", "small"]),
        Fixture(["lab", "32", "group", "feathered", "no", "path", "small"]),
        Fixture(["grayscale", "8", "shape", "none", "yes", "guides", "small"]),
    ]

    /// Each command's result saved as `.pcraft` (must reopen exactly), PSD and PNG (must look the
    /// same within rounding).
    func runRoundTrips() {
        for (c, params) in commandsWithDefaults() {
            let ids = Self.roundTripFixtures.map { "saveReopen|\(c.id)|\($0.name)" }
            if ids.allSatisfy(isDone) { continue }
            resetModel()
            for f in Self.roundTripFixtures {
                record(id: "saveReopen|\(c.id)|\(f.name)", command: c.id, fixture: f.name, params: json(params)) { r in
                    guard prepareAndRun(c.id, params, on: f, &r), let before = contentFingerprint(), let look = composite(),
                          let original = try? model.editor.export(format: "pcraft", quality: nil) else { return }
                    for format in ["pcraft", "psd", "png"] {
                        _ = try? model.editor.open(name: "omega.pcraft", bytes: original, allowPreview: false)
                        guard let bytes = try? model.editor.export(format: format, quality: nil) else {
                            r.problems.append("couldn't save as \(format)")
                            continue
                        }
                        do { _ = try model.editor.open(name: "omega.\(format)", bytes: bytes, allowPreview: false) } catch {
                            r.problems.append("couldn't reopen its own \(format): \(error)")
                            continue
                        }
                        model.sync()
                        if format == "pcraft", contentFingerprint() != before {
                            r.problems.append("reopened .pcraft differs")
                        } else if format != "pcraft", OmegaCatalog.flatExportDiffers[c.id] == nil, let after = composite(), Self.differ(look, after, by: format == "png" ? 0.01 : 0.004) {
                            r.problems.append("reopened \(format) looks different: \(Self.round(look)) → \(Self.round(after))")
                        }
                    }
                }
            }
        }
    }

    static func differ(_ a: [Double], _ b: [Double], by tolerance: Double) -> Bool {
        a.count != b.count || zip(a, b).contains { abs($0 - $1) > tolerance }
    }

    static func round(_ v: [Double]) -> [Double] { v.map { ($0 * 1000).rounded() / 1000 } }

    // MARK: - Check 6: the same result at every depth

    /// Each command at 8, 16 and 32 bits: how much it changes what the screen shows must agree.
    /// (The engine's own statistics are linear at 32 bits, so the rendered preview is compared.)
    func runDepths() {
        // First the documents themselves: converted to 16 or 32 bits, the same image must look the
        // same. A depth where it doesn't can't be compared command by command.
        var comparable: Set<Int> = [8]
        var looks: [Int: [Double]] = [:]
        for depth in [8, 16, 32] {
            _ = try? model.editor.execute(id: "file.closeAll", params: "{}")
            model.sync()
            if Fixture(["rgb", "\(depth)", "pixel", "rect", "no", "none", "small"]).build(in: model) == nil { looks[depth] = shown() }
        }
        for depth in [16, 32] {
            let same = looks[8].flatMap { a in looks[depth].map { !Self.differ(a, $0, by: 0.01) } } ?? false
            if same { comparable.insert(depth) }
            record(id: "depths|document at \(depth) bits", command: "image.mode.bits\(depth)", fixture: "rgb-pixel-rect", params: "") { r in
                guard let a = looks[8], let b = looks[depth] else { r.outcome = "fixture"; return }
                if !same { r.problems.append("the same image looks different at \(depth) bits: \(Self.round(a)) → \(Self.round(b))") }
            }
        }
        for (c, params) in commandsWithDefaults(where: { !$0.id.hasPrefix("image.mode.bits") }) {
            let id = "depths|\(c.id)"
            if isDone(id) { continue }
            resetModel()
            record(id: id, command: c.id, fixture: "rgb-pixel-rect at 8, 16, 32", params: json(params)) { r in
                var change: [Int: [Double]] = [:]
                for depth in [8, 16, 32] {
                    let f = Fixture(["rgb", "\(depth)", "pixel", "rect", "no", "none", "small"])
                    var probe = OmegaResult(id: id, command: c.id, fixture: f.name, params: "", outcome: "ok", problems: [], ms: 0)
                    _ = try? model.editor.execute(id: "file.closeAll", params: "{}")
                    model.sync()
                    guard f.build(in: model) == nil, let before = shown() else { continue }
                    _ = try? model.editor.execute(id: "file.closeAll", params: "{}")
                    guard prepareAndRun(c.id, params, on: f, &probe), let after = shown() else {
                        if probe.outcome == "hang" { r.outcome = "hang"; r.problems += probe.problems; return }
                        continue
                    }
                    change[depth] = zip(after, before).map { $0 - $1 }
                }
                guard let at8 = change[8] else { r.outcome = "refused"; return }
                for (depth, tolerance) in [(16, 0.02), (32, 0.03)] where comparable.contains(depth) {
                    if depth == 32, OmegaCatalog.differsAt32Bits[c.id] != nil { continue }
                    if let d = change[depth], Self.differ(at8, d, by: tolerance) {
                        r.problems.append("at \(depth) bits it changes the image differently: \(Self.round(at8)) vs \(Self.round(d))")
                    }
                }
            }
        }
    }

    /// The mean of each channel of the rendered preview, 0 to 1.
    func shown() -> [Double]? {
        guard let png = try? model.editor.previewImage(maxSide: 64), let px = Self.rgba(png) else { return nil }
        var sum = [Double](repeating: 0, count: 4)
        for i in stride(from: 0, to: px.bytes.count, by: 4) {
            for k in 0..<4 { sum[k] += Double(px.bytes[i + k]) }
        }
        let n = Double(max(px.width * px.height, 1)) * 255
        return sum.map { $0 / n }
    }

    // MARK: - Check 7: reference pictures

    /// Approved pictures: `$OMEGA_BASELINES/pictures/<command>.png` (the runner points it at the
    /// baselines checkout); this run's go to `<section>/pictures/`.
    static var baselines: URL? {
        ProcessInfo.processInfo.environment["OMEGA_BASELINES"].map { URL(fileURLWithPath: $0) }
    }

    /// Each command on a small photo, compared with its approved picture.
    func runPictures() {
        let pictures = folder.appendingPathComponent("pictures")
        try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        let photo = Self.samples.appendingPathComponent("beach.jpg")
        for (c, params) in commandsWithDefaults() {
            let id = "picture|\(c.id)"
            if isDone(id) { continue }
            resetModel()
            record(id: id, command: c.id, fixture: "beach.jpg at 160 px", params: json(params)) { r in
                guard let bytes = try? Data(contentsOf: photo),
                      (try? model.editor.open(name: "beach.jpg", bytes: bytes, allowPreview: false)) != nil,
                      (try? model.editor.execute(id: "image.imageSize", params: json(["width": 160, "resample": "bicubic"]))) != nil else {
                    r.outcome = "fixture"
                    r.message = "couldn't open beach.jpg at 160 px"
                    return
                }
                model.sync()
                let p = json(resolve(params, Fixture(["rgb", "8", "background", "none", "no", "none", "small"]), out: folder.appendingPathComponent("out")) as? [String: Any] ?? params)
                r.params = p
                switch execute(c.id, p) {
                case .none: r.outcome = "hang"; r.problems.append("no answer"); resetModel(); return
                case let .some(.failure(error)): r.outcome = "refused"; model.show(error); r.message = model.toast; return
                case .some(.success): model.sync()
                }
                guard let png = try? model.editor.previewImage(maxSide: 160) else { return }
                let name = c.id + ".png"
                try? png.write(to: pictures.appendingPathComponent(name))
                guard let base = Self.baselines?.appendingPathComponent("pictures").appendingPathComponent(name),
                      let reference = try? Data(contentsOf: base) else {
                    r.problems.append("no reference picture yet (look at it, then `cargo xtask omega accept`)")
                    return
                }
                if let share = Self.pixelsDiffer(png, reference), share > 0.01 {
                    r.problems.append("looks different from its reference picture: \(Int(share * 100))% of pixels")
                }
            }
        }
    }

    /// The share of pixels that differ by more than 10 of 255 in any channel; 1 if the sizes differ.
    static func pixelsDiffer(_ a: Data, _ b: Data) -> Double? {
        guard let x = rgba(a), let y = rgba(b) else { return nil }
        guard x.width == y.width, x.height == y.height else { return 1 }
        var differ = 0
        for i in stride(from: 0, to: min(x.bytes.count, y.bytes.count), by: 4) {
            if (0..<4).contains(where: { abs(Int(x.bytes[i + $0]) - Int(y.bytes[i + $0])) > 10 }) { differ += 1 }
        }
        return Double(differ) / Double(max(x.width * x.height, 1))
    }

    static func rgba(_ png: Data) -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let image = UIImage(data: png)?.cgImage else { return nil }
        let (w, h) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (w, h, bytes) : nil
    }

    // MARK: - Checks 8 and 9: speed and memory

    /// Each command on a 24 MP document: its time against the approved timings
    /// (`$OMEGA_BASELINES/timings.json`), and the app's memory after it.
    func runSpeed() {
        let timings = (Self.baselines.flatMap { try? Data(contentsOf: $0.appendingPathComponent("timings.json")) })
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Double] } ?? [:]
        let big = Fixture(["rgb", "8", "pixel", "rect", "no", "none", "big"])
        for (c, params) in commandsWithDefaults() {
            let id = "speed|\(c.id)"
            if isDone(id) { continue }
            resetModel()
            record(id: id, command: c.id, fixture: "6000 × 4000 RGB 8-bit", params: json(params)) { r in
                _ = try? model.editor.execute(id: "file.closeAll", params: "{}")
                for (sid, sp) in Self.bigDocument {
                    guard (try? model.editor.execute(id: sid, params: json(sp))) != nil else { r.outcome = "fixture"; r.message = sid; return }
                }
                model.sync()
                let p = json(resolve(params, big, out: folder.appendingPathComponent("out")) as? [String: Any] ?? params)
                r.params = p
                let start = Date()
                switch execute(c.id, p, deadline: 300) {
                case .none: r.outcome = "hang"; r.problems.append("no answer within 300 s"); resetModel(); return
                case let .some(.failure(error)): r.outcome = "refused"; model.show(error); r.message = model.toast
                case .some(.success): break
                }
                let ms = Date().timeIntervalSince(start) * 1000
                let mb = Self.memoryMB()
                r.message = (r.message.map { $0 + "; " } ?? "") + "\(Int(ms)) ms, \(Int(mb)) MB"
                if let base = timings[c.id], ms > 500, ms > base * 2 { r.problems.append("slower: \(Int(ms)) ms, was \(Int(base)) ms") }
                if mb > 3000 { r.problems.append("memory over 3 GB: \(Int(mb)) MB") }
            }
        }
    }

    static let bigDocument: [(String, [String: Any])] = [
        ("file.new", ["width": 6000, "height": 4000, "name": "big"]),
        ("select.rect", ["x": 600, "y": 400, "width": 3000, "height": 2000]),
        ("edit.fill", ["color": "#c04020"]),
        ("layer.new.layer", [:]),
        ("paint.stroke", ["points": [[200, 3600], [5600, 400]], "color": "#2060d0", "size": 300]),
        ("select.rect", ["x": 1200, "y": 900, "width": 2400, "height": 1600]),
    ]

    /// The app's memory footprint now, in MB.
    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
