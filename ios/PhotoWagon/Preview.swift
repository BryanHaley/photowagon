import SwiftUI

/// The image as it is now, for settings screens that cover the canvas. It renders off the main
/// thread after each change; a spinner shows while a change or a render is in progress.
struct PreviewPane: View {
    @ObservedObject var model: EditorModel
    /// Show the selection (white = selected) instead of the image.
    var selection = false
    /// Handles drawn over the image, given the image's rect in the pane.
    var overlay: ((CGRect) -> AnyView)?
    @Environment(\.horizontalSizeClass) private var width
    @State private var image: UIImage?
    @State private var rendering = false
    @State private var clipping: ClipOutline?
    /// The finger, while an eyedropper is held on the preview.
    @State private var loupe: CGPoint?
    @State private var loupeShows = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                GeometryReader { g in
                    let fit = Self.fitted(image.size, in: g.size)
                    if model.previewClipping, let clipping {
                        ClipOutlineView(outline: clipping, rect: fit).allowsHitTesting(false)
                    }
                    if model.previewTap != nil {
                        // Hold to see the magnifier, let go on the spot.
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { loupe = $0.location; loupeShows += 1 }
                                .onEnded { d in
                                    if let p = Self.imagePoint(d.location, in: g.size, image: image.size) { model.previewTap?(p) }
                                    hideLoupe()
                                })
                            .accessibilityElement()
                            .accessibilityIdentifier("preview.pick")
                    }
                    if let overlay { overlay(fit) }
                    if let loupe {
                        PreviewLoupe(image: image, fit: fit, finger: loupe, pane: g.size)
                    }
                }
            }
            if rendering || model.liveBusy {
                ProgressView().tint(.white).padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(8)
                    .accessibilityIdentifier("preview.busy")
            }
        }
        .frame(height: width == .regular ? 360 : 200)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("preview")
        .task(id: "\(model.doc?.revision ?? 0)\(selection)") { await render() }
    }

    /// The magnifier stays a moment after the finger lifts, to show where it picked.
    private func hideLoupe() {
        let shown = loupeShows
        DispatchQueue.main.asyncAfter(deadline: .now() + Loupe.linger) { if loupeShows == shown { loupe = nil } }
    }

    /// The rect an image of `image` size takes, fitted and centred in `size`.
    static func fitted(_ image: CGSize, in size: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(size.width / image.width, size.height / image.height)
        let (w, h) = (image.width * scale, image.height * scale)
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Where a tap at `pt` lands on an image fitted into `size`, 0…1 across it; `nil` off the image.
    static func imagePoint(_ pt: CGPoint, in size: CGSize, image: CGSize) -> CGPoint? {
        let r = fitted(image, in: size)
        guard r.width > 0, r.height > 0 else { return nil }
        let p = CGPoint(x: (pt.x - r.minX) / r.width, y: (pt.y - r.minY) / r.height)
        return (0...1).contains(p.x) && (0...1).contains(p.y) ? p : nil
    }

    private func render() async {
        rendering = true
        let editor = model.editor
        let mask = selection
        let png = await Task.detached(priority: .userInitiated) { () -> Data? in
            if mask, let m = (try? editor.selectionImage(maxSide: 900)) ?? nil { return m }
            return try? editor.previewImage(maxSide: 900)
        }.value
        // A newer change cancels this task: its own render replaces this one.
        guard !Task.isCancelled else { return }
        if let png, let ui = UIImage(data: png) {
            image = ui
            clipping = mask ? nil : ui.cgImage.flatMap { ClipOutline($0) }
        }
        rendering = false
    }
}

/// The preview's magnifier: beside the finger, the image four times larger, a crosshair on the spot.
private struct PreviewLoupe: View {
    let image: UIImage
    let fit: CGRect
    let finger: CGPoint
    let pane: CGSize
    private let d: CGFloat = 96
    private let zoom: CGFloat = 4

    var body: some View {
        ZStack {
            Color(white: 0.25)
            Image(uiImage: image).resizable().interpolation(.none)
                .frame(width: fit.width * zoom, height: fit.height * zoom)
                .position(x: d / 2 + (fit.midX - finger.x) * zoom, y: d / 2 + (fit.midY - finger.y) * zoom)
            Path { p in
                p.move(to: CGPoint(x: d / 2, y: 10)); p.addLine(to: CGPoint(x: d / 2, y: d / 2 - 5))
                p.move(to: CGPoint(x: d / 2, y: d / 2 + 5)); p.addLine(to: CGPoint(x: d / 2, y: d - 10))
                p.move(to: CGPoint(x: 10, y: d / 2)); p.addLine(to: CGPoint(x: d / 2 - 5, y: d / 2))
                p.move(to: CGPoint(x: d / 2 + 5, y: d / 2)); p.addLine(to: CGPoint(x: d - 10, y: d / 2))
            }
            .stroke(Color.pink, lineWidth: 1.5)
        }
        .frame(width: d, height: d)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white, lineWidth: 2))
        // Beside the finger (the pane is too short to go above it), on the roomier side.
        .position(x: finger.x + (finger.x > pane.width / 2 ? -1 : 1) * (d / 2 + 30),
                  y: min(max(finger.y, d / 2 + 4), max(pane.height - d / 2 - 4, d / 2 + 4)))
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityIdentifier("preview.loupe")
    }
}

/// Outlines round the parts of an image that clip: a channel at 0 (shadows) or 255 (highlights).
/// Fixed thresholds and outlines only, never recoloured pixels (`docs/patent-guardrails.md`).
struct ClipOutline {
    /// Segments in grid cells, the grid `width` × `height`.
    var shadows: [(CGPoint, CGPoint)] = []
    var highlights: [(CGPoint, CGPoint)] = []
    var width = 0
    var height = 0

    init(width: Int, height: Int, shadows: [Bool], highlights: [Bool]) {
        (self.width, self.height) = (width, height)
        self.shadows = Self.edges(shadows, width: width, height: height)
        self.highlights = Self.edges(highlights, width: width, height: height)
    }

    /// The image read at most 240 pixels across, nearest pixel (no averaging away the clipped ones).
    init?(_ image: CGImage) {
        let w = min(image.width, 240)
        let h = max(Int((Double(image.height) * Double(w) / Double(max(image.width, 1))).rounded()), 1)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var dark = [Bool](repeating: false, count: w * h), light = dark
        for i in 0..<(w * h) where px[i * 4 + 3] > 0 {
            let c = px[(i * 4)..<(i * 4 + 3)]
            dark[i] = c.contains(0)
            light[i] = c.contains(255)
        }
        self.init(width: w, height: h, shadows: dark, highlights: light)
    }

    /// The borders between cells in `mask` and cells outside it (or the grid's edge).
    static func edges(_ mask: [Bool], width w: Int, height h: Int) -> [(CGPoint, CGPoint)] {
        guard mask.count == w * h else { return [] }
        let on = { (x: Int, y: Int) in x >= 0 && y >= 0 && x < w && y < h && mask[y * w + x] }
        var out: [(CGPoint, CGPoint)] = []
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] {
                let (x0, y0, x1, y1) = (CGFloat(x), CGFloat(y), CGFloat(x + 1), CGFloat(y + 1))
                if !on(x, y - 1) { out.append((CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0))) }
                if !on(x, y + 1) { out.append((CGPoint(x: x0, y: y1), CGPoint(x: x1, y: y1))) }
                if !on(x - 1, y) { out.append((CGPoint(x: x0, y: y0), CGPoint(x: x0, y: y1))) }
                if !on(x + 1, y) { out.append((CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1))) }
            }
        }
        return out
    }
}

private struct ClipOutlineView: View {
    let outline: ClipOutline
    let rect: CGRect

    var body: some View {
        Canvas { ctx, _ in
            let sx = rect.width / CGFloat(max(outline.width, 1)), sy = rect.height / CGFloat(max(outline.height, 1))
            let path = { (segs: [(CGPoint, CGPoint)]) in
                Path { p in
                    for (a, b) in segs {
                        p.move(to: CGPoint(x: rect.minX + a.x * sx, y: rect.minY + a.y * sy))
                        p.addLine(to: CGPoint(x: rect.minX + b.x * sx, y: rect.minY + b.y * sy))
                    }
                }
            }
            ctx.stroke(path(outline.shadows), with: .color(.cyan), lineWidth: 1.5)
            ctx.stroke(path(outline.highlights), with: .color(.red), lineWidth: 1.5)
        }
        .accessibilityElement()
        .accessibilityIdentifier("preview.clipping")
        .accessibilityValue("\(outline.shadows.count) \(outline.highlights.count)")
    }
}
