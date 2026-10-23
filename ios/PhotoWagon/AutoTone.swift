import SwiftUI

/// Levels and Curves' Auto: which statistics it uses and how much it clips. Plain statistics of the
/// image, no learned model (`docs/patent-guardrails.md`).
struct AutoOptions: Equatable, Codable {
    enum Method: String, Codable, CaseIterable {
        case monochromatic, perChannel, darkLight

        var title: String {
            switch self {
            case .monochromatic: "Monochromatic Contrast"
            case .perChannel: "Per Channel Contrast"
            case .darkLight: "Find Dark & Light Colors"
            }
        }
    }

    var method = Method.perChannel
    var snapNeutral = false
    /// Percent of the pixels each end may clip.
    var shadows = 0.1
    var highlights = 0.1

    static let key = "autoOptions"

    static func saved(_ defaults: UserDefaults = .standard) -> AutoOptions {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AutoOptions.self, from: $0) } ?? AutoOptions()
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.key) }
    }
}

/// The pixels Auto looks at: the layer Levels adjusts (Image › Adjustments), or the image below an
/// adjustment layer, read once as the screen opens (later the image shows the tries).
struct AutoPixels {
    /// RGB 0…255, opaque pixels only.
    var rgb: [SIMD3<Float>] = []

    init(rgb: [SIMD3<Float>]) { self.rgb = rgb }

    init(_ image: CGImage?) {
        guard let image else { return }
        let w = min(image.width, 256)
        let h = max(Int((Double(image.height) * Double(w) / Double(max(image.width, 1))).rounded()), 1)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in 0..<(w * h) where px[i * 4 + 3] > 127 {
            let a = Float(px[i * 4 + 3]) / 255
            rgb.append(SIMD3(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2])) / a)
        }
    }

    @MainActor
    static func load(_ model: EditorModel, layer: UInt64?) -> AutoPixels {
        let png: Data? = if let layer { try? model.editor.analysisImageBelow(hidden: layer, maxSide: 256) }
                         else { try? model.editor.analysisImage(layer: model.activeLayer?.id, maxSide: 256) }
        return AutoPixels(png.flatMap { UIImage(data: $0)?.cgImage })
    }

    /// Black and white input levels (0…255) and a midtone gamma: one for every channel
    /// (`perChannel`, `"red"`…) or the composite (`""`).
    struct Result: Equatable {
        struct Levels: Equatable { var black: Double, white: Double, gamma = 1.0 }
        var channels: [String: Levels]
    }

    func auto(_ o: AutoOptions, color: Bool) -> Result {
        guard !rgb.isEmpty else { return Result(channels: ["": .init(black: 0, white: 255)]) }
        let lo = o.shadows / 100, hi = o.highlights / 100
        let luma = { (p: SIMD3<Float>) in 0.299 * p.x + 0.587 * p.y + 0.114 * p.z }
        var per: [Result.Levels]
        switch (o.method, color) {
        case (.perChannel, true):
            per = (0..<3).map { c in
                let (b, w) = Self.clip(rgb.map { $0[c] }, lo, hi)
                return .init(black: b, white: w)
            }
        case (.darkLight, true):
            // The average colour of the darkest and of the lightest pixels.
            let sorted = rgb.sorted { luma($0) < luma($1) }
            let nd = max(Int(Double(sorted.count) * lo), 1), nl = max(Int(Double(sorted.count) * hi), 1)
            let dark = sorted.prefix(nd).reduce(SIMD3<Float>(), +) / Float(nd)
            let light = sorted.suffix(nl).reduce(SIMD3<Float>(), +) / Float(nl)
            per = (0..<3).map { c in Self.ordered(Double(dark[c]), Double(light[c])) }
        default:
            // One pair for every channel: from all of them together (or the luminance).
            let values = color ? rgb.flatMap { [$0.x, $0.y, $0.z] } : rgb.map(luma)
            let (b, w) = Self.clip(values, lo, hi)
            per = Array(repeating: .init(black: b, white: w), count: 3)
        }
        if o.snapNeutral, color { snap(&per) }
        guard color, o.method != .monochromatic || o.snapNeutral else { return Result(channels: ["": per[0]]) }
        return Result(channels: ["red": per[0], "green": per[1], "blue": per[2]])
    }

    /// Each channel's gamma, so the image's near-neutral midtones come out gray.
    private func snap(_ per: inout [Result.Levels]) {
        let map = { (p: SIMD3<Float>) -> SIMD3<Double> in
            SIMD3((0..<3).map { c in min(max((Double(p[c]) - per[c].black) / max(per[c].white - per[c].black, 1), 0), 1) })
        }
        let near = rgb.map(map).filter { m in
            let avg = (m.x + m.y + m.z) / 3
            return (0.25...0.75).contains(avg) && max(m.x, m.y, m.z) - min(m.x, m.y, m.z) < 0.12
        }
        guard near.count * 200 >= rgb.count else { return }
        let mean = near.reduce(SIMD3<Double>(), +) / Double(near.count)
        let target = (mean.x + mean.y + mean.z) / 3
        for c in 0..<3 where mean[c] > 0.01 && mean[c] < 0.99 {
            per[c].gamma = min(max((log(mean[c]) / log(target) * 100).rounded() / 100, 0.1), 9.99)
        }
    }

    /// The levels with `lo` and `hi` (fractions) of `values` past each end.
    static func clip(_ values: [Float], _ lo: Double, _ hi: Double) -> (Double, Double) {
        guard !values.isEmpty else { return (0, 255) }
        let s = values.sorted()
        let n = s.count - 1
        let b = Double(s[min(max(Int(Double(n) * lo), 0), n)]), w = Double(s[min(max(Int(Double(n) * (1 - hi)), 0), n)])
        let pair = ordered(b, w)
        return (pair.black, pair.white)
    }

    /// Whole levels, white at least 2 above black (as Levels takes them).
    static func ordered(_ b: Double, _ w: Double) -> Result.Levels {
        let black = min(max(b.rounded(), 0), 253)
        return .init(black: black, white: min(max(w.rounded(), black + 2), 255))
    }
}

/// How much of the image clips to black or white: from the histogram and the levels each input
/// level comes out at (256 outputs, 0…255). Fixed thresholds, shown as histogram marks.
struct ClipStats: Equatable {
    var shadows = 0.0
    var highlights = 0.0
    /// The input levels that clip.
    var dark: [Bool] = []
    var light: [Bool] = []

    init(bins: [Int], outputs: [Double]) {
        guard bins.count == 256, outputs.count == 256 else { return }
        dark = outputs.map { $0 < 0.5 }
        light = outputs.map { $0 > 254.5 }
        let total = Double(max(bins.reduce(0, +), 1))
        shadows = Double(zip(bins, dark).filter(\.1).map(\.0).reduce(0, +)) / total * 100
        highlights = Double(zip(bins, light).filter(\.1).map(\.0).reduce(0, +)) / total * 100
    }

    var text: String { String(format: "Shadows %.1f%% · Highlights %.1f%%", shadows, highlights) }
}

/// Auto's options, as Photoshop's Auto Color Correction Options: OK runs Auto with them.
struct AutoOptionsSheet: View {
    @State var options: AutoOptions
    let apply: (AutoOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var save = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Algorithm") {
                    Picker("Algorithm", selection: $options.method) {
                        ForEach(AutoOptions.Method.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("auto.method")
                    Toggle("Snap Neutral Midtones", isOn: $options.snapNeutral).accessibilityIdentifier("auto.snap")
                }
                Section("Clip") {
                    percent("Shadows", $options.shadows, "auto.shadows")
                    percent("Highlights", $options.highlights, "auto.highlights")
                }
                Toggle("Save as Defaults", isOn: $save).accessibilityIdentifier("auto.save")
            }
            .navigationTitle("Auto Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        if save { options.save() }
                        apply(options)
                        dismiss()
                    }
                    .accessibilityIdentifier("auto.ok")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func percent(_ title: String, _ value: Binding<Double>, _ id: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(max($0, 0), 9.99) }),
                      format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(width: scaled(64))
                .accessibilityIdentifier(id)
            Text("%").foregroundStyle(.secondary)
        }
    }
}
