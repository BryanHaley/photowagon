import SwiftUI

extension EditorModel {
    /// A preference (`"general.resizeImageDuringPlace"`).
    func pref(_ path: String) -> Any? { query("prefs.get", ["path": path]) }

    func setPref(_ path: String, _ value: Any) { run("prefs.set", ["path": path, "value": value]) }
}

/// Edit › Preferences › General: the general settings the app uses, and File Handling's recovery.
struct GeneralPreferencesSheet: View {
    @ObservedObject var model: EditorModel
    @State private var resize = true
    @State private var embedded = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Resize Image During Place", isOn: $resize)
                        .accessibilityIdentifier("prefs.resizeImageDuringPlace")
                    Toggle("Always Create Embedded Layers When Placing", isOn: $embedded)
                        .accessibilityIdentifier("prefs.alwaysCreateEmbedded")
                } header: {
                    Text("Placing")
                } footer: {
                    Text("A placed picture is fitted to the canvas, and comes in as an embedded layer you can scale without losing detail.")
                }
                Section {
                    Picker("Save Recovery Information", selection: Binding(get: { model.recoveryMinutes }, set: { model.recoveryMinutes = $0 })) {
                        ForEach(EditorModel.recoveryChoices, id: \.self) { m in Text(m == 0 ? "Off" : m == 1 ? "Every Minute" : "Every \(m) Minutes").tag(m) }
                    }
                    .accessibilityIdentifier("prefs.recovery")
                    Toggle("Open JPEG and HEIC in Develop", isOn: Binding(get: { model.developJPEG }, set: { model.developJPEG = $0 }))
                        .accessibilityIdentifier("prefs.developJPEG")
                } header: {
                    Text("File Handling")
                } footer: {
                    Text("Recovery: a copy of the image you're working on, kept until you save or close it. If PhotoWagon closes first, it's on Home under Recovered (the last 10). Camera raw files always open in Develop first.")
                }
                Section {
                    Picker("Double-Tap", selection: Binding(get: { model.pencilTap }, set: { model.pencilTap = $0 })) {
                        ForEach(PencilAction.allCases.filter { $0 != .palette }) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("prefs.pencilTap")
                    Picker("Squeeze", selection: Binding(get: { model.pencilSqueeze }, set: { model.pencilSqueeze = $0 })) {
                        ForEach(PencilAction.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("prefs.pencilSqueeze")
                    Toggle("Only Apple Pencil Paints", isOn: Binding(get: { model.pencilOnly }, set: { model.pencilOnly = $0 }))
                        .accessibilityIdentifier("prefs.pencilOnly")
                    NavigationLink {
                        PressureCurveView(model: model)
                    } label: {
                        LabeledContent("Pressure", value: model.pencilPressure?.title ?? "Custom")
                    }
                    .accessibilityIdentifier("prefs.pencilPressure")
                } header: {
                    Text("Apple Pencil")
                } footer: {
                    Text("Squeeze needs Apple Pencil Pro. With Only Apple Pencil Paints, a finger pans the image while a painting tool is picked.")
                }
                AIModelSection(model: model)
                Section {
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                        .accessibilityIdentifier("prefs.acknowledgements")
                }
            }
            .navigationTitle("General")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DoneButton() } }
        }
        .onAppear {
            resize = model.pref("general.resizeImageDuringPlace") as? Bool ?? true
            embedded = model.pref("general.alwaysCreateSmartObjectsWhenPlacing") as? Bool ?? true
        }
        .onChange(of: resize) { _, v in model.setPref("general.resizeImageDuringPlace", v) }
        .onChange(of: embedded) { _, v in model.setPref("general.alwaysCreateSmartObjectsWhenPlacing", v) }
    }
}

/// Preferences › General › AI: AI Remove's model, downloaded or deleted.
private struct AIModelSection: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var lama = ModelDownload.shared

    var body: some View {
        Section {
            LabeledContent("AI Remove Model", value: status)
                .accessibilityIdentifier("prefs.aiModel")
            switch lama.state {
            case .ready:
                Button("Delete Model", role: .destructive) { lama.delete() }
            case .downloading:
                Button("Cancel Download") { lama.cancel() }
            case .missing, .failed:
                Button("Download Model") { model.downloadAIModel() }
            }
        } header: {
            Text("AI")
        } footer: {
            Text("AI Remove fills with MI-GAN (MIT), which runs on this device. Deleting it frees the space; it downloads again the next time you use AI Remove.")
        }
    }

    private var status: String {
        switch lama.state {
        case .ready: "Downloaded"
        case .missing: "Not Downloaded (\(ByteCountFormatter.string(fromByteCount: ModelDownload.downloadBytes, countStyle: .file)))"
        case .downloading(let f): "Downloading \(Int(f * 100))%"
        case .failed(let why): why
        }
    }
}

/// Preferences › Apple Pencil › Pressure: a preset, or the curve itself (input across, output up).
struct PressureCurveView: View {
    @ObservedObject var model: EditorModel
    @State private var points: [CGPoint] = CurvesValues.identity
    @State private var selected: Int?

    var body: some View {
        Form {
            Picker("Preset", selection: Binding(get: { model.pencilPressure }, set: { model.pencilPressure = $0; load() })) {
                ForEach(PencilPressure.allCases) { Text($0.title).tag(Optional($0)) }
                if model.pencilPressure == nil { Text("Custom").tag(PencilPressure?.none) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("pressure.preset")
            Section {
                CurveGraph(bins: [], tint: .primary, points: $points, selected: $selected) { save() }
                    .frame(height: 260)
            } footer: {
                Text("Drag the curve up for a lighter touch, down for a firmer one. Drag a point off to remove it.")
            }
        }
        .navigationTitle("Pressure")
        .onAppear(perform: load)
    }

    private func load() {
        let pts = (model.pref("tools.pressureCurve") as? [[NSNumber]])?.map { $0.map(\.doubleValue) } ?? PencilPressure.normal.curve
        points = pts.filter { $0.count == 2 }.map { CGPoint(x: $0[0] * 255, y: $0[1] * 255) }
    }

    private func save() {
        model.setPref("tools.pressureCurve", points.map { [Double($0.x) / 255, Double($0.y) / 255] })
        model.objectWillChange.send()
    }
}
