import AVFoundation
import Foundation
import UIKit
@testable import PhotoWagon

/// The Files section: real files of every format and import (Samples/formats, made by the engine's
/// `make_omega_files` example) opened, saved and reopened; and the settings screens walked.
extension Omega {
    static let formats = samples.appendingPathComponent("formats")

    private static func file(_ name: String) -> String { formats.appendingPathComponent(name).path }

    /// Files that aren't pictures (presets, actions, a plug-in, a table).
    private static let notPictures: Set<String> = ["abr", "aco", "ase", "atn", "csv", "grd", "pat", "shc", "wasm"]

    /// Every format the app can save, in the order tried on each opened file.
    private static let saveFormats = ["pcraft", "psd", "psb", "tif", "png", "exr", "dpx", "fits", "webp", "jpg", "ora", "bmp", "gif", "tga", "qoi", "ico", "hdr", "pfm", "ppm", "jxl"]

    /// Written but not read back: the app only makes these.
    private static let writeOnly = ["pdf"]

    /// Saved and reopened, these must look the same.
    private static let lossless: Set<String> = ["pcraft", "psd", "psb", "tif", "png"]

    /// The preview of the plain PNG all `rgb…` files were written from.
    private static let referenceLook: Data? = {
        let editor = EditorModel().editor
        guard let bytes = try? Data(contentsOf: formats.appendingPathComponent("rgb8.png")),
              (try? editor.open(name: "rgb8.png", bytes: bytes, allowPreview: false)) != nil else { return nil }
        return try? editor.previewImage(maxSide: 64)
    }()

    private static let pictures: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: formats.path)) ?? []
        return names.filter { !notPictures.contains(($0 as NSString).pathExtension.lowercased()) && !$0.hasPrefix(".") && $0 != "frames" }.sorted()
    }()

    func runFiles() {
        record(id: "files|the files are there", command: "files", fixture: "", params: "") { r in
            if Self.pictures.count < 50 { r.problems.append("only \(Self.pictures.count) pictures in \(Self.formats.path)") }
        }
        for name in Self.pictures {
            openAndSave(name)
            place(name)
        }
        for name in Self.pictures where ["dng", "cr2", "rw2", "orf", "nef", "arw", "raf"].contains((name as NSString).pathExtension.lowercased()) {
            develop(name)
        }
        for name in Self.pictures where name.hasSuffix(".exr") { exrParts(name) }
        fileCommands()
        saveOptions()
        brushes()
        gradients()
        swatches()
        patterns()
        actions()
        plugin()
        video()
        imports()
        prefsWalk()
        webExportWalk()
        typeStylesWalk()
    }

    // MARK: - Steps

    /// Runs a step that must work; a refusal is a problem. Its JSON answer, or nil.
    @discardableResult
    private func must(_ id: String, _ params: [String: Any] = [:], _ r: inout OmegaResult) -> [String: Any]? {
        switch execute(id, json(params)) {
        case .none:
            r.outcome = "hang"
            r.problems.append("\(id): no answer within \(Int(Self.deadline)) s")
            resetModel()
            return nil
        case let .some(.failure(error)):
            model.show(error)
            r.problems.append("\(id) refused: \(model.toast ?? "\(error)")")
            r.problems += Self.messageProblems(model.toast)
            return nil
        case let .some(.success(out)):
            model.sync()
            return (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] ?? [:]
        }
    }

    /// Runs a step that may be refused, as long as it says why in words a person can use.
    @discardableResult
    private func attempt(_ id: String, _ params: [String: Any] = [:], _ r: inout OmegaResult) -> Bool {
        switch execute(id, json(params)) {
        case .none:
            r.outcome = "hang"
            r.problems.append("\(id): no answer within \(Int(Self.deadline)) s")
            resetModel()
            return false
        case let .some(.failure(error)):
            model.show(error)
            r.problems += Self.messageProblems(model.toast).map { "\(id): \($0)" }
            r.message = (r.message.map { $0 + "; " } ?? "") + "\(id): \(model.toast ?? "\(error)")"
            return false
        case .some(.success):
            model.sync()
            return true
        }
    }

    /// A small document with a picture on a layer of its own.
    private func newDocument(_ r: inout OmegaResult, mode: String = "rgb", depth: Int = 8, layer: String = "pixel") -> Bool {
        _ = try? model.editor.execute(id: "file.closeAll", params: "{}")
        model.sync()
        if let why = Fixture([mode, "\(depth)", layer, "none", "no", "none", "small"]).build(in: model) {
            r.outcome = "fixture"
            r.message = why
            return false
        }
        return true
    }

    /// Opens through the same path as the app (our decoders, then Apple's, then LibRaw).
    private func open(_ url: URL, _ r: inout OmegaResult) -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            r.problems.append("can't read \(url.lastPathComponent)")
            return false
        }
        _ = try? model.editor.execute(id: "file.closeAll", params: "{}")
        let editor = model.editor
        let name = url.lastPathComponent
        let box = OmegaBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(Result { try EditorModel.load(editor, data, name) ?? "" })
            done.signal()
        }
        let end = Date().addingTimeInterval(Self.deadline)
        while done.wait(timeout: .now()) == .timedOut {
            if Date() > end {
                r.outcome = "hang"
                r.problems.append("opening: no answer within \(Int(Self.deadline)) s")
                resetModel()
                return false
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        if case let .failure(error)? = box.get() {
            model.show(error)
            r.problems.append("won't open: \(model.toast ?? "\(error)")")
            return false
        }
        model.sync()
        return true
    }

    private var outFolder: URL {
        let out = folder.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    private func documentSize() -> (Int, Int)? { model.doc.map { (Int($0.width), Int($0.height)) } }

    /// The commands that read a file work with what `OmegaCatalog` gives them, so the other
    /// sections' cases get past the file.
    private func fileCommands() {
        let ids: Set<String> = ["actions.load", "brush.presets.importAbr", "brush.presets.importFile", "gradient.presets.importGrd", "swatches.import",
                                "file.import.notes", "file.import.variableDataSets", "layer.videoLayers.newVideoLayerFromFile", "file.import.videoFramesToLayers",
                                "plugin.install", "plugin.reload", "plugin.run", "plugin.remove"]
        for (c, params) in commandsWithDefaults(where: { ids.contains($0.id) }) {
            record(id: "catalog|\(c.id)", command: c.id, fixture: "rgb8 pixel", params: json(params)) { r in
                resetModel()
                let f = Fixture(["rgb", "8", "pixel", "none", "no", "none", "small"])
                if !prepareAndRun(c.id, params, on: f, &r), r.outcome == "refused" {
                    r.problems.append("refused: \(r.message ?? "")")
                }
            }
        }
        _ = try? model.editor.execute(id: "plugin.remove", params: json(["id": "net.photowagon.omega.invert"]))
    }

    // MARK: - Pictures

    private func openAndSave(_ name: String) {
        record(id: "open|\(name)", command: "file.open", fixture: name, params: "") { r in
            guard open(Self.formats.appendingPathComponent(name), &r) else { return }
            guard let size = documentSize(), size.0 > 0, size.1 > 0 else {
                r.problems.append("opened with no document")
                return
            }
            guard let look = composite(), look.count >= 2 else {
                r.problems.append("no statistics for the opened document")
                return
            }
            if look[(look.count / 2)...].allSatisfy({ abs($0) < 0.0001 }) {
                r.problems.append("opened blank: every pixel the same (\(Self.round(look)))")
            }
            guard let preview = try? model.editor.previewImage(maxSide: 64) else {
                r.problems.append("no preview")
                return
            }
            // Same picture, whatever the format.
            if name.hasPrefix("rgb") || name.hasPrefix("lossless"), let reference = Self.referenceLook,
               let share = Self.pixelsDiffer(preview, reference), share > 0.05 {
                r.problems.append("doesn't look like rgb8.png: \(Int(share * 100))% of pixels differ")
            }
            guard let original = try? model.editor.export(format: "pcraft", quality: nil), let before = contentFingerprint() else {
                r.problems.append("couldn't save as .pcraft")
                return
            }
            for format in Self.saveFormats + Self.writeOnly {
                guard (try? model.editor.open(name: "omega.pcraft", bytes: original, allowPreview: false)) != nil else {
                    r.problems.append("couldn't reopen its own .pcraft")
                    return
                }
                let bytes: Data
                do { bytes = try model.editor.export(format: format, quality: nil) } catch {
                    // Not every format holds every document; the refusal must still read well.
                    model.show(error)
                    r.problems += Self.messageProblems(model.toast).map { "\(format): \($0)" }
                    r.message = (r.message.map { $0 + "; " } ?? "") + "\(format): \(model.toast ?? "\(error)")"
                    continue
                }
                if Self.writeOnly.contains(format) { continue }
                do { _ = try model.editor.open(name: "omega.\(format)", bytes: bytes, allowPreview: false) } catch {
                    r.problems.append("couldn't reopen its own \(format): \(error)")
                    continue
                }
                model.sync()
                if let again = documentSize(), again != size, format != "ico" {
                    r.problems.append("\(format) changed the size: \(size) → \(again)")
                }
                if format == "pcraft", contentFingerprint() != before { r.problems.append("reopened .pcraft differs") }
                if Self.lossless.contains(format), let again = try? model.editor.previewImage(maxSide: 64),
                   let share = Self.pixelsDiffer(preview, again), share > 0.05 {
                    r.problems.append("\(format) looks different when reopened: \(Int(share * 100))% of pixels")
                }
            }
        }
    }

    private func place(_ name: String) {
        record(id: "place|\(name)", command: "file.placeEmbedded", fixture: name, params: "") { r in
            guard newDocument(&r), attempt("file.placeEmbedded", ["path": Self.file(name)], &r) else { return }
            // An embedded layer travels in a PSD and in our own file.
            for format in ["psd", "pcraft"] {
                guard let bytes = try? model.editor.export(format: format, quality: nil) else {
                    r.problems.append("couldn't save as \(format)")
                    continue
                }
                do { _ = try model.editor.open(name: "omega.\(format)", bytes: bytes, allowPreview: false) } catch {
                    r.problems.append("couldn't reopen its own \(format): \(error)")
                }
            }
            model.sync()
        }
    }

    /// The Develop screen's settings on a raw file, one at a time.
    private func develop(_ name: String) {
        let url = Self.formats.appendingPathComponent(name)
        for f in model.editor.commandFields(id: "filter.cameraRaw") {
            for (n, value) in Self.values(f.kind).dropFirst().enumerated() {
                record(id: "develop|\(name)|\(f.name)|\(n)", command: "filter.cameraRaw", fixture: name, params: "\(f.name)=\(value)") { r in
                    guard open(url, &r), let before = fingerprint() else { return }
                    guard attempt("filter.cameraRaw", [f.name: value], &r) else { return }
                    if let after = fingerprint(), Self.document(after) != Self.document(before), undo(to: before, max: 4) == nil {
                        r.problems.append("Undo doesn't bring back the document")
                    }
                }
            }
            // One raw file walks every setting; the others just open.
            if !name.hasPrefix("cfa-uncompressed") { break }
        }
    }

    private func exrParts(_ name: String) {
        record(id: "exrParts|\(name)", command: "file.openExrParts", fixture: name, params: "") { r in
            guard newDocument(&r) else { return }
            guard case let .success(out)? = execute("file.exrParts", json(["path": Self.file(name)])),
                  let entries = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]] else {
                // A file of only deep parts has no parts to choose from.
                if !name.hasPrefix("deep") { r.problems.append("no parts listed") }
                return
            }
            var pick: [String: Any] = ["path": Self.file(name), "precomp": name == "aovs.exr"]
            for e in entries {
                if let kind = e["kind"] as? String, ["part", "group"].contains(kind), let n = e["name"] as? String { pick["\(kind)/\(n)"] = true }
            }
            if pick.count == 2 { r.problems.append("nothing to choose in \(entries)") }
            must("file.openExrParts", pick, &r)
        }
    }

    /// The options Save As offers beyond the format.
    private func saveOptions() {
        let choices: [(String, [String: Any])] = [
            ("layers.tif", ["tiffLayers": true]), ("flat.tif", ["tiffLayers": false]),
            ("a.dpx", ["dpxBits": 8]), ("b.dpx", ["dpxBits": 10]), ("c.dpx", ["dpxBits": 12]), ("d.dpx", ["dpxBits": 16]),
            ("a.tga", ["tgaBits": 24]), ("b.tga", ["tgaBits": 32]),
            ("low.jpg", ["quality": 0]), ("high.jpg", ["quality": 12]),
            ("nolayers.psd", ["layers": false]),
        ]
        for (mode, depth) in [("rgb", 8), ("rgb", 16), ("rgb", 32), ("cmyk", 8), ("lab", 16), ("grayscale", 8)] {
            record(id: "saveOptions|\(mode)\(depth)", command: "file.saveACopy", fixture: "\(mode)\(depth)", params: "") { r in
                guard newDocument(&r, mode: mode, depth: depth) else { return }
                for (file, options) in choices {
                    let path = outFolder.appendingPathComponent(file)
                    var p = options
                    p["path"] = path.path
                    guard attempt("file.saveACopy", p, &r) else { continue }
                    guard let bytes = try? Data(contentsOf: path) else {
                        r.problems.append("\(file) wasn't written")
                        continue
                    }
                    if (try? model.editor.open(name: file, bytes: bytes, allowPreview: false)) == nil {
                        r.problems.append("couldn't reopen \(file)")
                    }
                    guard newDocument(&r, mode: mode, depth: depth) else { return }
                }
            }
        }
    }

    // MARK: - Presets

    private func brushes() {
        let abr = ["brushes-v1.abr", "brushes-v2.abr", "brushes-v6.abr"].map(Self.file)
        let tips = ["speckle.gbr", "oval.vbr", "star.png", "inky.kpp", "tips.bundle"].map { Self.samples.appendingPathComponent($0).path }
        for path in abr + tips {
            let name = (path as NSString).lastPathComponent
            record(id: "brushes|\(name)", command: "brush.presets.importFile", fixture: name, params: "") { r in
                resetModel()
                guard newDocument(&r) else { return }
                guard let out = must("brush.presets.importFile", ["path": path, "group": "Omega"], &r) else { return }
                // The presets paint.
                let list = (try? model.editor.execute(id: "brush.presets.list", params: "{}")).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                var presets = (list?["presets"] as? [[String: Any]] ?? []).filter { $0["group"] as? String == "Omega" }.compactMap { $0["name"] as? String }
                // A plain image becomes one preset outside the group.
                if presets.isEmpty, let single = out["name"] as? String { presets = [single] }
                if presets.isEmpty { r.problems.append("nothing imported: \(out)") }
                for preset in presets {
                    must("paint.stroke", ["points": [[2, 2], [30, 20]], "preset": preset], &r)
                }
            }
        }
        record(id: "brushes|importAbr", command: "brush.presets.importAbr", fixture: "brushes-v6.abr", params: "") { r in
            resetModel()
            must("brush.presets.importAbr", ["path": Self.file("brushes-v6.abr"), "select": true], &r)
        }
    }

    private func gradients() {
        record(id: "gradients|grd", command: "gradient.presets.importGrd", fixture: "gradients.grd", params: "") { r in
            resetModel()
            guard newDocument(&r) else { return }
            must("gradient.presets.importGrd", ["path": Self.file("gradients.grd"), "group": "Omega"], &r)
            let out = (try? model.editor.execute(id: "gradient.presets.list", params: "{}")).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            let group = (out?["groups"] as? [[String: Any]] ?? []).first { $0["name"] as? String == "Omega" }
            let names = (group?["presets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            if names.count < 6 { r.problems.append("only \(names.count) gradients imported") }
            for name in names { attempt("gradient.presets.apply", ["preset": name, "angle": 30], &r) }
        }
    }

    private func swatches() {
        for name in ["swatches.aco", "swatches.ase"] {
            record(id: "swatches|\(name)", command: "swatches.import", fixture: name, params: "") { r in
                resetModel()
                must("swatches.import", ["path": Self.file(name), "group": "Omega", "mode": "replace"], &r)
                for format in ["aco", "ase"] {
                    let path = outFolder.appendingPathComponent("again.\(format)").path
                    if must("swatches.export", ["path": path, "format": format], &r) != nil {
                        must("swatches.import", ["path": path, "group": "Again \(format)"], &r)
                    }
                }
            }
        }
    }

    private func patterns() {
        record(id: "patterns|pat", command: "pattern.import", fixture: "patterns.pat", params: "") { r in
            resetModel()
            guard newDocument(&r) else { return }
            must("pattern.import", ["path": Self.file("patterns.pat")], &r)
            let out = (try? model.editor.execute(id: "pattern.list", params: "{}")).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String: Any]] }
            let names = (out ?? []).compactMap { $0["name"] as? String }
            if names.count < 5 { r.problems.append("only \(names.count) patterns imported") }
            for name in names { attempt("layer.newFillLayer.pattern", ["pattern": name], &r) }
            must("pattern.export", ["path": outFolder.appendingPathComponent("again.pat").path], &r)
        }
    }

    // MARK: - Actions

    private func actions() {
        var names: [String] = []
        record(id: "actions|load many", command: "actions.load", fixture: "many-steps.atn", params: "") { r in
            resetModel()
            names = must("actions.load", ["path": Self.file("many-steps.atn")], &r)?["actions"] as? [String] ?? []
            if names.count < 50 { r.problems.append("only \(names.count) actions loaded") }
        }
        if names.isEmpty {
            // Already done in an earlier attempt: load again for the plays left.
            let out = try? model.editor.execute(id: "actions.load", params: json(["path": Self.file("many-steps.atn")]))
            names = out.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["actions"] as? [String] ?? []
        }
        for name in names {
            record(id: "actions|play \(name)", command: "actions.play", fixture: "rgb8 pixel", params: name) { r in
                guard newDocument(&r) else { return }
                attempt("select.rect", ["x": 4, "y": 4, "width": 20, "height": 12], &r)
                attempt("actions.play", ["action": name], &r)
            }
        }
        for name in ["many-steps.atn", "odd-steps.atn"] {
            record(id: "actions|save \(name)", command: "actions.save", fixture: name, params: "") { r in
                resetModel()
                guard let loaded = must("actions.load", ["path": Self.file(name), "set": "Omega"], &r) else { return }
                let path = outFolder.appendingPathComponent("again.atn").path
                must("actions.save", ["path": path, "set": "Omega", "skipUnsupported": true], &r)
                let again = must("actions.load", ["path": path, "set": "Again"], &r)
                if again?["actions"] as? [String] == nil || (again?["actions"] as? [String])?.count != (loaded["actions"] as? [String])?.count {
                    r.problems.append("saved actions don't load back: \(String(describing: again?["actions"]))")
                }
            }
        }
    }

    // MARK: - Plug-in

    private func plugin() {
        let id = "net.photowagon.omega.invert"
        let path = Self.file("omega-invert.wasm")
        for depth in [8, 16, 32] {
            record(id: "plugin|run at \(depth)", command: "plugin.run", fixture: "rgb\(depth) pixel", params: "") { r in
                guard let installed = must("plugin.install", ["path": path], &r) else { return }
                if installed["id"] as? String != id { r.problems.append("installed as \(String(describing: installed["id"]))") }
                let list = must("plugin.list", [:], &r)
                if !"\(list ?? [:])".contains(id) { r.problems.append("not in the plug-in list") }
                guard newDocument(&r, depth: depth), let before = fingerprint() else { return }
                must("plugin.run", ["id": id], &r)
                if let after = fingerprint(), Self.document(after) == Self.document(before) { r.problems.append("running it changed nothing") }
                if undo(to: before, max: 4) == nil { r.problems.append("Undo doesn't bring back the document") }
                must("plugin.remove", ["id": id], &r)
                if attempt("plugin.run", ["id": id], &r) { r.problems.append("ran after it was removed") }
            }
        }
        record(id: "plugin|folder", command: "plugin.reload", fixture: "", params: "") { r in
            let report = must("plugin.reload", ["path": Self.formats.path], &r)
            if !"\(report ?? [:])".contains("omega") { r.problems.append("the folder's plug-in didn't load: \(report ?? [:])") }
            attempt("plugin.remove", ["id": id], &r)
        }
        record(id: "plugin|not a plug-in", command: "plugin.install", fixture: "", params: "") { r in
            if attempt("plugin.install", ["path": Self.file("datasets.csv")], &r) { r.problems.append("installed a text file") }
            if attempt("plugin.remove", ["id": "net.photowagon.omega.none"], &r) { r.problems.append("removed one that isn't there") }
        }
    }

    // MARK: - Video

    private func video() {
        for (name, path) in [("clip.gif", Self.file("clip.gif")), ("frames", Self.file("frames"))] {
            record(id: "video|\(name)", command: "layer.videoLayers.newVideoLayerFromFile", fixture: name, params: "") { r in
                guard newDocument(&r) else { return }
                must("layer.videoLayers.newVideoLayerFromFile", ["path": path], &r)
                for step: (String, [String: Any]) in [
                    ("timeline.setFrame", ["frame": 1]),
                    ("layer.videoLayers.insertBlankFrame", [:]), ("layer.videoLayers.duplicateFrame", [:]),
                    ("paint.stroke", ["points": [[2, 2], [20, 14]], "size": 3]),
                    ("layer.videoLayers.restoreFrame", [:]), ("layer.videoLayers.deleteFrame", [:]),
                    ("layer.videoLayers.interpretFootage", ["fps": 12]),
                    ("layer.videoLayers.showAlteredVideo", [:]), ("layer.videoLayers.reloadFrame", [:]),
                    ("layer.videoLayers.replaceFootage", ["path": path]),
                    ("layer.videoLayers.restoreAllFrames", [:]),
                    ("file.export.renderVideo", ["dir": outFolder.appendingPathComponent("render").path]),
                ] {
                    attempt(step.0, step.1, &r)
                }
                for format in ["pcraft", "psd"] {
                    guard let bytes = try? model.editor.export(format: format, quality: nil) else { continue }
                    if (try? model.editor.open(name: "omega.\(format)", bytes: bytes, allowPreview: false)) == nil {
                        r.problems.append("couldn't reopen its own \(format)")
                    }
                    model.sync()
                }
            }
            record(id: "video|\(name) to layers", command: "file.import.videoFramesToLayers", fixture: name, params: "") { r in
                guard newDocument(&r) else { return }
                must("file.import.videoFramesToLayers", ["path": path], &r)
            }
        }
        record(id: "video|rasterize", command: "layer.videoLayers.rasterize", fixture: "clip.gif", params: "") { r in
            guard newDocument(&r) else { return }
            must("layer.videoLayers.newVideoLayerFromFile", ["path": Self.file("clip.gif")], &r)
            must("layer.videoLayers.rasterize", [:], &r)
        }
        // A real movie: the engine reads GIFs and image sequences, so it may only refuse, cleanly.
        record(id: "video|movie", command: "layer.videoLayers.newVideoLayerFromFile", fixture: "clip.mov", params: "") { r in
            guard newDocument(&r), let url = writeClip() else { return }
            attempt("layer.videoLayers.newVideoLayerFromFile", ["path": url.path], &r)
            attempt("file.import.videoFramesToLayers", ["path": url.path], &r)
            if r.message?.contains("codec") == true { r.problems.append("developer text in the refusal: \(r.message ?? "")") }
        }
    }

    /// A short H.264 clip made here with AVFoundation; nil where the simulator can't encode.
    private func writeClip() -> URL? {
        let url = outFolder.appendingPathComponent("clip.mov")
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        for n in 0..<6 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, Int32(n * 40), CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let end = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(n), timescale: 12)) else { return nil }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        return done.wait(timeout: .now() + 20) == .success && writer.status == .completed ? url : nil
    }

    // MARK: - Other imports

    private func imports() {
        record(id: "imports|notes", command: "file.import.notes", fixture: "notes.psd", params: "") { r in
            guard newDocument(&r), let before = fingerprint() else { return }
            must("file.import.notes", ["path": Self.file("notes.psd")], &r)
            if undo(to: before, max: 4) == nil { r.problems.append("Undo doesn't bring back the document") }
            if attempt("file.import.notes", ["path": Self.file("rgb8.png")], &r) { r.problems.append("imported notes from a file with none") }
        }
        record(id: "imports|data sets", command: "file.import.variableDataSets", fixture: "datasets.csv", params: "") { r in
            guard newDocument(&r), let layer = model.activeLayer?.id else { return }
            must("image.variables.define", ["defs": [["name": "v", "layer": layer, "type": "visibility"]]], &r)
            must("file.import.variableDataSets", ["path": Self.file("datasets.csv")], &r)
            must("image.applyDataSet", ["name": "Second"], &r)
        }
        record(id: "imports|stack", command: "file.scripts.loadFilesIntoStack", fixture: "frames", params: "") { r in
            guard newDocument(&r) else { return }
            attempt("file.scripts.loadFilesIntoStack", ["paths": Self.file("frames")], &r)
        }
    }

    // MARK: - Settings walks

    /// Each preference changed on its own, read back, then set back.
    private func prefsWalk() {
        guard let out = try? model.editor.execute(id: "prefs.get", params: "{}"),
              let all = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] else { return }
        var leaves: [(String, Any)] = []
        func walk(_ v: Any, _ path: String) {
            if let d = v as? [String: Any] {
                for (k, x) in d.sorted(by: { $0.key < $1.key }) { walk(x, path.isEmpty ? k : "\(path).\(k)") }
            } else if !(v is [Any]), !(v is NSNull) {
                leaves.append((path, v))
            }
        }
        walk(all, "")
        for (path, value) in leaves {
            record(id: "prefs|\(path)", command: "prefs.set", fixture: "", params: "\(value)") { r in
                let changed: Any
                if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
                    changed = !n.boolValue
                } else if let n = value as? NSNumber {
                    changed = n.doubleValue + 1
                } else {
                    changed = "Omega"
                }
                if attempt("prefs.set", ["path": path, "value": changed], &r), let b = changed as? Bool,
                   let out = try? model.editor.execute(id: "prefs.get", params: json(["path": path])), out != "\(b)" {
                    r.problems.append("didn't stick: \(out)")
                }
                // A list of choices or a colour: the refusal says which, so try those too.
                let said = r.message ?? ""
                r.message = nil
                let choices: [Any]
                if let m = said.range(of: "must be one of ") {
                    choices = said[m.upperBound...].prefix { $0 != " " }.split(separator: "|").map(String.init)
                } else if said.contains("#rrggbb") {
                    choices = ["#123456"]
                } else {
                    choices = []
                }
                for choice in choices {
                    if !attempt("prefs.set", ["path": path, "value": choice], &r) { r.problems.append("its own choice \(choice) was refused") }
                }
                attempt("prefs.set", ["path": path, "value": value], &r)
            }
        }
        record(id: "prefs|reset", command: "prefs.reset", fixture: "", params: "") { r in
            if attempt("prefs.set", ["values": ["performance.historyStates": 30, "general.notARealOne": 1]], &r) { r.problems.append("took an unknown preference") }
            must("prefs.reset", [:], &r)
        }
    }

    /// Save for Web in every format and palette, and the export preferences.
    private func webExportWalk() {
        for format in ["gif", "png8", "png24", "jpeg", "wbmp"] {
            for f in model.editor.commandFields(id: "file.export.saveForWebLegacy") where !["format", "path", "preset", "colorTable", "colorTableEdits"].contains(f.name) {
                for (n, value) in Self.values(f.kind).dropFirst().enumerated() {
                    record(id: "web|\(format)|\(f.name)|\(n)", command: "file.export.saveForWebLegacy", fixture: "rgb8 pixel", params: "\(f.name)=\(value)") { r in
                        guard newDocument(&r) else { return }
                        attempt("file.export.saveForWebLegacy", ["format": format, f.name: value, "path": outFolder.appendingPathComponent("web.\(format)").path], &r)
                    }
                }
            }
        }
        for preset in ["GIF 128 Dithered", "JPEG High", "PNG-24"] {
            record(id: "web|preset \(preset)", command: "file.export.saveForWebLegacy", fixture: "rgb8 pixel", params: preset) { r in
                guard newDocument(&r) else { return }
                must("file.export.saveForWebLegacy", ["preset": preset, "path": outFolder.appendingPathComponent("preset").path], &r)
            }
        }
        for format in ["png", "jpg", "gif", "webp"] {
            record(id: "web|quick export \(format)", command: "file.export.quickExport", fixture: "rgb8 pixel", params: format) { r in
                guard newDocument(&r) else { return }
                must("file.export.exportPreferences", ["quickExportFormat": format, "jpegQuality": 60, "webpLossless": format == "png", "webpQuality": 50, "metadata": "copyright", "convertToSrgb": true], &r)
                must("file.export.quickExport", ["path": outFolder.appendingPathComponent("quick.\(format)").path, "percent": 50, "transparency": false], &r)
            }
        }
        record(id: "web|image assets", command: "file.generate.imageAssets", fixture: "named layers", params: "") { r in
            guard newDocument(&r) else { return }
            for name in ["foo.png", "200% foo@2x.png", "48x48 icons/a.png8", "photo.jpg80%", "bad.webp, tiny.gif"] {
                must("layer.new.layer", [:], &r)
                must("paint.stroke", ["points": [[2, 2], [20, 14]], "size": 4], &r)
                must("layer.renameLayer", ["name": name], &r)
            }
            must("file.generate.imageAssets", ["on": true, "dir": outFolder.appendingPathComponent("assets").path], &r)
            must("file.generate.imageAssets", ["on": false], &r)
        }
    }

    /// Character and paragraph styles: made, changed, applied, redefined, removed.
    private func typeStylesWalk() {
        for prefix in ["type.characterStyle", "type.paragraphStyle"] {
            record(id: "typeStyles|\(prefix)", command: "\(prefix).new", fixture: "text layer", params: "") { r in
                guard newDocument(&r, layer: "text"), let layer = model.activeLayer?.id else { return }
                let paragraph = prefix.hasSuffix("paragraphStyle")
                let attrs: [String: Any] = paragraph ? ["align": "center", "spaceBefore": 6, "size": 14] : ["size": 14, "underline": true, "color": "#ff0000", "caps": "all"]
                guard let id = must("\(prefix).new", ["name": "Omega", "fromSelection": false, "attrs": attrs], &r)?["id"] else { return }
                must("\(prefix).set", ["id": id, "attrs": attrs, "replace": true], &r)
                must("\(prefix).apply", ["id": id, "layer": layer], &r)
                must("\(prefix).list", ["layer": layer], &r)
                must("\(prefix).redefine", ["layer": layer], &r)
                must("\(prefix).clearOverride", ["layer": layer], &r)
                for format in ["psd", "pcraft"] {
                    guard let bytes = try? model.editor.export(format: format, quality: nil) else { continue }
                    if (try? model.editor.open(name: "omega.\(format)", bytes: bytes, allowPreview: false)) == nil { r.problems.append("couldn't reopen its own \(format)") }
                    model.sync()
                }
                guard newDocument(&r, layer: "text") else { return }
                guard let second = must("\(prefix).new", ["name": "Other", "fromSelection": true], &r)?["id"] else { return }
                let copy = must("\(prefix).duplicate", ["id": second], &r)?["id"]
                must("\(prefix).rename", ["id": second, "name": "Renamed"], &r)
                if let copy { must("\(prefix).delete", ["id": copy], &r) }
                must("\(prefix).delete", ["id": second], &r)
                if attempt("\(prefix).delete", ["id": 999], &r) { r.problems.append("deleted a style that isn't there") }
                if attempt("\(prefix).new", ["attrs": ["bogus": 1]], &r) { r.problems.append("took a made-up attribute") }
            }
        }
        record(id: "typeStyles|defaults", command: "type.loadDefaultTypeStyles", fixture: "text layer", params: "") { r in
            guard newDocument(&r, layer: "text") else { return }
            attempt("type.saveDefaultTypeStyles", [:], &r)
            attempt("type.loadDefaultTypeStyles", [:], &r)
        }
    }
}
