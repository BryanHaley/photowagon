import SwiftUI

/// One Develop slider: its params key, name, range and the value it resets to.
struct DevelopSlider: Equatable {
    let key: String
    let title: String
    let range: ClosedRange<Double>
    var initial = 0.0

    /// Exposure and the sharpening radius take hundredths; the rest whole steps.
    var fine: Bool { range.upperBound <= 5 }

    func rounded(_ v: Double) -> Double { fine ? (v * 100).rounded() / 100 : v.rounded() }
}

/// Develop's settings as its screen edits them, and the engine's `filter.cameraRaw` params.
struct DevelopSettings: Equatable {
    struct Snapshot: Equatable {
        var name: String
        var values: [String: Double]
        var curves: [String: [CGPoint]]
        var monochrome: Bool
    }

    struct Panel {
        let name: String
        let sliders: [DevelopSlider]
    }

    static let bands = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
    static let mixerKinds = [("hslHue", "Hue"), ("hslSat", "Saturation"), ("hslLum", "Luminance")]
    static let curveKeys = [("pointCurve", "RGB"), ("pointCurveRed", "Red"), ("pointCurveGreen", "Green"), ("pointCurveBlue", "Blue")]

    static let light = [
        DevelopSlider(key: "exposure", title: "Exposure", range: -5...5), DevelopSlider(key: "contrast", title: "Contrast", range: -100...100),
        DevelopSlider(key: "highlights", title: "Highlights", range: -100...100), DevelopSlider(key: "shadows", title: "Shadows", range: -100...100),
        DevelopSlider(key: "whites", title: "Whites", range: -100...100), DevelopSlider(key: "blacks", title: "Blacks", range: -100...100),
    ]
    static let color = [
        DevelopSlider(key: "temperature", title: "Temperature", range: -100...100), DevelopSlider(key: "tint", title: "Tint", range: -100...100),
        DevelopSlider(key: "vibrance", title: "Vibrance", range: -100...100), DevelopSlider(key: "saturation", title: "Saturation", range: -100...100),
    ]
    static let effects = [
        DevelopSlider(key: "texture", title: "Texture", range: -100...100), DevelopSlider(key: "clarity", title: "Clarity", range: -100...100),
        DevelopSlider(key: "dehaze", title: "Dehaze", range: -100...100),
        DevelopSlider(key: "vignetteAmount", title: "Vignette", range: -100...100),
        DevelopSlider(key: "vignetteMidpoint", title: "Midpoint", range: 0...100, initial: 50),
        DevelopSlider(key: "vignetteRoundness", title: "Roundness", range: -100...100),
        DevelopSlider(key: "vignetteFeather", title: "Feather", range: 0...100, initial: 50),
        DevelopSlider(key: "grainAmount", title: "Grain", range: 0...100),
        DevelopSlider(key: "grainSize", title: "Size", range: 0...100, initial: 25),
        DevelopSlider(key: "grainRoughness", title: "Roughness", range: 0...100, initial: 50),
    ]
    static let detail = [
        DevelopSlider(key: "sharpenAmount", title: "Sharpening", range: 0...150),
        DevelopSlider(key: "sharpenRadius", title: "Radius", range: 0.5...3, initial: 1),
        DevelopSlider(key: "sharpenDetail", title: "Detail", range: 0...100, initial: 25),
        DevelopSlider(key: "sharpenMasking", title: "Masking", range: 0...100),
        DevelopSlider(key: "noiseLuminance", title: "Noise Reduction", range: 0...100),
        DevelopSlider(key: "noiseLuminanceDetail", title: "Detail", range: 0...100, initial: 50),
        DevelopSlider(key: "noiseColor", title: "Color Noise Reduction", range: 0...100),
        DevelopSlider(key: "noiseColorDetail", title: "Detail", range: 0...100, initial: 50),
    ]

    /// The Color Mixer's sliders for one of `mixerKinds`, keyed `hslSat.3` and so on.
    static func mixer(_ kind: String) -> [DevelopSlider] {
        bands.enumerated().map { DevelopSlider(key: "\(kind).\($0.offset)", title: $0.element, range: -100...100) }
    }

    /// The panels in order; Curve has no sliders.
    static let panels = [
        Panel(name: "Light", sliders: light), Panel(name: "Color", sliders: color), Panel(name: "Effects", sliders: effects),
        Panel(name: "Curve", sliders: []), Panel(name: "Color Mixer", sliders: mixerKinds.flatMap { mixer($0.0) }),
        Panel(name: "Detail", sliders: detail),
    ]

    static let sliders: [String: DevelopSlider] = Dictionary(panels.flatMap(\.sliders).map { ($0.key, $0) }) { a, _ in a }

    var values: [String: Double] = [:]
    var curves: [String: [CGPoint]] = [:]
    var monochrome = false
    var snapshots: [Snapshot] = []
    /// Panels turned off with their eye: left out of the params.
    var hidden: Set<String> = []

    init() {}

    init(_ p: [String: Any]) {
        for (key, s) in Self.sliders {
            let v: Double? = if let dot = key.firstIndex(of: ".") {
                ((p[String(key[..<dot])] as? [NSNumber])?[safe: Int(key[key.index(after: dot)...]) ?? 0])?.doubleValue
            } else {
                (p[key] as? NSNumber)?.doubleValue
            }
            if let v, v != s.initial { values[key] = v }
        }
        for (key, _) in Self.curveKeys {
            let pts = (p[key] as? [[NSNumber]] ?? []).filter { $0.count == 2 }.map { CGPoint(x: $0[0].doubleValue, y: $0[1].doubleValue) }
            if pts.count >= 2 { curves[key] = pts.sorted { $0.x < $1.x } }
        }
        monochrome = p["convertToGrayscale"] as? Bool ?? false
        snapshots = (p["__snapshots"] as? [[String: Any]] ?? []).compactMap { d in
            guard let name = d["name"] as? String, let s = d["settings"] as? [String: Any] else { return nil }
            let one = DevelopSettings(s)
            return Snapshot(name: name, values: one.values, curves: one.curves, monochrome: one.monochrome)
        }
    }

    subscript(key: String) -> Double {
        get { values[key] ?? Self.sliders[key]?.initial ?? 0 }
        set {
            let v = Self.sliders[key].map { min(max($0.rounded(newValue), $0.range.lowerBound), $0.range.upperBound) } ?? newValue
            values[key] = v == Self.sliders[key]?.initial ? nil : v
        }
    }

    func curve(_ key: String) -> [CGPoint] { curves[key] ?? CurvesValues.identity }

    mutating func setCurve(_ key: String, _ points: [CGPoint]) { curves[key] = points == CurvesValues.identity ? nil : points }

    /// Every value, defaults too, as a live filter's params are merged into the old ones.
    func params() -> [String: Any] {
        let off = Set(Self.panels.filter { hidden.contains($0.name) }.flatMap { $0.sliders.map(\.key) })
        var out: [String: Any] = [:]
        for (key, s) in Self.sliders where !key.contains(".") { out[key] = off.contains(key) ? s.initial : self[key] }
        for (kind, _) in Self.mixerKinds {
            out[kind] = Self.mixer(kind).map { off.contains($0.key) ? 0 : self[$0.key] }
        }
        let curvesOff = hidden.contains("Curve")
        for (key, _) in Self.curveKeys {
            out[key] = curvesOff || curves[key] == nil ? [] : curve(key).map { [Double($0.x), Double($0.y)] }
        }
        out["convertToGrayscale"] = monochrome
        out["__snapshots"] = snapshots.map { s -> [String: Any] in
            var one = DevelopSettings()
            (one.values, one.curves, one.monochrome) = (s.values, s.curves, s.monochrome)
            return ["name": s.name, "settings": one.params()]
        }
        return out
    }

    /// Reset to Default: every setting, keeping the snapshots.
    mutating func reset() { self = DevelopSettings().with { $0.snapshots = snapshots } }

    /// A preset at `amount` percent: its values scaled from each slider's default, the others back
    /// to theirs.
    mutating func apply(_ preset: [String: Double], amount: Double = 100) {
        values = [:]
        curves = [:]
        monochrome = false
        for (key, v) in preset {
            let initial = Self.sliders[key]?.initial ?? 0
            self[key] = initial + (v - initial) * amount / 100
        }
    }

    mutating func saveSnapshot(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        snapshots.removeAll { $0.name == name }
        snapshots.append(Snapshot(name: name, values: values, curves: curves, monochrome: monochrome))
    }

    mutating func restore(_ s: Snapshot) { (values, curves, monochrome) = (s.values, s.curves, s.monochrome) }

    /// White Balance: As Shot until Temperature or Tint moves.
    var asShot: Bool { self["temperature"] == 0 && self["tint"] == 0 }

    private func with(_ f: (inout Self) -> Void) -> Self {
        var c = self
        f(&c)
        return c
    }

    // MARK: - Auto

    /// Auto: Light settings from plain statistics of the image (`rgb` 0…255), no learned model
    /// (`docs/patent-guardrails.md`).
    static func auto(_ rgb: [SIMD3<Float>]) -> [String: Double] {
        guard !rgb.isEmpty else { return [:] }
        let l = rgb.map { Double(0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z) / 255 }.sorted()
        let at = { (q: Double) in l[min(Int(Double(l.count - 1) * q), l.count - 1)] }
        let share = { (test: (Double) -> Bool) in Double(l.filter(test).count) / Double(l.count) }
        let lin = { (v: Double) in pow(max(v, 0.002), 2.2) }
        let clamp = { (v: Double, r: Double) in min(max(v, -r), r) }
        return [
            "exposure": (clamp(log2(lin(0.45) / lin(at(0.5))) * 0.6, 2) * 100).rounded() / 100,
            "contrast": clamp((0.6 - (at(0.9) - at(0.1))) * 60, 30).rounded(),
            "highlights": -min(share { $0 > 0.9 } * 300, 60).rounded(),
            "shadows": min(share { $0 < 0.1 } * 300, 60).rounded(),
            "whites": clamp((0.98 - at(0.995)) * 250, 60).rounded(),
            "blacks": clamp((0.02 - at(0.005)) * 250, 60).rounded(),
        ]
    }

    /// Temperature and Tint that make `rgb` (0…1, as shown) neutral: the inverse of the engine's
    /// white balance gains (`camera_raw::white_balance_gains`).
    static func whiteBalance(_ rgb: [Double]) -> (temperature: Double, tint: Double)? {
        guard rgb.count >= 3 else { return nil }
        let lin = rgb.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let (r, g, b) = (lin[0], lin[1], lin[2])
        guard r + b > 1e-4, g > 1e-4 else { return nil }
        let t = (b - r) / (0.35 * (r + b))
        let side = (r * (1 + 0.35 * t) + b * (1 - 0.35 * t)) / 2
        let tint = (1 - side / g) / 0.25
        return (min(max(t * 100, -100), 100).rounded(), min(max(tint * 100, -100), 100).rounded())
    }

    /// Auto white balance: the average of the near-gray pixels made neutral (of them all when
    /// there are too few), so a blue sky doesn't count as a colour cast.
    static func autoWhiteBalance(_ rgb: [SIMD3<Float>]) -> (temperature: Double, tint: Double)? {
        let lin = { (v: Float) in Double(v / 255) }
        let unclipped = rgb.filter { max($0.x, $0.y, $0.z) < 250 && min($0.x, $0.y, $0.z) > 5 }
        let grayish = unclipped.filter { ($0.max() - $0.min()) / $0.max() < 0.25 }
        let shown = grayish.count * 20 >= unclipped.count ? grayish : unclipped
        guard !shown.isEmpty else { return nil }
        // Averaged in light, then shown again, as `whiteBalance` reads a shown colour.
        let toLight = { (v: Double) in v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let toShown = { (v: Double) in v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        var sum = [0.0, 0.0, 0.0]
        for p in shown { for c in 0..<3 { sum[c] += toLight(lin(p[c])) } }
        return whiteBalance(sum.map { toShown($0 / Double(shown.count)) })
    }
}

/// A Develop live filter to change: `index` on `layer`.
struct DevelopEdit: Identifiable, Equatable {
    let layer: UInt64
    let index: Int
    let initial: [String: Any]
    var id: String { "\(layer)-\(index)" }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// A file opened into Develop: its settings are kept under `key` when it's done.
struct DevelopOpen: Identifiable, Equatable {
    let key: String
    let initial: [String: Any]
    var id: String { key }

    static func == (a: Self, b: Self) -> Bool { a.key == b.key }
}

/// Opening into Develop: camera raw files always, JPEG and HEIC when File Handling says so. Done
/// keeps the settings for the next time that file opens (by name and size), Open applies them,
/// Open as Object keeps them as a live filter to change later.
extension EditorModel {
    static let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef"]
    static let workflowSpaces = [("", "As Opened"), ("srgb", "sRGB"), ("display-p3", "Display P3"),
                                 ("adobe-rgb-compat", "Adobe RGB (1998) compatible"), ("prophoto-compat", "ProPhoto RGB compatible")]

    /// Preferences › File Handling › Open JPEG and HEIC in Develop.
    var developJPEG: Bool {
        get { defaults.bool(forKey: "openJPEGInDevelop") }
        set {
            defaults.set(newValue, forKey: "openJPEGInDevelop")
            objectWillChange.send()
        }
    }

    static func opensInDevelop(_ name: String, jpeg: Bool) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return rawExtensions.contains(ext) || jpeg && ["jpg", "jpeg", "heic", "heif"].contains(ext)
    }

    static func developKey(_ name: String, _ data: Data) -> String { "\(name)|\(data.count)" }

    /// Settings kept with Done (or Open), by file.
    func developSettings(_ key: String) -> [String: Any] {
        (defaults.dictionary(forKey: "developFiles")?[key] as? [String: Any]) ?? [:]
    }

    func keepDevelopSettings(_ key: String, _ params: [String: Any]) {
        var all = defaults.dictionary(forKey: "developFiles") ?? [:]
        all[key] = params
        defaults.set(all, forKey: "developFiles")
    }

    func beginDevelopOpen(_ key: String) {
        developOpen = DevelopOpen(key: key, initial: developSettings(key))
    }

    /// Done: keep the settings and close the file without opening it.
    func developDone(_ params: [String: Any]) {
        if let o = developOpen { keepDevelopSettings(o.key, params) }
        developCancel()
    }

    func developCancel() {
        developOpen = nil
        liveCancel()
        afterLive { [weak self] in self?.closeActive() }
    }

    /// Open (applied to the pixels) or Open as Object (a live filter on an embedded layer), then
    /// the Workflow's colour space (`space` a built-in profile id, "" to keep it) and depth.
    func developOpenImage(_ params: [String: Any], asObject: Bool, space: String = "", depth: Int = 0) {
        if let o = developOpen { keepDevelopSettings(o.key, params) }
        developOpen = nil
        if asObject {
            liveCancel()
            afterLive { [weak self] in
                _ = self?.run("filter.convertForSmartFilters")
                _ = self?.run("filter.cameraRaw", params)
            }
        } else {
            liveFinish("filter.cameraRaw", params)
        }
        afterLive { [weak self] in
            if !space.isEmpty { _ = self?.run("edit.convertToProfile", ["profile": space, "intent": "relative"]) }
            if depth == 8 || depth == 16 { _ = self?.run("image.mode.bits\(depth)") }
        }
    }
}
