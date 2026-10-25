import SwiftUI

/// The first-time tour: short tips pointing at the tools, the options bar and the top bar.
enum TutorialStep: Int, CaseIterable {
    case toolGroups, groupTools, toolOptions, home, menu, undo, search, history, view, layers, colors

    var target: TutorialTarget {
        switch self {
        case .toolGroups: .toolbar
        case .groupTools: .contextBar
        case .toolOptions: .contextBar
        case .home: .home
        case .menu: .menu
        case .undo: .undo
        case .search: .search
        case .history: .history
        case .view: .view
        case .layers: .layers
        case .colors: .colors
        }
    }

    var title: String {
        switch self {
        case .toolGroups: "Tools"
        case .groupTools: "Pick a Tool"
        case .toolOptions: "Tool Options"
        case .home: "Home"
        case .menu: "Menus"
        case .undo: "Undo and Redo"
        case .search: "Search"
        case .history: "History"
        case .view: "View"
        case .layers: "Layers"
        case .colors: "Colors"
        }
    }

    var text: String {
        switch self {
        case .toolGroups: "Tap an icon to see the tools in its group. Touch and hold for their names and what they do."
        case .groupTools: "Tap a tool to pick it. Touch and hold for its name."
        case .toolOptions: "Once a tool is selected, its options appear here."
        case .home: "Your files, new images and settings."
        case .menu: "Tap ☰ to open it. Quick actions are at the top; File, Edit, Image, Layer, Select, Filter and the rest are below them. Scroll down to reach them."
        case .undo: "Step back, or forward again."
        case .search: "Find any command by name."
        case .history: "Go back to any earlier step."
        case .view: "Fit to Screen, and reset the zoom, position or tilt."
        case .layers: "Layers, masks and blend modes."
        case .colors: "Foreground and background colors. Tap to pick one."
        }
    }
}

extension TutorialStep {
    /// Its target still takes touches (the menu can be opened during its tip).
    var touchesTarget: Bool { self == .menu }
}

/// What a tip points at.
enum TutorialTarget: Hashable {
    case toolbar, contextBar, home, menu, undo, search, history, view, layers, colors
}

struct TutorialAnchors: PreferenceKey {
    static var defaultValue: [TutorialTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TutorialTarget: Anchor<CGRect>], nextValue: () -> [TutorialTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks this view as what the tutorial's `target` tip points at.
    func tutorialTarget(_ target: TutorialTarget) -> some View {
        // Merged, so a target inside another (the colours in the toolbar) keeps its own.
        transformAnchorPreference(key: TutorialAnchors.self, value: .bounds) { $0[target] = $1 }
    }
}

extension EditorModel {
    /// Done or skipped once, the tour doesn't come back by itself (UI tests skip it with
    /// `-skipTutorial`).
    var tutorialDone: Bool {
        get { defaults.bool(forKey: "tutorialDone") || UserDefaults.standard.bool(forKey: "skipTutorial") }
        set { defaults.set(newValue, forKey: "tutorialDone") }
    }

    /// The first time a document is open.
    func startTutorialIfNew() {
        guard tutorialStep == nil, !tutorialDone, doc != nil else { return }
        showTutorial(.toolGroups)
    }

    /// Help › Tutorial, and each step: the group's list shows while its tip does.
    func showTutorial(_ step: TutorialStep) {
        tutorialStep = step
        let group = Tool.groups.firstIndex { $0.contains(tool) }
        switch step {
        case .groupTools: pickingGroup = group
        default: pickingGroup = nil
        }
    }

    func nextTutorialStep() {
        guard let step = tutorialStep else { return }
        if let next = TutorialStep(rawValue: step.rawValue + 1) {
            showTutorial(next)
        } else {
            endTutorial()
        }
    }

    /// The ☰ menu closed: on the Menus tip, the tour goes on.
    func menuClosed() {
        if tutorialStep == .menu { nextTutorialStep() }
    }

    func endTutorial() {
        tutorialStep = nil
        pickingGroup = nil
        tutorialDone = true
    }
}

/// The tip for the current step: the screen dimmed but for its target, a note beside it, Next
/// and Skip Tutorial.
struct TutorialOverlay: View {
    @ObservedObject var model: EditorModel
    let anchors: [TutorialAnchors.Value.Key: Anchor<CGRect>]

    var body: some View {
        GeometryReader { g in
            if let step = model.tutorialStep, let anchor = anchors[step.target] {
                let r = g[anchor].insetBy(dx: -4, dy: -4)
                // Below the highlight, else above it, else inside it (the room a tip needs).
                let room: CGFloat = 200
                let (top, inside): (Bool, Bool) = g.size.height - r.maxY >= room ? (true, false) : r.minY >= room ? (false, false) : (false, true)
                ZStack(alignment: .topLeading) {
                    // Every touch goes to the tip, not what's under it (but the target, on a tip that
                    // lets you use it).
                    let dim = Path { p in
                        p.addRect(CGRect(origin: .zero, size: g.size))
                        p.addRoundedRect(in: r, cornerSize: CGSize(width: 10, height: 10))
                    }
                    dim.fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                        .contentShape(step.touchesTarget ? dim : Path(CGRect(origin: .zero, size: g.size)), eoFill: step.touchesTarget)
                        .onTapGesture {}
                    RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                    VStack(spacing: 0) {
                        if top { Color.clear.frame(height: r.maxY + 12) } else { Spacer(minLength: 0) }
                        note(step)
                            .frame(width: min(320, g.size.width - 32))
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(x: min(max(r.midX, 176), g.size.width - 176) - g.size.width / 2)
                        if top { Spacer(minLength: 0) } else { Color.clear.frame(height: g.size.height - (inside ? r.maxY - 16 : r.minY - 12)) }
                    }
                    .frame(width: g.size.width, height: g.size.height)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.2), value: model.tutorialStep)
    }

    private func note(_ step: TutorialStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(step.title).font(.headline)
                Spacer()
                Text("\(step.rawValue + 1) of \(TutorialStep.allCases.count)").font(.caption).foregroundStyle(.secondary)
            }
            Text(step.text).font(.subheadline)
            if step == .menu { MenuScrollPicture().frame(height: 120) }
            HStack {
                Button("Skip Tutorial") { model.endTutorial() }
                    .accessibilityIdentifier("tutorial.skip")
                Spacer()
                Button(step == TutorialStep.allCases.last ? "Done" : "Next") { model.nextTutorialStep() }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(.black)
                    .accessibilityIdentifier("tutorial.next")
            }
            .font(.subheadline)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tutorial.\(step.title)")
    }
}

/// The Menus tip's picture of the ☰ menu: quick actions, then the menus below, scrolling.
private struct MenuScrollPicture: View {
    @State private var down = false
    private let quick = ["Quick Share as PNG", "Crop and Rotate", "Auto Enhance", "Develop", "Curves"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(quick, id: \.self) { row($0, chevron: false) }
            Divider().padding(.vertical, 4)
            ForEach(MenuTree.order, id: \.self) { row($0, chevron: true) }
        }
        .padding(.horizontal, 10)
        .offset(y: down ? -210 : 0)
        .frame(height: 120, alignment: .top)
        .clipped()
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
        .onAppear { withAnimation(.easeInOut(duration: 2.5).delay(0.8).repeatForever(autoreverses: true)) { down = true } }
    }

    private func row(_ title: String, chevron: Bool) -> some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            if chevron { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(height: 22)
    }
}
