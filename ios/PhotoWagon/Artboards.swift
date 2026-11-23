import SwiftUI
import UIKit

/// An artboard: its layer, name and board in document pixels.
struct ArtboardRow: Equatable {
    let id: UInt64
    let name: String
    let rect: CGRect
    var portrait: Bool { rect.height >= rect.width }
}

/// Sizes kept from New Document's Save Preset, for New Document and the Artboard tool.
enum SavedPresets {
    private static let key = "savedDocPresets"

    static var all: [DocPreset] {
        let raw = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        return raw.compactMap { d in
            guard let name = d["name"] as? String, let w = d["width"] as? Int, let h = d["height"] as? Int else { return nil }
            return DocPreset(name: name, width: w, height: h, resolution: d["resolution"] as? Int ?? 72)
        }
    }

    /// Keeps `p`, replacing a saved preset of the same name.
    static func save(_ p: DocPreset) {
        let kept = all.filter { $0.name != p.name } + [p]
        UserDefaults.standard.set(kept.map { ["name": $0.name, "width": $0.width, "height": $0.height, "resolution": $0.resolution] }, forKey: key)
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}

extension EditorModel {
    /// The artboards, top first.
    var artboards: [ArtboardRow] {
        layers.compactMap { r in
            guard r.depth == 0, let a = r.artboard, a.count == 4 else { return nil }
            return ArtboardRow(id: r.id, name: r.name, rect: CGRect(x: a[0], y: a[1], width: a[2], height: a[3]))
        }
    }

    /// The artboard the active layer is, or is in.
    var activeArtboard: ArtboardRow? {
        guard let a = activeLayer, let i = layers.firstIndex(where: { $0.id == a.id }),
              let top = layers[...i].last(where: { $0.depth == 0 }) else { return nil }
        return artboards.first { $0.id == top.id }
    }

    /// Every top-level layer is an artboard: the canvas around them is pasteboard.
    var onlyArtboards: Bool {
        let top = layers.filter { $0.depth == 0 }
        return !top.isEmpty && top.allSatisfy { $0.artboard != nil }
    }

    /// The topmost artboard under document point `p`.
    func artboard(at p: Point) -> ArtboardRow? {
        artboards.first { $0.rect.contains(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))) }
    }

    /// The Artboard tool's sizes: saved presets first.
    static let artboardSizes = [
        DocPreset(name: "Social Portrait", width: 1080, height: 1350, resolution: 72),
        DocPreset(name: "Social Square", width: 1080, height: 1080, resolution: 72),
        DocPreset(name: "Social Story", width: 1080, height: 1920, resolution: 72),
        DocPreset(name: "Phone", width: 1206, height: 2622, resolution: 72),
        DocPreset(name: "Tablet", width: 1668, height: 2420, resolution: 72),
        DocPreset(name: "Web Large", width: 1920, height: 1080, resolution: 72),
        DocPreset(name: "Web Medium", width: 1440, height: 900, resolution: 72),
        DocPreset(name: "Letter", width: 2550, height: 3300, resolution: 300),
        DocPreset(name: "A4", width: 2480, height: 3508, resolution: 300),
    ]
    var artboardSizes: [DocPreset] { SavedPresets.all + Self.artboardSizes }

    /// After the canvas grew: when it grew left or up every board moved by the same amount, so the
    /// view follows to keep them where they were on screen. Measured on the boards not being worked
    /// on; with none of those it can't tell.
    func followCanvasShift(from before: [ArtboardRow]) {
        let active = activeArtboard?.id
        let moves = before.compactMap { b -> CGPoint? in
            guard b.id != active, let a = artboards.first(where: { $0.id == b.id }), a.rect.size == b.rect.size else { return nil }
            return CGPoint(x: a.rect.minX - b.rect.minX, y: a.rect.minY - b.rect.minY)
        }
        guard let s = moves.first, s != .zero, moves.allSatisfy({ $0 == s }) else { return }
        view.centerX += Float(s.x)
        view.centerY += Float(s.y)
        needsDraw = true
        overlayDirty = true
        canvasShifted?(Float(s.x), Float(s.y))
    }

    /// The Artboard tool's "+": a board the same size beside the active one.
    func addArtboard(beside side: String) {
        guard let a = activeArtboard else { return }
        run("layer.artboard.addBeside", ["layer": a.id, "side": side])
    }

    func resizeArtboard(width: Int, height: Int) {
        guard let a = activeArtboard else { return }
        run("layer.artboard.set", ["layer": a.id, "width": width, "height": height])
    }

    /// Turns the active artboard to portrait or landscape.
    func orientArtboard(portrait: Bool) {
        guard let a = activeArtboard, a.portrait != portrait, a.rect.width != a.rect.height else { return }
        resizeArtboard(width: Int(a.rect.height), height: Int(a.rect.width))
    }

    /// After the Move tool lets go: a layer dragged onto another artboard goes into it, one dragged
    /// off every board leaves its board. It joins the move's undo step (`key`).
    func adoptMovedLayers(key: String) {
        for l in selectedLayers where l.artboard == nil {
            guard let b = l.bounds, b.count == 4, b[2] > 0, b[3] > 0 else { continue }
            let centre = Point(x: Float(b[0] + b[2] / 2), y: Float(b[1] + b[3] / 2))
            let target = artboard(at: centre)
            guard let i = layers.firstIndex(where: { $0.id == l.id }) else { continue }
            let current = l.depth == 0 ? nil : layers[..<i].last(where: { $0.depth == 0 }).flatMap { r in artboards.first { $0.id == r.id } }
            if let target, target.id != current?.id {
                run("layer.moveTo", ["layer": l.id, "target": target.id, "position": "into", "coalesce": key])
            } else if target == nil, let current {
                run("layer.moveTo", ["layer": l.id, "target": current.id, "position": "above", "coalesce": key])
            }
        }
    }

    func setLabelColor(_ color: String, of id: UInt64) {
        run("layer.setLabelColor", ["layer": id, "color": color])
    }

    /// File › Export › Artboards to Files: one file per board in the app's folder.
    @discardableResult
    func exportArtboards(format: String, quality: Double, prefix: String, only: [UInt64]?) -> [String] {
        var p: [String: Any] = ["dir": AppFolder.url.path, "format": format, "prefix": prefix]
        if format == "jpg" { p["quality"] = Int(quality) }
        if let only { p["artboards"] = only }
        let files = ((run("file.export.artboardsToFiles", p) as? [String: Any])?["files"] as? [String]) ?? []
        if !files.isEmpty { toast = files.count == 1 ? "Exported \((files[0] as NSString).lastPathComponent)" : "Exported \(files.count) artboards" }
        return files
    }
}

/// The colour labels the Layers panel offers, as the engine names them.
enum LabelColors {
    static let all: [(id: String, title: String, color: Color?)] = [
        ("none", "No Color", nil), ("red", "Red", .red), ("orange", "Orange", .orange), ("yellow", "Yellow", .yellow),
        ("green", "Green", .green), ("blue", "Blue", .blue), ("violet", "Violet", .purple), ("gray", "Gray", .gray),
    ]
    static func color(_ id: String) -> Color? { all.first { $0.id == id }?.color }
}

// MARK: - Canvas

/// What a touch on the artboard overlay hit.
enum BoardHit: Equatable {
    /// The Artboard tool's "+" on a side of the active board.
    case add(String)
    /// A board's name.
    case name(UInt64)
}

/// Artboards on the canvas: outlines, names, the pasteboard around them, the Artboard tool's "+"
/// buttons, and the document's guides.
@MainActor
final class BoardOverlay {
    let pasteboard = CAShapeLayer()
    let outlines = CAShapeLayer()
    let active = CAShapeLayer()
    let plus = CAShapeLayer()
    let guides = CAShapeLayer()
    private var labels: [CATextLayer] = []
    private weak var host: CALayer?
    /// Where the names and "+" buttons were drawn, for hit tests (screen points).
    private(set) var nameRects: [(UInt64, CGRect)] = []
    private(set) var plusPoints: [(String, CGPoint)] = []

    static let plusRadius: CGFloat = 13
    static let plusGap: CGFloat = 30

    func install(in layer: CALayer) {
        host = layer
        pasteboard.fillRule = .evenOdd
        outlines.fillColor = nil
        outlines.strokeColor = UIColor(white: 0.55, alpha: 1).cgColor
        outlines.lineWidth = 1
        active.fillColor = nil
        active.strokeColor = UIColor.systemBlue.cgColor
        active.lineWidth = 1.5
        plus.fillColor = UIColor(white: 0.15, alpha: 0.9).cgColor
        plus.strokeColor = UIColor.white.cgColor
        plus.lineWidth = 1.5
        guides.fillColor = nil
        guides.strokeColor = UIColor.cyan.withAlphaComponent(0.8).cgColor
        guides.lineWidth = 1
        for l in all { layer.addSublayer(l) }
    }

    var all: [CAShapeLayer] { [pasteboard, outlines, active, guides, plus] }

    func layout(_ bounds: CGRect) {
        for l in all {
            l.bounds = bounds
            l.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    /// The four "+" places around `r` (screen points): top (above the name), right, bottom, left.
    static func plusPlaces(_ r: CGRect) -> [(String, CGPoint)] {
        [("top", CGPoint(x: r.midX, y: r.minY - plusGap - 12)), ("right", CGPoint(x: r.maxX + plusGap, y: r.midY)),
         ("bottom", CGPoint(x: r.midX, y: r.maxY + plusGap)), ("left", CGPoint(x: r.minX - plusGap, y: r.midY))]
    }

    func hit(_ p: CGPoint) -> BoardHit? {
        if let (side, _) = plusPoints.first(where: { hypot($0.1.x - p.x, $0.1.y - p.y) <= Self.plusRadius + 8 }) { return .add(side) }
        if let (id, _) = nameRects.first(where: { $0.1.insetBy(dx: -6, dy: -6).contains(p) }) { return .name(id) }
        return nil
    }

    func update(_ canvas: CanvasUIView) {
        let model = canvas.model
        let boards = model.artboards
        let quad = { (r: CGRect) -> [CGPoint] in
            [Point(x: Float(r.minX), y: Float(r.minY)), Point(x: Float(r.maxX), y: Float(r.minY)),
             Point(x: Float(r.maxX), y: Float(r.maxY)), Point(x: Float(r.minX), y: Float(r.maxY))].map(canvas.toScreen)
        }
        let closed = { (pts: [CGPoint], path: CGMutablePath) in
            guard let f = pts.first else { return }
            path.move(to: f)
            for q in pts.dropFirst() { path.addLine(to: q) }
            path.closeSubpath()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let show = model.doc != nil
        let edges = CGMutablePath()
        let board = CGMutablePath()
        let page = CGMutablePath()
        let covered = CGMutablePath()
        var names: [(UInt64, String, CGPoint)] = []
        if show, let d = model.doc, model.onlyArtboards {
            closed(quad(CGRect(x: 0, y: 0, width: CGFloat(d.width), height: CGFloat(d.height))), page)
        }
        for b in show ? boards : [] {
            let q = quad(b.rect)
            closed(q, edges)
            closed(q, covered)
            names.append((b.id, b.name, q[0]))
        }
        // Boards may overlap: take their union away, not each board in turn.
        let fill = page.isEmpty ? page : page.subtracting(covered.normalized())
        let rgb = model.canvasColor.rgb
        pasteboard.fillColor = UIColor(red: CGFloat(rgb[0]), green: CGFloat(rgb[1]), blue: CGFloat(rgb[2]), alpha: 1).cgColor
        pasteboard.path = fill
        outlines.path = edges

        let activeBoard = show ? model.activeArtboard : nil
        if let a = activeBoard { closed(quad(a.rect), board) }
        active.path = board

        // The Artboard tool's "+" buttons, a little outside each side of the active board.
        plusPoints = []
        let plusPath = CGMutablePath()
        if model.tool == .artboard, let a = activeBoard {
            let q = quad(a.rect)
            let r = CGRect(x: q.map(\.x).min() ?? 0, y: q.map(\.y).min() ?? 0, width: 0, height: 0)
                .union(CGRect(x: q.map(\.x).max() ?? 0, y: q.map(\.y).max() ?? 0, width: 0, height: 0))
            // A "+" that would sit on another board isn't offered.
            let others = boards.filter { $0.id != a.id }.map { b -> CGRect in
                let q = quad(b.rect)
                return CGRect(x: q.map(\.x).min() ?? 0, y: q.map(\.y).min() ?? 0, width: 0, height: 0)
                    .union(CGRect(x: q.map(\.x).max() ?? 0, y: q.map(\.y).max() ?? 0, width: 0, height: 0))
            }
            plusPoints = Self.plusPlaces(r).filter { p in !others.contains { $0.insetBy(dx: -Self.plusRadius, dy: -Self.plusRadius).contains(p.1) } }
            let s = Self.plusRadius
            for (_, c) in plusPoints {
                plusPath.addEllipse(in: CGRect(x: c.x - s, y: c.y - s, width: 2 * s, height: 2 * s))
                plusPath.move(to: CGPoint(x: c.x - s / 2, y: c.y)); plusPath.addLine(to: CGPoint(x: c.x + s / 2, y: c.y))
                plusPath.move(to: CGPoint(x: c.x, y: c.y - s / 2)); plusPath.addLine(to: CGPoint(x: c.x, y: c.y + s / 2))
            }
        }
        plus.path = plusPath

        // Guides run across the whole document.
        let lines = CGMutablePath()
        if show, let d = model.doc {
            for y in model.guides.horizontal {
                lines.move(to: canvas.toScreen(Point(x: 0, y: Float(y)))); lines.addLine(to: canvas.toScreen(Point(x: Float(d.width), y: Float(y))))
            }
            for x in model.guides.vertical {
                lines.move(to: canvas.toScreen(Point(x: Float(x), y: 0))); lines.addLine(to: canvas.toScreen(Point(x: Float(x), y: Float(d.height))))
            }
        }
        guides.path = lines

        // Names above each board's top-left corner.
        while labels.count < names.count {
            let t = CATextLayer()
            t.fontSize = 11
            t.font = UIFont.systemFont(ofSize: 11, weight: .medium)
            t.contentsScale = canvas.scale
            t.truncationMode = .end
            host?.addSublayer(t)
            labels.append(t)
        }
        nameRects = []
        for (i, t) in labels.enumerated() {
            guard i < names.count else { t.isHidden = true; continue }
            let (id, name, corner) = names[i]
            let width = min((name as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 11, weight: .medium)]).width + 4, 220)
            t.isHidden = false
            t.string = name
            t.foregroundColor = (id == activeBoard?.id ? UIColor.systemBlue : UIColor(white: 0.75, alpha: 1)).cgColor
            t.frame = CGRect(x: corner.x, y: corner.y - 17, width: width, height: 15)
            nameRects.append((id, t.frame))
        }
    }
}

extension CanvasUIView {
    func updateBoards() { boardOverlay.update(self) }

    /// A touch on a board's name selects that board; the Artboard tool's "+" adds one beside it.
    /// True when the touch was taken.
    func boardTouched(at p: CGPoint) -> Bool {
        guard [.artboard, .move].contains(model.tool), let hit = boardOverlay.hit(p) else { return false }
        switch hit {
        case let .add(side):
            guard model.tool == .artboard else { return false }
            model.addArtboard(beside: side)
            return true
        case let .name(id):
            model.run("layer.select", ["layer": id])
            // The Move tool goes on to move the board just picked.
            return model.tool == .artboard
        }
    }
}

// MARK: - Screens

/// Layer › New › Artboard: name, size and background.
struct NewArtboardSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var preset = ""
    @State private var width = "1080"
    @State private var height = "1350"
    @State private var background = "white"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).accessibilityIdentifier("artboard.name")
                Picker("Size", selection: Binding(get: { preset }, set: { n in
                    preset = n
                    if let p = model.artboardSizes.first(where: { $0.name == n }) { (width, height) = ("\(p.width)", "\(p.height)") }
                })) {
                    Text("Custom").tag("")
                    ForEach(model.artboardSizes) { p in Text(verbatim: "\(p.name) (\(p.width) × \(p.height))").tag(p.name) }
                }
                .accessibilityIdentifier("artboard.size")
                field("Width", $width, id: "artboard.width")
                field("Height", $height, id: "artboard.height")
                Picker("Background", selection: $background) {
                    Text("White").tag("white"); Text("Black").tag("black"); Text("Transparent").tag("transparent")
                }
                .accessibilityIdentifier("artboard.background")
            }
            .navigationTitle("New Artboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        var p: [String: Any] = ["width": NewDocumentSheet.pixels(width, unit: .pixels, resolution: "72"),
                                                "height": NewDocumentSheet.pixels(height, unit: .pixels, resolution: "72"), "background": background]
                        let n = name.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty { p["name"] = n }
                        dismiss()
                        model.run("layer.new.artboard", p)
                    }
                    .disabled(NewDocumentSheet.problem(width: NewDocumentSheet.pixels(width, unit: .pixels, resolution: "72"),
                                                       height: NewDocumentSheet.pixels(height, unit: .pixels, resolution: "72")) != nil)
                    .accessibilityIdentifier("artboard.ok")
                }
            }
            .onAppear { name = "Artboard \(model.artboards.count + 1)" }
        }
    }

    private func field(_ title: String, _ value: Binding<String>, id: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: value).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 110).accessibilityIdentifier(id)
            Text("px").foregroundStyle(.secondary)
        }
    }
}

/// File › Export › Artboards to Files, and a board's own Export As (`only`).
struct ExportArtboardsSheet: View {
    @ObservedObject var model: EditorModel
    /// Export just this board.
    var only: UInt64?
    @Environment(\.dismiss) private var dismiss
    @State private var prefix = ""
    @State private var format = "png"
    @State private var quality = 10.0
    @State private var selectedOnly = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("File Name Prefix", text: $prefix).accessibilityIdentifier("artboards.prefix")
                    Picker("Format", selection: $format) {
                        Text("PNG").tag("png"); Text("JPEG").tag("jpg"); Text("TIFF").tag("tiff"); Text("WebP").tag("webp"); Text("Photoshop® (PSD)").tag("psd")
                    }
                    .accessibilityIdentifier("artboards.format")
                    if format == "jpg" {
                        VStack(alignment: .leading) {
                            HStack { Text("Quality"); Spacer(); Text("\(Int(quality))").monospacedDigit() }
                            Slider(value: $quality, in: 0...12, step: 1)
                        }
                    }
                    if only == nil {
                        Toggle("Selected Artboards Only", isOn: $selectedOnly)
                            .disabled(model.activeArtboard == nil)
                            .accessibilityIdentifier("artboards.selectedOnly")
                    }
                } footer: {
                    Text("Saved in On My iPhone › PhotoWagon, one file per artboard, named with the prefix and the artboard's name.")
                }
            }
            .navigationTitle(only == nil ? "Artboards to Files" : "Export Artboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        let boards: [UInt64]? = only.map { [$0] } ?? (selectedOnly ? model.selectedArtboardIds : nil)
                        dismiss()
                        model.exportArtboards(format: format, quality: quality, prefix: prefix, only: boards)
                    }
                    .accessibilityIdentifier("artboards.export")
                }
            }
            .onAppear {
                prefix = only == nil ? model.fileStem : ""
                selectedOnly = model.activeArtboard != nil
            }
        }
    }
}

/// Which boards the Artboards to Files screen exports.
struct ExportBoards: Identifiable {
    let only: UInt64?
    var id: String { only.map(String.init) ?? "all" }
}

extension EditorModel {
    /// The artboards that are selected, or hold a selected layer.
    var selectedArtboardIds: [UInt64] {
        var ids: [UInt64] = []
        var board: UInt64?
        for r in layers {
            if r.depth == 0 { board = r.artboard != nil ? r.id : nil }
            if r.selected, let board, !ids.contains(board) { ids.append(board) }
        }
        return ids
    }
}
