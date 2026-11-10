// Copyright (C) 2025-2026 Ari Jaaksi. All rights reserved.
// Licensed under GPLv3 or a commercial license.
// See LICENSE.txt for details or contact [ari@slowlight.art] for commercial licensing.

import SwiftUI
import UniformTypeIdentifiers
import NegativeCore

@MainActor
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDropTargeted = false
    @State private var showMeasuredArea = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                sidebar
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 420, maxHeight: .infinity)
                detail
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 940, minHeight: 620)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            model.handleDrop(providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: File list

    private var sidebar: some View {
        Group {
            if model.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Drop negatives here")
                        .font(.headline)
                    Text("Camera raw, JPEG or TIFF")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.items) { item in
                        ItemRow(item: item)
                            .tag(item.id)
                            .contextMenu {
                                Button("Remove") { model.remove(item.id) }
                            }
                    }
                }
            }
        }
    }

    // MARK: Preview and adjustments

    @ViewBuilder
    private var detail: some View {
        if let item = model.selectedItem {
            VStack(spacing: 0) {
                previewArea(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                AdjustmentPanel(item: item,
                                settings: model.settingsBinding(for: item.id),
                                showMeasuredArea: $showMeasuredArea)
                    .padding(12)
            }
        } else {
            Text(model.items.isEmpty ? "Drop photographs of film negatives anywhere in this window."
                                     : "Select an image.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func previewArea(for item: NegativeItem) -> some View {
        switch item.stage {
        case .waiting, .analyzing:
            VStack(spacing: 8) {
                ProgressView()
                Text(item.stage == .waiting ? "Waiting…" : "Analysing…")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding()
        case .ready:
            if let image = item.rendered {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay {
                        if showMeasuredArea, let area = item.analysis?.pictureArea {
                            GeometryReader { geometry in
                                Rectangle()
                                    .strokeBorder(Color.yellow, lineWidth: 1.5)
                                    .frame(width: geometry.size.width * CGFloat(area.x1 - area.x0),
                                           height: geometry.size.height * CGFloat(area.y1 - area.y0))
                                    .offset(x: geometry.size.width * CGFloat(area.x0),
                                            y: geometry.size.height * CGFloat(area.y0))
                            }
                        }
                    }
                    .padding(12)
            } else {
                Text("No preview available.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button("Add Files…") { model.presentOpenPanel() }
            Button("Clear") { model.clear() }
                .disabled(model.items.isEmpty || model.isExporting)

            Divider().frame(height: 18)

            Button("Output Folder…") { model.chooseOutputFolder() }
                .disabled(model.isExporting)
            Text(model.outputFolder?.path ?? "No output folder chosen")
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(model.outputFolder == nil ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.isExporting {
                ProgressView(value: Double(model.exportDone), total: Double(max(model.exportTotal, 1)))
                    .frame(width: 120)
                Text("\(model.exportDone) of \(model.exportTotal)")
                    .monospacedDigit()
                Button("Cancel") { model.cancelExporting() }
            } else {
                if !model.statusMessage.isEmpty {
                    Text(model.statusMessage)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Picker("Format", selection: $model.outputFormat) {
                    Text("JPEG").tag(OutputFormat.jpeg)
                    Text("TIFF, 16-bit").tag(OutputFormat.tiff)
                }
                .labelsHidden()
                .frame(width: 120)
                .help("JPEG: 8 bits per channel, small files. TIFF: 16 bits per channel, lossless, large files. Both have the same number of pixels as the original.")
                if model.outputFormat == .jpeg {
                    Picker("JPEG quality", selection: $model.jpegQuality) {
                        Text("Quality 85").tag(0.85)
                        Text("Quality 90").tag(0.90)
                        Text("Quality 95").tag(0.95)
                        Text("Quality 100").tag(1.0)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                Button(model.readyCount == 1 ? "Convert 1 Image" : "Convert \(model.readyCount) Images") {
                    model.export()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.readyCount == 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Rows

private struct ItemRow: View {
    let item: NegativeItem

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                if let image = item.rendered {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if case .failed = item.stage {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 64, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusIsProblem ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusIsProblem: Bool {
        if case .failed = item.stage { return true }
        if case .failed = item.exportStage { return true }
        return false
    }

    private var statusText: String {
        switch item.exportStage {
        case .queued: return "Queued"
        case .exporting: return "Converting…"
        case .done(let name): return "Saved as \(name)"
        case .failed(let message): return "Not saved: \(message)"
        case .none: break
        }
        switch item.stage {
        case .waiting: return "Waiting"
        case .analyzing: return "Analysing…"
        case .failed: return "Could not be read"
        case .ready:
            let film = item.isMonochrome == true ? "Black-and-white" : "Colour"
            return film + (item.usesFilmExposure ? ", by film exposure" : ", fitted to picture")
        }
    }
}

// MARK: - Adjustments

@MainActor
private struct AdjustmentPanel: View {
    let item: NegativeItem
    @Binding var settings: ConversionSettings
    @Binding var showMeasuredArea: Bool
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let ready = item.stage == .ready
        let monochrome = item.isMonochrome == true
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Film", selection: $settings.filmType) {
                    Text(autoLabel).tag(FilmType.auto)
                    Text("Colour").tag(FilmType.color)
                    Text("Black-and-white").tag(FilmType.blackAndWhite)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                Spacer()

                Toggle("Show measured area", isOn: $showMeasuredArea)
                    .toggleStyle(.checkbox)
            }

            HStack(spacing: 12) {
                Picker("Tones", selection: $settings.toneMode) {
                    Text("By film exposure").tag(ToneMode.filmExposure)
                    Text("Fit to picture").tag(ToneMode.fitToPicture)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 330)
                .help("By film exposure: tones follow the exposure you gave the film, so a correctly exposed subject stays right in front of a much brighter background. It needs clear film somewhere in the frame. Fit to picture: the frame's own darkest and brightest parts become black and white.")

                Spacer()
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 6) {
                    AdjustmentSlider(title: "Brightness", value: $settings.brightness)
                    AdjustmentSlider(title: "Contrast", value: $settings.contrast)
                    AdjustmentSlider(title: "Saturation", value: $settings.saturation)
                        .disabled(monochrome)
                }
                VStack(spacing: 6) {
                    AdjustmentSlider(title: "Warmth", value: $settings.warmth)
                        .disabled(monochrome)
                    AdjustmentSlider(title: "Tint", value: $settings.tint)
                        .disabled(monochrome)
                    HStack {
                        Text(detectionSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button("Reset") {
                            var cleared = ConversionSettings()
                            cleared.filmType = settings.filmType
                            cleared.toneMode = settings.toneMode
                            settings = cleared
                        }
                        .disabled(settings.isNeutral)
                        Button("Apply to All") { model.applySettingsToAll(from: item.id) }
                            .disabled(model.items.count < 2)
                    }
                }
            }
        }
        .disabled(!ready)
    }

    private var autoLabel: String {
        guard let analysis = item.analysis else { return "Automatic" }
        return analysis.isBlackAndWhite ? "Automatic (black-and-white)" : "Automatic (colour)"
    }

    private var detectionSummary: String {
        guard let analysis = item.analysis else { return "" }
        if analysis.usedFallbackRegion {
            return "Borders could not be told apart from the picture; the centre of the frame was measured."
        }
        var notes: [String] = []
        if analysis.foundHolderBorder { notes.append("holder border ignored") }
        if analysis.foundBacklightBorder { notes.append("bare backlight ignored") }
        var text = "No borders found outside the film."
        if !notes.isEmpty {
            let joined = notes.joined(separator: ", ")
            text = joined.prefix(1).uppercased() + String(joined.dropFirst()) + "."
        }
        if settings.toneMode == .filmExposure && !analysis.clearFilmFound {
            text += " No clear film in this frame, so it is fitted to the picture."
        }
        return text
    }
}

private struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 76, alignment: .leading)
            Slider(value: $value, in: -2...2)
            Text(String(format: "%+.2f", value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
