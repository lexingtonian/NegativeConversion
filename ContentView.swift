//
//  ContentView.swift
//  Negative Conversion
//
//  Created by Ari Jaaksi on 25.9.2025.
//
// Copyright (C) 2025 Ari Jaaksi. All rights reserved.
// Licensed under GPLv3 or a commercial license.
// See LICENSE.txt for details or contact [ari@slowlight.art] for commercial licensing.

import SwiftUI
import UniformTypeIdentifiers

@main
struct NegativeConverterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Negative Converter Help") {
                    HelpWindowController.shared.show()
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}

// MARK: - Help window controller (singleton — ensures only one Help window)

class HelpWindowController: NSObject {
    static let shared = HelpWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let hostingView = NSHostingView(rootView: HelpView())
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Help"
        w.contentView = hostingView
        w.center()
        w.setFrameAutosaveName("HelpWindow")
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}

// MARK: - Help content

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Title
                Text("Negative to Positive Converter")
                    .font(.largeTitle).fontWeight(.bold)

                Text("Converts film negative scans to positive images and can also enhance existing positives. Output files are saved alongside the source files with a _p (convert) or _e (enhance) suffix.")
                    .font(.body).foregroundColor(.secondary)

                Divider()

                // Source
                helpSection(title: "Source Panel") {
                    Text("Select ") + Text("Convert Negatives").bold() + Text(" or ") + Text("Enhance Images").bold() + Text(", then drag files into the drop area or use the ") + Text("Select Images").bold() + Text(" button. Supported formats: RAW (ARW, CR2, NEF, DNG, ORF), JPEG, PNG, and TIFF. You can add more files at any time.")
                }

                Divider()

                // Process
                helpSection(title: "Process Panel") {
                    Text("Three modes are available:")
                }
                VStack(alignment: .leading, spacing: 10) {
                    helpBullet(label: "Automatic", body: "The app analyses each image and applies a standard conversion with no adjustments.")
                    helpBullet(label: "Balanced", body: "Applies automatic brightness and contrast balancing. Nudges dark or bright images toward middle grey, and boosts contrast on flat images. Never clips highlights or shadows.")
                    helpBullet(label: "Use Reference Image", body: "Drag in or select a positive photo that represents the look you want. The app matches contrast and color balance toward that reference while always outputting a full-range image. Dropping a reference image automatically switches to this mode.")
                }
                .padding(.leading, 16)

                Divider()

                // Output
                helpSection(title: "Output Panel") {
                    Text("Shows a preview of the last converted image. Choose ") + Text("JPEG").bold() + Text(" for smaller files or ") + Text("TIFF").bold() + Text(" for maximum quality.")
                }

                Divider()

                // Converting
                helpSection(title: "Converting") {
                    Text("Press ") + Text("Convert to Positives").bold() + Text(" (or ") + Text("Enhance Images").bold() + Text(") to process all files in the list. Progress is shown in the action bar. A summary appears when done.")
                }

                Divider()

                // Tips
                helpSection(title: "Tips") {
                    Text("A good reference image is a well-exposed positive from the same film stock or shooting conditions. The reference guides contrast and color balance — it does not need to match the subject matter. Results are intended as a starting point for further editing in Lightroom or similar tools.")
                }

                Spacer(minLength: 8)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 500)
    }

    private func helpSection(title: String, @ViewBuilder body: () -> Text) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            body()
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func helpBullet(label: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").font(.body).foregroundColor(.secondary)
            (Text(label).bold() + Text(" — ") + Text(body))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Enums

enum PickerMode   { case negatives, reference, outputFolder }
enum OutputFormat { case jpeg, tiff }
enum AppMode      { case convertNegatives, enhancePositives }
enum ProcessMode  { case automatic, balanced, useReference }

// MARK: - Panel label style

struct PanelLabelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.headline)
            .foregroundColor(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(6)
    }
}

// MARK: - Main View

struct ContentView: View {

    // Source
    @State private var appMode: AppMode = .convertNegatives
    @State private var selectedImages: [URL] = []

    // Process
    @State private var processMode: ProcessMode = .automatic
    // Checkbox state vars removed — Balanced always applies both corrections
    // @State private var normalizeMidtones = false
    // @State private var balanceContrast   = false
    @State private var referenceURL: URL?
    @State private var referenceImage: NSImage?

    // Output
    @State private var outputFormat: OutputFormat = .jpeg
    @State private var lastResultImage: NSImage?

    // Processing state
    @State private var isProcessing       = false
    @State private var processingProgress = 0.0
    @State private var currentImageName   = ""

    // Output directory (persisted via security-scoped bookmark)
    @State private var outputDirectory: URL? = nil

    // Pickers / alerts
    @State private var showingPicker        = false
    @State private var pickerMode: PickerMode = .negatives
    @State private var alertMessage  = ""
    @State private var showingAlert  = false

    // Derived
    private var useReference: Bool            { processMode == .useReference }
    private var normalizeMidtonesActive: Bool { processMode == .balanced }
    private var balanceContrastActive: Bool   { processMode == .balanced }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                sourcePanel
                arrowSpacer
                processPanel
                arrowSpacer
                outputPanel
            }
            .padding([.top, .horizontal], 16)
            .padding(.bottom, 8)

            actionBar
                .padding([.horizontal, .bottom], 16)
        }
        .frame(minWidth: 960, minHeight: 580)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: pickerMode == .negatives ? supportedTypes
                               : pickerMode == .reference ? [.jpeg, .png, .tiff]
                               : [.folder],
            allowsMultipleSelection: pickerMode == .negatives
        ) { result in
            switch pickerMode {
            case .negatives:    handleNegativeSelection(result)
            case .reference:    handleReferenceSelection(result)
            case .outputFolder: handleOutputFolderSelection(result)
            }
        }
        .alert("Result", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            loadSavedOutputDirectory()
        }
    }

    // MARK: - SOURCE panel

    private var sourcePanel: some View {
        panelContainer(color: .green, title: "Input") {
            VStack(alignment: .leading, spacing: 8) {
                radioButton("Convert Negatives", selected: appMode == .convertNegatives) {
                    appMode = .convertNegatives
                }
                radioButton("Enhance Images", selected: appMode == .enhancePositives) {
                    appMode = .enhancePositives
                }
            }
            .padding(.bottom, 8)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.blue.opacity(0.35), lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(Color.gray.opacity(0.05)))
                if selectedImages.isEmpty {
                    emptySourceState
                } else {
                    imageListView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                        guard let data = item as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        DispatchQueue.main.async {
                            if !selectedImages.contains(url) { selectedImages.append(url) }
                        }
                    }
                }
                return true
            }
        }
    }

    private var emptySourceState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 52)).foregroundColor(.blue)
            Text(appMode == .convertNegatives
                 ? "Select negative images to convert"
                 : "Select images for enhancement")
                .font(.headline).multilineTextAlignment(.center)
            Button("Select Images") {
                pickerMode = .negatives
                showingPicker = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var imageListView: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(selectedImages.count) image\(selectedImages.count == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
                Button("Clear") { selectedImages = [] }.buttonStyle(.bordered)
                Button("Add") {
                    pickerMode = .negatives
                    showingPicker = true
                }.buttonStyle(.bordered)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(selectedImages, id: \.self) { url in
                        imageRowView(url)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private func imageRowView(_ url: URL) -> some View {
        let ext    = outputFormat == .jpeg ? "jpg" : "tiff"
        let suffix = appMode == .convertNegatives ? "_p" : "_e"
        return HStack {
            Image(systemName: "photo").foregroundColor(.blue).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(.caption, design: .monospaced))
                Text("-> \(url.deletingPathExtension().lastPathComponent)\(suffix).\(ext)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.blue)
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(5)
    }

    // MARK: - PROCESS panel

    private var processPanel: some View {
        panelContainer(color: .red, title: "Process") {
            VStack(alignment: .leading, spacing: 6) {
                radioButton("Automatic", selected: processMode == .automatic) {
                    processMode = .automatic
                }
                radioButton("Balanced", selected: processMode == .balanced) {
                    processMode = .balanced
                }

                radioButton("Use Reference Image", selected: processMode == .useReference) {
                    processMode = .useReference
                }
            }
            .padding(.bottom, 8)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.orange.opacity(0.4), lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(Color.gray.opacity(0.05)))

                if let nsImg = referenceImage {
                    Image(nsImage: nsImg)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .bottom) {
                            HStack(spacing: 10) {
                                Button("Change") {
                                    pickerMode = .reference
                                    showingPicker = true
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                                Button("Clear") {
                                    referenceURL   = nil
                                    referenceImage = nil
                                    if processMode == .useReference { processMode = .automatic }
                                }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(8)
                        }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 44)).foregroundColor(.orange.opacity(0.6))
                        Text("No reference image")
                            .font(.headline).foregroundColor(.secondary)
                        Text("Drop here or use button below")
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Select Reference Image") {
                            pickerMode = .reference
                            showingPicker = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    let image = NSImage(contentsOf: url)
                    DispatchQueue.main.async {
                        referenceURL   = url
                        referenceImage = image
                        processMode    = .useReference
                    }
                }
                return true
            }
        }
    }

    // MARK: - OUTPUT panel

    private var outputPanel: some View {
        panelContainer(color: .yellow, title: "Output") {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.03)))

                if let result = lastResultImage {
                    Image(nsImage: result)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.artframe")
                            .font(.system(size: 44)).foregroundColor(.gray.opacity(0.4))
                        Text("Output preview")
                            .font(.headline).foregroundColor(.secondary)
                        Text("Last converted image\nwill appear here")
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Text("Output Format")
                    .font(.caption).foregroundColor(.secondary)
                HStack(spacing: 16) {
                    radioButton("JPEG", selected: outputFormat == .jpeg) {
                        outputFormat = .jpeg
                    }
                    radioButton("TIFF", selected: outputFormat == .tiff) {
                        outputFormat = .tiff
                    }
                }

                Divider().padding(.vertical, 4)

                Text("Output Folder")
                    .font(.caption).foregroundColor(.secondary)
                Text(outputDirectory?.path ?? "Not selected")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(outputDirectory == nil ? .red : .primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Button("Select Output Folder") {
                    pickerMode = .outputFolder
                    showingPicker = true
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - ACTION bar

    private var actionBar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(0.07))
                .stroke(Color.blue.opacity(0.15), lineWidth: 1)

            if isProcessing {
                processingView
                    .padding(.horizontal, 20)
            } else {
                Button(appMode == .convertNegatives ? "Convert to Positives" : "Enhance Images") {
                    Task { await processImages() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .font(.headline)
                .disabled(selectedImages.isEmpty)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 64)
    }

    private var processingView: some View {
        VStack(spacing: 6) {
            HStack {
                Text(appMode == .convertNegatives ? "Converting..." : "Enhancing...")
                    .font(.headline)
                Spacer()
                Text("\(Int(processingProgress * 100))%")
                    .font(.headline).foregroundColor(.blue)
            }
            ProgressView(value: processingProgress)
                .progressViewStyle(LinearProgressViewStyle())
            if !currentImageName.isEmpty {
                Text("Processing: \(currentImageName)")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Panel container helper

    private func panelContainer<Content: View>(
        color: Color,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14)
                .stroke(color.opacity(0.35), lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(color.opacity(0.06)))

            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 28)
                content()
                    .padding([.horizontal, .bottom], 12)
                    .padding(.top, 8)
            }

            Text(title)
                .modifier(PanelLabelStyle())
                .offset(y: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


    // MARK: - Arrow between panels

    private var arrowSpacer: some View {
        VStack {
            Spacer()
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 14))
                .foregroundColor(.red.opacity(0.7))
            Spacer()
        }
        .frame(width: 24)
    }

    // MARK: - Radio / checkbox helpers

    private func radioButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(.blue)
                Text(label).font(.body)
            }
        }
        .buttonStyle(.plain)
    }

    private func checkBox(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.checkbox)
            .font(.body)
    }

    // MARK: - File selection handlers

    private func handleNegativeSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls where !selectedImages.contains(url) {
                _ = url.startAccessingSecurityScopedResource()
                selectedImages.append(url)
            }
        case .failure(let error):
            alertMessage = "Failed to select images: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func handleReferenceSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            referenceURL   = url
            referenceImage = NSImage(contentsOf: url)
            processMode    = .useReference
        case .failure(let error):
            alertMessage = "Failed to select reference: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    // MARK: - Output folder bookmark persistence

    private static let bookmarkKey = "outputDirectoryBookmark"

    private func loadSavedOutputDirectory() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return }
        if isStale {
            saveOutputDirectoryBookmark(url)
        }
        _ = url.startAccessingSecurityScopedResource()
        outputDirectory = url
    }

    private func saveOutputDirectoryBookmark(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }

    private func handleOutputFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            outputDirectory = url
            saveOutputDirectoryBookmark(url)
        case .failure(let error):
            alertMessage = "Failed to select output folder: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    // MARK: - Main processing dispatcher

    @MainActor
    private func processImages() async {
        guard !selectedImages.isEmpty else { return }

        guard let outputDir = outputDirectory else {
            alertMessage = "Please select an output folder before converting."
            showingAlert = true
            return
        }

        let imageTypeAnalyzer = ImageTypeAnalyzer()
        let colorProcessor    = ImageProcessorColor()
        let bwProcessor       = ImageProcessorBW()

        let activeReference: URL? = useReference ? referenceURL : nil

        var referenceIsBW = false
        if let refURL = activeReference,
           let refImage = try? loadImageForAnalysis(from: refURL) {
            let refType = try? imageTypeAnalyzer.analyzeImageType(refImage)
            referenceIsBW = (refType == .blackAndWhite)
            let refTypeStr = referenceIsBW ? "BW" : "COLOR"
            print("📋 Reference type: \(refTypeStr) -> transferLuminance=\(referenceIsBW)")
        }

        isProcessing       = true
        processingProgress = 0.0

        let total = selectedImages.count
        var completed     = 0
        var successCount  = 0
        var errorMessages: [String] = []

        for imageURL in selectedImages {
            currentImageName = imageURL.lastPathComponent

            do {
                let inputImage = try loadImageForAnalysis(from: imageURL)
                let imageType  = try imageTypeAnalyzer.analyzeImageType(inputImage)

                if appMode == .convertNegatives {
                    switch imageType {
                    case .color:
                        let hasRef = activeReference != nil ? "yes" : "no"
                        print("🔀 ROUTING: \(imageURL.lastPathComponent) -> COLOR (reference: \(hasRef))")
                        try await colorProcessor.convertImageColor(
                            sourceURL: imageURL, outputDirectory: outputDir,
                            referenceURL: activeReference,
                            outputFormat: outputFormat,
                            normalizeMidtones: normalizeMidtonesActive,
                            transferLuminance: referenceIsBW,
                            balanceContrast: balanceContrastActive)

                    case .blackAndWhite:
                        if let ref = activeReference {
                            print("🔀 ROUTING: \(imageURL.lastPathComponent) -> COLOR with reference (greyscale + reference)")
                            try await colorProcessor.convertImageColor(
                                sourceURL: imageURL, outputDirectory: outputDir,
                                referenceURL: ref,
                                outputFormat: outputFormat,
                                normalizeMidtones: normalizeMidtonesActive,
                                transferLuminance: referenceIsBW,
                                balanceContrast: false,
                                sourceIsGrayscale: !referenceIsBW)
                        } else {
                            print("🔀 ROUTING: \(imageURL.lastPathComponent) -> BW processor")
                            try await bwProcessor.convertImageBW(
                                sourceURL: imageURL, outputDirectory: outputDir,
                                outputFormat: outputFormat,
                                normalizeMidtones: normalizeMidtonesActive,
                                balanceContrast: balanceContrastActive)
                        }
                    }

                } else {
                    switch imageType {
                    case .color:
                        let hasRef = activeReference != nil ? "yes" : "no"
                        print("🔀 ENHANCE: \(imageURL.lastPathComponent) -> COLOR enhance (reference: \(hasRef))")
                        try await colorProcessor.enhancePositiveColor(
                            sourceURL: imageURL, outputDirectory: outputDir,
                            referenceURL: activeReference,
                            outputFormat: outputFormat,
                            normalizeMidtones: normalizeMidtonesActive,
                            transferLuminance: referenceIsBW,
                            balanceContrast: balanceContrastActive)

                    case .blackAndWhite:
                        if let ref = activeReference {
                            print("🔀 ENHANCE: \(imageURL.lastPathComponent) -> COLOR enhance with reference (greyscale + reference)")
                            try await colorProcessor.enhancePositiveColor(
                                sourceURL: imageURL, outputDirectory: outputDir,
                                referenceURL: ref,
                                outputFormat: outputFormat,
                                normalizeMidtones: normalizeMidtonesActive,
                                transferLuminance: referenceIsBW,
                                balanceContrast: false,
                                sourceIsGrayscale: !referenceIsBW)
                        } else {
                            print("🔀 ENHANCE: \(imageURL.lastPathComponent) -> BW enhance")
                            try await bwProcessor.enhancePositiveBW(
                                sourceURL: imageURL, outputDirectory: outputDir,
                                outputFormat: outputFormat,
                                normalizeMidtones: normalizeMidtonesActive,
                                balanceContrast: balanceContrastActive)
                        }
                    }
                }

                let outputURL = lastOutputURL(for: imageURL)
                if let url = outputURL, let img = NSImage(contentsOf: url) {
                    lastResultImage = img
                }

                successCount += 1
                print("✅ SUCCESS: \(imageURL.lastPathComponent)")

            } catch {
                errorMessages.append("\(imageURL.lastPathComponent): \(error.localizedDescription)")
                print("❌ ERROR: \(imageURL.lastPathComponent): \(error)")
            }

            completed += 1
            processingProgress = Double(completed) / Double(total)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        isProcessing     = false
        currentImageName = ""

        if errorMessages.isEmpty {
            alertMessage = "✓ Processed all \(successCount) image\(successCount == 1 ? "" : "s") successfully."
        } else {
            alertMessage = "Processed \(successCount) of \(total) images.\nErrors:\n\(errorMessages.joined(separator: "\n"))"
        }
        showingAlert = true
    }

    // MARK: - Output URL helper (for preview)

    private func lastOutputURL(for sourceURL: URL) -> URL? {
        let dir    = outputDirectory ?? sourceURL.deletingLastPathComponent()
        let base   = sourceURL.deletingPathExtension().lastPathComponent
        let suffix = appMode == .convertNegatives ? "_p" : "_e"
        let ext    = outputFormat == .jpeg ? "jpg" : "tiff"
        var counter = 1
        var last: URL? = nil
        let first = dir.appendingPathComponent("\(base)\(suffix).\(ext)")
        if FileManager.default.fileExists(atPath: first.path) { last = first }
        while true {
            let candidate = dir.appendingPathComponent("\(base)\(suffix)\(counter).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                last = candidate
                counter += 1
            } else { break }
        }
        return last
    }

    // MARK: - Image loading for analysis

    private func loadImageForAnalysis(from url: URL) throws -> CIImage {
        let ext = url.pathExtension.lowercased()
        if ["arw", "cr2", "nef", "dng", "orf", "raw"].contains(ext) {
            return try loadRAWForAnalysis(from: url)
        }
        guard let image = CIImage(contentsOf: url) else {
            throw NSError(domain: "ImageLoading", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load image"])
        }
        return image
    }

    private func loadRAWForAnalysis(from url: URL) throws -> CIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw NSError(domain: "RAWLoading", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load RAW"])
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform:  true,
            kCGImageSourceThumbnailMaxPixelSize:          1000
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return CIImage(cgImage: cg)
        }
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "RAWLoading", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
        }
        return CIImage(cgImage: cg)
    }

    // MARK: - Supported types

    private var supportedTypes: [UTType] {
        [
            .jpeg, .png, .tiff,
            UTType(filenameExtension: "arw") ?? .data,
            UTType(filenameExtension: "cr2") ?? .data,
            UTType(filenameExtension: "nef") ?? .data,
            UTType(filenameExtension: "dng") ?? .data,
            UTType(filenameExtension: "orf") ?? .data,
            .rawImage
        ]
    }
}



/*
import SwiftUI
import UniformTypeIdentifiers

@main
struct NegativeConverterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Picker mode
enum PickerMode { case negatives, reference }

// MARK: - Output format
enum OutputFormat { case jpeg, tiff }

// MARK: - App mode
enum AppMode { case convertNegatives, enhancePositives }

// MARK: - Main View
struct ContentView: View {
    @State private var appMode: AppMode = .convertNegatives
    @State private var selectedImages: [URL] = []
    @State private var referenceURL: URL?
    @State private var referenceImage: NSImage?
    @State private var useReference = false
    @State private var outputFormat: OutputFormat = .jpeg
    @State private var normalizeMidtones = false
    @State private var balanceContrast = false
    @State private var isProcessing = false
    @State private var processingProgress = 0.0
    @State private var currentImageName = ""
    @State private var showingPicker = false
    @State private var pickerMode: PickerMode = .negatives
    @State private var alertMessage = ""
    @State private var showingAlert = false

    var body: some View {
        VStack(spacing: 24) {
            headerView
            mainPanels
            Spacer()
        }
        .padding(30)
        .frame(minWidth: 860, minHeight: 500)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: pickerMode == .negatives ? supportedTypes : [.jpeg, .png, .tiff],
            allowsMultipleSelection: pickerMode == .negatives
        ) { result in
            if pickerMode == .negatives {
                handleNegativeSelection(result)
            } else {
                handleReferenceSelection(result)
            }
        }
        .alert("Result", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 6) {
            Text(appMode == .convertNegatives
                 ? "Negative to Positive Converter"
                 : "Image Enhancer")
                .font(.largeTitle).fontWeight(.bold)
            Text(appMode == .convertNegatives
                 ? "Create positive images from your negative scans"
                 : "Create enhanced copies of your images")
                .font(.subheadline).foregroundColor(.secondary)
        }
    }

    // MARK: - Two-panel layout

    private var mainPanels: some View {
        GeometryReader { geo in
            let side = min((geo.size.width - 120) / 2 - 12, geo.size.height - 80)
            HStack(alignment: .top, spacing: 0) {
                // Mode selector on the far left
                modeSelectorView
                    .frame(width: 180)
                    .padding(.trailing, 16)

                // Left panel: images
                imagePanel(size: side)

                Spacer().frame(width: 24)

                // Right panel: reference
                referencePanel(size: side)
            }
        }
        .frame(minHeight: 360)
    }

    // MARK: - Mode selector (radio buttons)

    private var modeSelectorView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: { appMode = .convertNegatives }) {
                    HStack(spacing: 8) {
                        Image(systemName: appMode == .convertNegatives ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(.blue)
                        Text("Convert Negatives")
                            .font(.body)
                    }
                }
                .buttonStyle(.plain)

                Button(action: { appMode = .enhancePositives }) {
                    HStack(spacing: 8) {
                        Image(systemName: appMode == .enhancePositives ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(.blue)
                        Text("Enhance Images")
                            .font(.body)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Left panel: image selection

    private func imagePanel(size: CGFloat) -> some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.blue.opacity(0.4), lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.05)))

                if selectedImages.isEmpty {
                    emptyImageState
                } else {
                    imageListView
                }
            }
            .frame(width: size, height: size)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadFileRepresentation(forTypeIdentifier: "public.file-url") { url, _ in
                        guard let url = url else { return }
                        let copy = url.standardizedFileURL
                        DispatchQueue.main.async {
                            if !selectedImages.contains(copy) { selectedImages.append(copy) }
                        }
                    }
                }
                return true
            }

            actionButtons
        }
    }

    private var emptyImageState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 60)).foregroundColor(.blue)
            Text(appMode == .convertNegatives
                 ? "Select negative images to convert"
                 : "Select images for enhancement")
                .font(.headline)
            Button("Select Images") {
                pickerMode = .negatives
                showingPicker = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var imageListView: some View {
        VStack(spacing: 12) {
            HStack {
                Text("\(selectedImages.count) image\(selectedImages.count == 1 ? "" : "s") selected")
                    .font(.headline)
                Spacer()
                Button("Clear") { selectedImages = [] }.buttonStyle(.bordered)
                Button("Add More") {
                    pickerMode = .negatives
                    showingPicker = true
                }.buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(selectedImages, id: \.self) { url in
                        imageRowView(url)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func imageRowView(_ url: URL) -> some View {
        let ext = outputFormat == .jpeg ? "jpg" : "tiff"
        let suffix = appMode == .convertNegatives ? "_p" : "_e"
        return HStack {
            Image(systemName: "photo").foregroundColor(.blue).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(.body, design: .monospaced))
                Text("→ \(url.deletingPathExtension().lastPathComponent)\(suffix).\(ext)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.blue)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(6)
    }

    // MARK: - Right panel: reference image

    private func referencePanel(size: CGFloat) -> some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange.opacity(0.4), lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.05)))

                if let nsImage = referenceImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 60)).foregroundColor(.orange.opacity(0.6))
                        Text("No reference image")
                            .font(.headline).foregroundColor(.secondary)
                        Text("Conversion will use automatic settings")
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                }
            }
            .frame(width: size, height: size)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadFileRepresentation(forTypeIdentifier: "public.file-url") { url, _ in
                    guard let url = url else { return }
                    let copy = url.standardizedFileURL
                    let image = NSImage(contentsOf: copy)
                    DispatchQueue.main.async {
                        referenceURL = copy
                        referenceImage = image
                        useReference = true
                    }
                }
                return true
            }

            HStack(spacing: 12) {
                Button(referenceURL == nil ? "Select a reference image" : "Change reference") {
                    pickerMode = .reference
                    showingPicker = true
                }
                .buttonStyle(.bordered)

                if referenceURL != nil {
                    Toggle("Use Reference Image", isOn: $useReference)
                        .toggleStyle(.checkbox)

                    Button("Clear") {
                        referenceURL = nil
                        referenceImage = nil
                        useReference = false
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }

            // Output format picker
            Picker("Output Format", selection: $outputFormat) {
                Text("JPEG").tag(OutputFormat.jpeg)
                Text("TIFF").tag(OutputFormat.tiff)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
        }
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        if isProcessing {
            processingView
        } else {
                let referenceActive = useReference && referenceURL != nil
                VStack(spacing: 10) {
                Button(appMode == .convertNegatives ? "Convert to Positives" : "Enhance Images") {
                    Task { await processImages() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .font(.headline)
                .disabled(selectedImages.isEmpty)

                Toggle("Balance brightness", isOn: $normalizeMidtones)
                    .toggleStyle(.checkbox)
                    .font(.body)
                    .disabled(referenceActive)
                    .opacity(referenceActive ? 0.4 : 1.0)

                Toggle("Balance contrast", isOn: $balanceContrast)
                    .toggleStyle(.checkbox)
                    .font(.body)
                    .disabled(referenceActive)
                    .opacity(referenceActive ? 0.4 : 1.0)

                if referenceActive {
                    Text("Not applied when reference image is used")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var processingView: some View {
        VStack(spacing: 10) {
            HStack {
                Text(appMode == .convertNegatives ? "Converting..." : "Enhancing...")
                    .font(.headline)
                Spacer()
                Text("\(Int(processingProgress * 100))%")
                    .font(.headline).foregroundColor(.blue)
            }
            ProgressView(value: processingProgress)
                .progressViewStyle(LinearProgressViewStyle())
            if !currentImageName.isEmpty {
                Text("Processing: \(currentImageName)")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.08))
        .cornerRadius(10)
    }

    // MARK: - File selection handlers

    private func handleNegativeSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls where !selectedImages.contains(url) {
                _ = url.startAccessingSecurityScopedResource()
                selectedImages.append(url)
            }
        case .failure(let error):
            alertMessage = "Failed to select images: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func handleReferenceSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            referenceURL = url
            referenceImage = NSImage(contentsOf: url)
            useReference = true
        case .failure(let error):
            alertMessage = "Failed to select reference: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    // MARK: - Main processing dispatcher

    @MainActor
    private func processImages() async {
        guard !selectedImages.isEmpty else { return }

        let imageTypeAnalyzer = ImageTypeAnalyzer()
        let colorProcessor    = ImageProcessorColor()
        let bwProcessor       = ImageProcessorBW()

        let activeReference: URL? = (useReference && referenceURL != nil) ? referenceURL : nil


        // Determine if reference is BW — full Lab transfer (L+a+b) if so, a+b only otherwise
        var referenceIsBW = false
        if let refURL = activeReference,
           let refImage = try? loadImageForAnalysis(from: refURL) {
            let refType = try? imageTypeAnalyzer.analyzeImageType(refImage)
            referenceIsBW = (refType == .blackAndWhite)
            print("📋 Reference type: \(referenceIsBW ? "BW" : "COLOR") → transferLuminance=\(referenceIsBW)")
        }
        isProcessing = true
        processingProgress = 0.0

        let total = selectedImages.count
        var completed = 0
        var successCount = 0
        var errorMessages: [String] = []

        for imageURL in selectedImages {
            currentImageName = imageURL.lastPathComponent

            do {
                let inputImage = try loadImageForAnalysis(from: imageURL)
                let imageType  = try imageTypeAnalyzer.analyzeImageType(inputImage)

                if appMode == .convertNegatives {
                    // ── NEGATIVE CONVERSION — original logic, untouched ──
                    switch imageType {
                    case .color:
                        print("🔀 ROUTING: \(imageURL.lastPathComponent) → COLOR (reference: \(activeReference != nil ? "yes" : "no"))")
                        //try await colorProcessor.convertImageColor(sourceURL: imageURL, referenceURL: activeReference, outputFormat: outputFormat, normalizeMidtones: normalizeMidtones)
                        try await colorProcessor.convertImageColor(
                            sourceURL: imageURL, referenceURL: activeReference,
                            outputFormat: outputFormat, normalizeMidtones: normalizeMidtones,
                            transferLuminance: referenceIsBW, balanceContrast: balanceContrast)
                    case .blackAndWhite:
                        if let ref = activeReference {
                            print("🔀 ROUTING: \(imageURL.lastPathComponent) → COLOR with reference (greyscale + reference)")
                            //try await colorProcessor.convertImageColor(sourceURL: imageURL, referenceURL: ref, outputFormat: outputFormat, normalizeMidtones: normalizeMidtones)
                            try await colorProcessor.convertImageColor(
                                sourceURL: imageURL, referenceURL: ref,
                                outputFormat: outputFormat, normalizeMidtones: normalizeMidtones,
                                transferLuminance: referenceIsBW, balanceContrast: false)
                        } else {
                            print("🔀 ROUTING: \(imageURL.lastPathComponent) → BW processor")
                            try await bwProcessor.convertImageBW(sourceURL: imageURL, outputFormat: outputFormat, normalizeMidtones: normalizeMidtones, balanceContrast: balanceContrast)
                        }
                    }

                } else {
                    // ── ENHANCE POSITIVES — new logic ──
                    switch imageType {
                    case .color:
                        print("🔀 ENHANCE: \(imageURL.lastPathComponent) → COLOR enhance (reference: \(activeReference != nil ? "yes" : "no"))")
                        try await colorProcessor.enhancePositiveColor(sourceURL: imageURL, referenceURL: activeReference, outputFormat: outputFormat, normalizeMidtones: normalizeMidtones, transferLuminance: referenceIsBW, balanceContrast: balanceContrast)

                    case .blackAndWhite:
                        if let ref = activeReference {
                            print("🔀 ENHANCE: \(imageURL.lastPathComponent) → COLOR enhance with reference (greyscale + reference)")
                            try await colorProcessor.enhancePositiveColor(sourceURL: imageURL, referenceURL: ref, outputFormat: outputFormat, normalizeMidtones: normalizeMidtones, transferLuminance: referenceIsBW, balanceContrast: false)
                        } else {
                            print("🔀 ENHANCE: \(imageURL.lastPathComponent) → BW enhance")
                            try await bwProcessor.enhancePositiveBW(sourceURL: imageURL, outputFormat: outputFormat, normalizeMidtones: normalizeMidtones, balanceContrast: balanceContrast)
                        }
                    }
                }

                successCount += 1
                print("✅ SUCCESS: \(imageURL.lastPathComponent)")

            } catch {
                errorMessages.append("\(imageURL.lastPathComponent): \(error.localizedDescription)")
                print("❌ ERROR: \(imageURL.lastPathComponent): \(error)")
            }

            completed += 1
            processingProgress = Double(completed) / Double(total)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        isProcessing = false
        currentImageName = ""

        if errorMessages.isEmpty {
            alertMessage = "✓ Processed all \(successCount) image\(successCount == 1 ? "" : "s") successfully."
        } else {
            alertMessage = "Processed \(successCount) of \(total) images.\nErrors:\n\(errorMessages.joined(separator: "\n"))"
        }
        showingAlert = true
    }

    // MARK: - Image loading for analysis

    private func loadImageForAnalysis(from url: URL) throws -> CIImage {
        let ext = url.pathExtension.lowercased()
        if ["arw", "cr2", "nef", "dng", "orf", "raw"].contains(ext) {
            return try loadRAWForAnalysis(from: url)
        }
        guard let image = CIImage(contentsOf: url) else {
            throw NSError(domain: "ImageLoading", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load image"])
        }
        return image
    }

    private func loadRAWForAnalysis(from url: URL) throws -> CIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw NSError(domain: "RAWLoading", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load RAW"])
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1000
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return CIImage(cgImage: cg)
        }
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "RAWLoading", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
        }
        return CIImage(cgImage: cg)
    }

    // MARK: - Supported types

    private var supportedTypes: [UTType] {
        [
            .jpeg, .png, .tiff,
            UTType(filenameExtension: "arw") ?? .data,
            UTType(filenameExtension: "cr2") ?? .data,
            UTType(filenameExtension: "nef") ?? .data,
            UTType(filenameExtension: "dng") ?? .data,
            UTType(filenameExtension: "orf") ?? .data,
            .rawImage
        ]
    }
}
*/

/*
import SwiftUI
import UniformTypeIdentifiers

@main
struct NegativeConverterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Picker mode
enum PickerMode { case negatives, reference }

// MARK: - Output format
enum OutputFormat { case jpeg, tiff }

// MARK: - App mode
enum AppMode { case convertNegatives, enhancePositives }

// MARK: - Main View
struct ContentView: View {
    @State private var appMode: AppMode = .convertNegatives
    @State private var selectedImages: [URL] = []
    @State private var referenceURL: URL?
    @State private var referenceImage: NSImage?
    @State private var useReference = false
    @State private var outputFormat: OutputFormat = .jpeg
    @State private var normalizeMidtones = false
    @State private var balanceContrast = false
    @State private var isProcessing = false
    @State private var processingProgress = 0.0
    @State private var currentImageName = ""
    @State private var showingPicker = false
    @State private var pickerMode: PickerMode = .negatives
    @State private var alertMessage = ""
    @State private var showingAlert = false

    var body: some View {
        VStack(spacing: 24) {
            headerView
            mainPanels
            Spacer()
        }
        .padding(30)
        .frame(minWidth: 860, minHeight: 500)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: pickerMode == .negatives ? supportedTypes : [.jpeg, .png, .tiff],
            allowsMultipleSelection: pickerMode == .negatives
        ) { result in
            if pickerMode == .negatives {
                handleNegativeSelection(result)
            } else {
                handleReferenceSelection(result)
            }
        }
        .alert("Result", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 6) {
            Text(appMode == .convertNegatives
                 ? "Negative to Positive Converter"
                 : "Image Enhancer")
                .font(.largeTitle).fontWeight(.bold)
            Text(appMode == .convertNegatives
                 ? "Create positive images from your negative scans"
                 : "Create enhanced copies of your images")
                .font(.subheadline).foregroundColor(.secondary)
        }
    }

    // MARK: - Two-panel layout

    private var mainPanels: some View {
        GeometryReader { geo in
            let side = min((geo.size.width - 120) / 2 - 12, geo.size.height - 80)
            HStack(alignment: .top, spacing: 0) {
                // Mode selector on the far left
                modeSelectorView
                    .frame(width: 180)
                    .padding(.trailing, 16)

                // Left panel: images
                imagePanel(size: side)

                Spacer().frame(width: 24)

                // Right panel: reference
                referencePanel(size: side)
            }
        }
        .frame(minHeight: 360)
    }

    // MARK: - Mode selector (radio buttons)

    private var modeSelectorView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: { appMode = .convertNegatives }) {
                    HStack(spacing: 8) {
                        Image(systemName: appMode == .convertNegatives ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(.blue)
                        Text("Convert Negatives")
                            .font(.body)
                    }
                }
                .buttonStyle(.plain)

                Button(action: { appMode = .enhancePositives }) {
                    HStack(spacing: 8) {
                        Image(systemName: appMode == .enhancePositives ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(.blue)
                        Text("Enhance Images")
                            .font(.body)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Left panel: image selection

    private func imagePanel(size: CGFloat) -> some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.blue.opacity(0.4), lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.05)))

                if selectedImages.isEmpty {
                    emptyImageState
                } else {
                    imageListView
                }
            }
            .frame(width: size, height: size)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadFileRepresentation(forTypeIdentifier: "public.file-url") { url, _ in
                        guard let url = url else { return }
                        let copy = url.standardizedFileURL
                        DispatchQueue.main.async {
                            if !selectedImages.contains(copy) { selectedImages.append(copy) }
                        }
                    }
                }
                return true
            }

            actionButtons
        }
    }

    private var emptyImageState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 60)).foregroundColor(.blue)
            Text(appMode == .convertNegatives
                 ? "Select negative images to convert"
                 : "Select images for enhancement")
                .font(.headline)
            Button("Select Images") {
                pickerMode = .negatives
                showingPicker = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var imageListView: some View {
        VStack(spacing: 12) {
            HStack {
                Text("\(selectedImages.count) image\(selectedImages.count == 1 ? "" : "s") selected")
                    .font(.headline)
                Spacer()
                Button("Clear") { selectedImages = [] }.buttonStyle(.bordered)
                Button("Add More") {
                    pickerMode = .negatives
                    showingPicker = true
                }.buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(selectedImages, id: \.self) { url in
                        imageRowView(url)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func imageRowView(_ url: URL) -> some View {
        let ext = outputFormat == .jpeg ? "jpg" : "tiff"
        let suffix = appMode == .convertNegatives ? "_p" : "_e"
        return HStack {
            Image(systemName: "photo").foregroundColor(.blue).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(.body, design: .monospaced))
                Text("→ \(url.deletingPathExtension().lastPathComponent)\(suffix).\(ext)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.blue)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(6)
    }

    // MARK: - Right panel: reference image

    private func referencePanel(size: CGFloat) -> some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange.opacity(0.4), lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.05)))

                if let nsImage = referenceImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 60)).foregroundColor(.orange.opacity(0.6))
                        Text("No reference image")
                            .font(.headline).foregroundColor(.secondary)
                        Text("Conversion will use automatic settings")
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                }
            }
            .frame(width: size, height: size)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadFileRepresentation(forTypeIdentifier: "public.file-url") { url, _ in
                    guard let url = url else { return }
                    let copy = url.standardizedFileURL
                    let image = NSImage(contentsOf: copy)
                    DispatchQueue.main.async {
                        referenceURL = copy
                        referenceImage = image
                        useReference = true
                    }
                }
                return true
            }

            HStack(spacing: 12) {
                Button(referenceURL == nil ? "Select a reference image" : "Change reference") {
                    pickerMode = .reference
                    showingPicker = true
                }
                .buttonStyle(.bordered)

                if referenceURL != nil {
                    Toggle("Use Reference Image", isOn: $useReference)
                        .toggleStyle(.checkbox)

                    Button("Clear") {
                        referenceURL = nil
                        referenceImage = nil
                        useReference = false
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }

            // Output format picker
            Picker("Output Format", selection: $outputFormat) {
                Text("JPEG").tag(OutputFormat.jpeg)
                Text("TIFF").tag(OutputFormat.tiff)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
        }
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        if isProcessing {
            processingView
        } else {
                let referenceActive = useReference && referenceURL != nil
                VStack(spacing: 10) {
                Button(appMode == .convertNegatives ? "Convert to Positives" : "Enhance Images") {
                    Task { await processImages() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .font(.headline)
                .disabled(selectedImages.isEmpty)

                Toggle("Balance brightness", isOn: $normalizeMidtones)
                    .toggleStyle(.checkbox)
                    .font(.body)
                    .disabled(referenceActive)
                    .opacity(referenceActive ? 0.4 : 1.0)

                Toggle("Balance contrast", isOn: $balanceContrast)
                    .toggleStyle(.checkbox)
                    .font(.body)
                    .disabled(referenceActive)
                    .opacity(referenceActive ? 0.4 : 1.0)

                if referenceActive {
                    Text("Not applied when reference image is used")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var processingView: some View {
        VStack(spacing: 10) {
            HStack {
                Text(appMode == .convertNegatives ? "Converting..." : "Enhancing...")
                    .font(.headline)
                Spacer()
                Text("\(Int(processingProgress * 100))%")
                    .font(.headline).foregroundColor(.blue)
            }
            ProgressView(value: processingProgress)
                .progressViewStyle(LinearProgressViewStyle())
            if !currentImageName.isEmpty {
                Text("Processing: \(currentImageName)")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.08))
        .cornerRadius(10)
    }

    // MARK: - File selection handlers

    private func handleNegativeSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls where !selectedImages.contains(url) {
                _ = url.startAccessingSecurityScopedResource()
                selectedImages.append(url)
            }
        case .failure(let error):
            alertMessage = "Failed to select images: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func handleReferenceSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            referenceURL = url
            referenceImage = NSImage(contentsOf: url)
            useReference = true
        case .failure(let error):
            alertMessage = "Failed to select reference: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    // MARK: - Main processing dispatcher

    @MainActor
    private func processImages() async {
        guard !selectedImages.isEmpty else { return }

        let imageTypeAnalyzer = ImageTypeAnalyzer()
        let colorProcessor    = ImageProcessorColor()
        let bwProcessor       = ImageProcessorBW()

        let activeReference: URL? = (useReference && referenceURL != nil) ? referenceURL : nil


        // Determine if reference is BW — full Lab transfer (L+a+b) if so, a+b only otherwise
        var referenceIsBW = false
        if let refURL = activeReference,
           let refImage = try? loadImageForAnalysis(from: refURL) {
            let refType = try? imageTypeAnalyzer.analyzeImageType(refImage)
            referenceIsBW = (refType == .blackAndWhite)
            print("📋 Reference type: \(referenceIsBW ? "BW" : "COLOR") → transferLuminance=\(referenceIsBW)")
        }
        isProcessing = true
        processingProgress = 0.0

        let total = selectedImages.count
        var completed = 0
        var successCount = 0
        var errorMessages: [String] = []

        for imageURL in selectedImages {
            currentImageName = imageURL.lastPathComponent

            do {
                let inputImage = try loadImageForAnalysis(from: imageURL)
                let imageType  = try imageTypeAnalyzer.analyzeImageType(inputImage)

                if appMode == .convertNegatives {
                    // ── NEGATIVE CONVERSION — original logic, untouched ──
                    switch imageType {
                    case .color:
                        print("🔀 ROUTING: \(imageURL.lastPathComponent) → COLOR (reference: \(activeReference != nil ? "yes" : "no"))")
                        //try await colorProcessor.convertImageColor(sourceURL: imageURL, referenceURL: activeReference, outputFormat: outputFormat, normalizeMidtones: normalizeMidtones)
                        try await colorProcessor.convertImageColor(
                            sourceURL: imageURL, referenceURL: activeReference,
                            outputFormat: outputFormat, normalizeMidtones: normalizeMidtones,
                            transferLuminance: referenceIsBW, balanceContrast: balanceContrast)
                    case .blackAndWhite:
                        if let ref = activeReference {
                            print("🔀 ROUTING: \(imageURL.lastPathComponent) → COLOR with reference (greyscale + reference)")
                            //try await colorProcessor.convertImageColor(sourceURL: imageURL, referenceURL: ref, outputFormat: outputFormat, normalizeMidtones: normalizeMidtones)
                            try await colorProcessor.convertImageColor(
                                sourceURL: imageURL, referenceURL: ref,
                                outputFormat: outputFormat, normalizeMidtones: normalizeMidtones,
                                transferLuminance: referenceIsBW, balanceContrast: false)
                        } else {
                            print("🔀 ROUTING: \(imageURL.lastPathComponent) → BW processor")
                            try await bwProcessor.convertImageBW(sourceURL: imageURL, outputFormat: outputFormat, normalizeMidtones: normalizeMidtones, balanceContrast: balanceContrast)
                        }
                    }

                } else {
                    // ── ENHANCE POSITIVES — new logic ──
                    switch imageType {
                    case .color:
                        print("🔀 ENHANCE: \(imageURL.lastPathComponent) → COLOR enhance (reference: \(activeReference != nil ? "yes" : "no"))")
                        try await colorProcessor.enhancePositiveColor(sourceURL: imageURL, referenceURL: activeReference, outputFormat: outputFormat, normalizeMidtones: normalizeMidtones, transferLuminance: referenceIsBW, balanceContrast: balanceContrast)

                    case .blackAndWhite:
                        if let ref = activeReference {
                            print("🔀 ENHANCE: \(imageURL.lastPathComponent) → COLOR enhance with reference (greyscale + reference)")
                            try await colorProcessor.enhancePositiveColor(sourceURL: imageURL, referenceURL: ref, outputFormat: outputFormat, normalizeMidtones: normalizeMidtones, transferLuminance: referenceIsBW, balanceContrast: false)
                        } else {
                            print("🔀 ENHANCE: \(imageURL.lastPathComponent) → BW enhance")
                            try await bwProcessor.enhancePositiveBW(sourceURL: imageURL, outputFormat: outputFormat, normalizeMidtones: normalizeMidtones, balanceContrast: balanceContrast)
                        }
                    }
                }

                successCount += 1
                print("✅ SUCCESS: \(imageURL.lastPathComponent)")

            } catch {
                errorMessages.append("\(imageURL.lastPathComponent): \(error.localizedDescription)")
                print("❌ ERROR: \(imageURL.lastPathComponent): \(error)")
            }

            completed += 1
            processingProgress = Double(completed) / Double(total)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        isProcessing = false
        currentImageName = ""

        if errorMessages.isEmpty {
            alertMessage = "✓ Processed all \(successCount) image\(successCount == 1 ? "" : "s") successfully."
        } else {
            alertMessage = "Processed \(successCount) of \(total) images.\nErrors:\n\(errorMessages.joined(separator: "\n"))"
        }
        showingAlert = true
    }

    // MARK: - Image loading for analysis

    private func loadImageForAnalysis(from url: URL) throws -> CIImage {
        let ext = url.pathExtension.lowercased()
        if ["arw", "cr2", "nef", "dng", "orf", "raw"].contains(ext) {
            return try loadRAWForAnalysis(from: url)
        }
        guard let image = CIImage(contentsOf: url) else {
            throw NSError(domain: "ImageLoading", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load image"])
        }
        return image
    }

    private func loadRAWForAnalysis(from url: URL) throws -> CIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw NSError(domain: "RAWLoading", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load RAW"])
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1000
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return CIImage(cgImage: cg)
        }
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "RAWLoading", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
        }
        return CIImage(cgImage: cg)
    }

    // MARK: - Supported types

    private var supportedTypes: [UTType] {
        [
            .jpeg, .png, .tiff,
            UTType(filenameExtension: "arw") ?? .data,
            UTType(filenameExtension: "cr2") ?? .data,
            UTType(filenameExtension: "nef") ?? .data,
            UTType(filenameExtension: "dng") ?? .data,
            UTType(filenameExtension: "orf") ?? .data,
            .rawImage
        ]
    }
}
*/
