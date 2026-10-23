import SwiftUI

/// A layer mask's Properties (double-tap the mask, or Window › Properties with the mask
/// selected): Density and Feather, which leave the mask's pixels as they are, and what else
/// Photoshop's Masks properties offer.
struct MaskProperties: View {
    @ObservedObject var model: EditorModel
    let layer: UInt64

    private var row: LayerRow? { model.layers.first { $0.id == layer } }

    var body: some View {
        Form {
            if let row, let m = row.mask {
                Section {
                    StyleSlider(title: "Density", value: m.density, range: 0...100, unit: "%", id: "mask.density") { model.setMask(layer, density: $0) }
                    StyleSlider(title: "Feather", value: m.feather, range: 0...1000, unit: "px", id: "mask.feather") { model.setMask(layer, feather: $0) }
                } header: {
                    Text("Pixel Mask")
                } footer: {
                    Text("Density fades the whole mask; Feather softens its edges. Neither changes what you painted, so you can change them later.")
                }
                Section {
                    Button { model.targetLayer(layer, mask: true); model.run("image.adjustments.invert") } label: { Label("Invert", systemImage: "circle.righthalf.filled") }
                        .accessibilityIdentifier("mask.invert")
                    Button { model.run("layer.layerMask.enabled", ["layer": layer]) } label: {
                        Label(m.enabled ? "Disable Mask" : "Enable Mask", systemImage: m.enabled ? "eye.slash" : "eye")
                    }
                    .accessibilityIdentifier("mask.enabled")
                    Button { model.run("layer.layerMask.linked", ["layer": layer]) } label: {
                        Label(m.linked ? "Unlink from Layer" : "Link to Layer", systemImage: "link")
                    }
                    .accessibilityIdentifier("mask.linked")
                    Button { model.run("layer.layerMask.apply", ["layer": layer]) } label: { Label("Apply Mask", systemImage: "checkmark.circle") }
                        .disabled(row.kind != "Pixel")
                    Button(role: .destructive) { model.run("layer.layerMask.delete", ["layer": layer]) } label: { Label("Delete Mask", systemImage: "trash") }
                }
            } else {
                Text("This layer has no mask.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Mask Properties")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Shown while the canvas shows a layer's mask alone (View Mask): what you see, and the way back.
struct MaskViewBar: View {
    let done: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.lefthalf.filled")
            Text("Showing the layer mask").font(.callout)
            Button("Done", action: done)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("maskView.done")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maskView.bar")
    }
}
