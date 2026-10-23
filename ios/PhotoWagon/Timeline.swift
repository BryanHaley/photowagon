import SwiftUI

/// The document's frame animation, as `animation.info` reports it.
struct AnimationInfo: Equatable {
    /// Each frame's delay, seconds.
    var delays: [Double]
    var current: Int
    /// Times to play: 0 forever.
    var loops: Int

    init(delays: [Double], current: Int = 0, loops: Int = 0) {
        (self.delays, self.current, self.loops) = (delays, current, loops)
    }

    init?(_ out: Any?) {
        guard let a = (out as? [String: Any])?["animation"] as? [String: Any], let frames = a["frames"] as? [[String: Any]] else { return nil }
        delays = frames.map { ($0["delay"] as? NSNumber)?.doubleValue ?? 0 }
        current = a["current"] as? Int ?? 0
        loops = a["loops"] as? Int ?? 0
    }

    var count: Int { delays.count }

    /// The frame after `current` while playing, and the plays finished; `nil` once the last
    /// play ends (it stops on the last frame).
    static func next(after current: Int, count: Int, loops: Int, played: Int) -> (frame: Int, played: Int)? {
        guard count > 1 else { return nil }
        if current + 1 < count { return (current + 1, played) }
        let done = played + 1
        if loops > 0, done >= loops { return nil }
        return (0, done)
    }

    /// Seconds a frame shows while playing: a delay of 0 plays as fast as the screen updates.
    static func onScreen(_ delay: Double) -> Double { max(delay, 1.0 / 30) }

    /// "0.2 s", "No delay".
    static func label(_ delay: Double) -> String {
        delay <= 0 ? "No delay" : String(format: delay < 1 ? "%.1g s" : "%g s", delay)
    }

    /// The delay menu. No "no delay": viewers play a GIF's shortest delays at 0.1 s anyway.
    static let delays: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10]

    static func loopsLabel(_ n: Int) -> String {
        switch n {
        case 0: "Forever"
        case 1: "Once"
        default: "\(n) Times"
        }
    }
}

extension EditorModel {
    func createFrameAnimation() { run("animation.create") }

    func selectFrame(_ i: Int) {
        selectedFrames = [i]
        run("animation.selectFrame", ["frame": i])
    }

    /// A copy of the current frame after it (the Timeline's New Frame).
    func newFrame() {
        run("animation.newFrame")
        selectedFrames = [animation?.current ?? 0]
    }

    func deleteFrames() {
        run("animation.deleteFrames", ["frames": Array(framesToChange)])
        selectedFrames = [animation?.current ?? 0]
    }

    func makeFramesFromLayers() {
        run("animation.makeFramesFromLayers")
        selectedFrames = [0]
    }

    /// The frames a change applies to: the ones selected, or the current.
    var framesToChange: [Int] {
        let n = animation?.count ?? 0
        let picked = selectedFrames.filter { $0 < n }.sorted()
        return picked.isEmpty ? [animation?.current ?? 0] : picked
    }

    func setDelay(_ delay: Double, frames: [Int]? = nil) {
        run("animation.setDelay", ["delay": delay, "frames": frames ?? framesToChange])
    }

    func setLoops(_ n: Int) { run("animation.setLoops", ["loops": n == 0 ? "forever" as Any : n]) }

    func togglePlay() { playing ? stopPlaying() : startPlaying() }

    func startPlaying() {
        guard let a = animation, a.count > 1 else { return }
        playing = true
        played = 0
        schedulePlay(after: AnimationInfo.onScreen(a.delays[a.current]))
    }

    func stopPlaying() {
        guard playing else { return }
        playing = false
        playTimer?.invalidate()
        playTimer = nil
        // Playing only redrew the canvas: bring the layers and history up to date.
        selectedFrames = [animation?.current ?? 0]
        sync()
    }

    private func schedulePlay(after seconds: Double) {
        playTimer?.invalidate()
        playTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.playStep() }
        }
    }

    private func playStep() {
        guard playing, let a = animation, let step = AnimationInfo.next(after: a.current, count: a.count, loops: a.loops, played: played) else {
            stopPlaying()
            return
        }
        played = step.played
        // Each frame only redraws the canvas (a full refresh per frame can't keep up).
        guard (try? editor.execute(id: "animation.selectFrame", params: json(["frame": step.frame]))) != nil else {
            stopPlaying()
            return
        }
        animation?.current = step.frame
        needsDraw = true
        schedulePlay(after: AnimationInfo.onScreen(animation?.delays[safe: step.frame] ?? 0))
    }
}

/// Window › Timeline: the frame animation's frames with their delays, playback, and the panel
/// menu (Make Frames From Layers, Select All Frames…). Docked above the tools, so the canvas
/// stays free for moving layers within a frame.
struct TimelinePanel: View {
    @ObservedObject var model: EditorModel
    @State private var thumbs: [Int: UIImage] = [:]
    @State private var otherLoops = false
    @State private var otherDelay = false

    var body: some View {
        VStack(spacing: 6) {
            if let a = model.animation {
                controls(a)
                frames(a)
            } else {
                HStack(spacing: 12) {
                    Text("Timeline").font(.headline)
                    Spacer()
                    Button { model.createFrameAnimation() } label: { Label("Create Frame Animation", systemImage: "film.stack") }
                        .buttonStyle(.bordered)
                        .disabled(model.doc == nil)
                        .accessibilityIdentifier("timeline.create")
                    Button { model.showTimeline = false } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close Timeline")
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(white: 0.12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline")
        .task(id: thumbKey) { await loadThumbs() }
        .alert("Looping", isPresented: $otherLoops) { NumberPrompt(title: "Times") { model.setLoops(max(Int($0), 1)) } } message: { Text("How many times it plays.") }
        .alert("Frame Delay", isPresented: $otherDelay) { NumberPrompt(title: "Seconds") { model.setDelay(min(max($0, 0), 600)) } }
    }

    private func controls(_ a: AnimationInfo) -> some View {
        HStack(spacing: 14) {
            Menu {
                Button("Once") { model.setLoops(1) }
                Button("3 Times") { model.setLoops(3) }
                Button("Forever") { model.setLoops(0) }
                Button("Other…") { otherLoops = true }
            } label: { Text(AnimationInfo.loopsLabel(a.loops)).font(.caption).frame(minWidth: 56) }
            .accessibilityIdentifier("timeline.loops")
            Spacer(minLength: 0)
            button("backward.end.fill", "First Frame", "timeline.first") { model.selectFrame(0) }
            button("backward.frame.fill", "Previous Frame", "timeline.previous") { model.selectFrame(max(a.current - 1, 0)) }
            button(model.playing ? "stop.fill" : "play.fill", model.playing ? "Stop" : "Play", "timeline.play") { model.togglePlay() }
            button("forward.frame.fill", "Next Frame", "timeline.next") { model.selectFrame(min(a.current + 1, a.count - 1)) }
            Spacer(minLength: 0)
            button("plus.square.on.square", "Duplicate Frame", "timeline.new") { model.newFrame() }
            button("trash", "Delete Frame", "timeline.delete", enabled: a.count > model.framesToChange.count) { model.deleteFrames() }
            Menu {
                Button("Make Frames From Layers") { model.makeFramesFromLayers() }
                Button("Select All Frames") { model.selectedFrames = Set(0..<a.count) }
                Button("Reverse Frames") { model.run("animation.reverseFrames") }
                Divider()
                Button("Delete Animation", role: .destructive) { model.stopPlaying(); model.run("animation.delete") }
                Button("Close Timeline") { model.showTimeline = false }
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("Timeline Menu")
            .accessibilityIdentifier("timeline.menu")
        }
        .font(.body)
    }

    private func frames(_ a: AnimationInfo) -> some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(0..<a.count, id: \.self) { i in frame(i, a).id(i) }
                }
            }
            .onChange(of: a.current) { _, c in withAnimation { scroll.scrollTo(c) } }
        }
    }

    private func frame(_ i: Int, _ a: AnimationInfo) -> some View {
        let picked = model.selectedFrames.contains(i) || (model.selectedFrames.isEmpty && i == a.current)
        return VStack(spacing: 2) {
            Button { model.selectFrame(i) } label: {
                ZStack(alignment: .topLeading) {
                    Checkerboard()
                    if let t = thumbs[i] { Image(uiImage: t).resizable().scaledToFit() }
                    Text("\(i + 1)").font(.caption2.monospacedDigit()).padding(3).background(.black.opacity(0.5))
                }
                .frame(width: 72, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(i == a.current ? Color.accentColor : picked ? .white.opacity(0.7) : .clear, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Frame \(i + 1)")
            .accessibilityValue(i == a.current ? "current" : picked ? "selected" : "")
            .accessibilityIdentifier("timeline.frame.\(i)")
            Menu {
                ForEach(AnimationInfo.delays, id: \.self) { d in
                    Button(AnimationInfo.label(d)) { model.setDelay(d, frames: picked ? model.framesToChange : [i]) }
                }
                Button("Other…") {
                    if !picked { model.selectedFrames = [i] }
                    otherDelay = true
                }
            } label: {
                Text(AnimationInfo.label(a.delays[i])).font(.caption2).lineLimit(1)
            }
            .accessibilityIdentifier("timeline.delay.\(i)")
        }
    }

    private func button(_ symbol: String, _ title: String, _ id: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 30, height: 30) }
            .disabled(!enabled)
            .accessibilityLabel(title)
            .accessibilityIdentifier(id)
    }

    /// Thumbnails come again after an edit, not while playing (going to a frame changes nothing in them).
    private var thumbKey: String {
        model.playing ? "playing" : "\(model.doc?.revision ?? 0)-\(model.animation?.count ?? 0)"
    }

    private func loadThumbs() async {
        guard !model.playing, let n = model.animation?.count else { return }
        let editor = model.editor
        let pngs = await Task.detached(priority: .utility) { (0..<n).map { try? editor.animationThumbnail(frame: UInt32($0), maxSide: 144) } }.value
        guard !Task.isCancelled else { return }
        thumbs = Dictionary(uniqueKeysWithValues: pngs.enumerated().compactMap { i, d in d.flatMap(UIImage.init(data:)).map { (i, $0) } })
    }
}

/// A number typed in an alert.
private struct NumberPrompt: View {
    let title: String
    let done: (Double) -> Void
    @State private var text = ""

    var body: some View {
        TextField(title, text: $text).keyboardType(.numbersAndPunctuation)
        Button("OK") { if let v = Double(text) { done(v) } }
        Button("Cancel", role: .cancel) {}
    }
}
