// Copyright (C) 2025-2026 Ari Jaaksi. All rights reserved.
// Licensed under GPLv3 or a commercial license.
// See LICENSE.txt for details or contact [ari@slowlight.art] for commercial licensing.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NegativeCore

/// One dropped file and everything known about it.
struct NegativeItem: Identifiable {
    enum Stage: Equatable {
        case waiting
        case analyzing
        case ready
        case failed(String)
    }

    enum ExportStage: Equatable {
        case none
        case queued
        case exporting
        case done(String)      // name of the written file
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var stage: Stage = .waiting
    var exportStage: ExportStage = .none
    var preview: HalfImage?
    var analysis: NegativeAnalysis?
    var settings = ConversionSettings()
    var rendered: CGImage?
    var renderGeneration = 0

    var name: String { url.lastPathComponent }

    /// Whether tones are placed by film exposure (true) or fitted to the
    /// picture (false). Film exposure needs clear film in the frame.
    var usesFilmExposure: Bool {
        settings.toneMode == .filmExposure && analysis?.clearFilmFound == true
    }

    /// Whether this image will be converted as black-and-white, once known.
    var isMonochrome: Bool? {
        switch settings.filmType {
        case .color: return false
        case .blackAndWhite: return true
        case .auto: return analysis?.isBlackAndWhite
        }
    }
}

/// Work that runs off the main thread.
private enum Processing {
    struct Prepared: @unchecked Sendable {
        let preview: HalfImage
        let analysis: NegativeAnalysis
        let image: CGImage?
    }

    static func prepare(url: URL) throws -> Prepared {
        let preview = try ImagePipeline.makePreview(url: url)
        let analysis = preview.withPixels {
            NegativeAnalyzer.analyze(half: $0, width: preview.width, height: preview.height,
                                     rowStride: preview.rowStride)
        }
        let image = ImagePipeline.renderPreview(preview, analysis: analysis, settings: ConversionSettings())
        return Prepared(preview: preview, analysis: analysis, image: image)
    }

    struct Rendered: @unchecked Sendable {
        let image: CGImage?
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [NegativeItem] = []
    @Published var selection: NegativeItem.ID?
    @Published var outputFolder: URL?
    @Published var outputFormat: OutputFormat = .jpeg
    @Published var jpegQuality: Double = 0.95
    @Published var isExporting = false
    @Published var exportDone = 0
    @Published var exportTotal = 0
    @Published var statusMessage = ""

    private var isAnalyzing = false
    private var cancelExport = false

    /// The output folder is remembered between launches as a security-scoped
    /// bookmark, which lets the sandboxed app open it again without asking.
    private static let outputFolderBookmarkKey = "OutputFolderBookmark"
    /// Set while the remembered folder is opened through its bookmark.
    private var bookmarkedFolder: URL?

    init() {
        restoreOutputFolder()
    }

    var selectedItem: NegativeItem? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    var readyCount: Int { items.filter { $0.stage == .ready }.count }

    private func index(of id: NegativeItem.ID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    // MARK: Adding and removing

    func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in self.add(urls: [url]) }
            }
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .folder]
        panel.message = "Choose photographs of negatives"
        if panel.runModal() == .OK {
            add(urls: panel.urls)
        }
    }

    func add(urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                files.append(contentsOf: contents.filter { ImagePipeline.isSupportedImage($0) })
            } else if ImagePipeline.isSupportedImage(url) {
                files.append(url)
            }
        }
        let known = Set(items.map { $0.url.standardizedFileURL })
        var added = false
        for file in files where !known.contains(file.standardizedFileURL) {
            items.append(NegativeItem(url: file))
            added = true
        }
        guard added else { return }
        items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if selection == nil { selection = items.first?.id }
        pumpAnalysis()
    }

    func remove(_ id: NegativeItem.ID) {
        items.removeAll { $0.id == id }
        if selection == id { selection = items.first?.id }
    }

    func clear() {
        guard !isExporting else { return }
        items.removeAll()
        selection = nil
        statusMessage = ""
    }

    // MARK: Analysis and preview

    /// Analyses waiting items one at a time (a raw decode is memory hungry).
    private func pumpAnalysis() {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        Task {
            while let next = items.first(where: { $0.stage == .waiting }) {
                let id = next.id
                let url = next.url
                if let i = index(of: id) { items[i].stage = .analyzing }
                let result = await Task.detached(priority: .userInitiated) { () -> Result<Processing.Prepared, Error> in
                    do {
                        return .success(try Processing.prepare(url: url))
                    } catch {
                        return .failure(error)
                    }
                }.value
                guard let i = index(of: id) else { continue }   // removed meanwhile
                switch result {
                case .success(let prepared):
                    items[i].preview = prepared.preview
                    items[i].analysis = prepared.analysis
                    items[i].rendered = prepared.image
                    items[i].stage = .ready
                    // Settings may have been changed (Apply to All) while waiting.
                    if items[i].settings != ConversionSettings() { rerender(id) }
                case .failure(let error):
                    items[i].stage = .failed(error.localizedDescription)
                }
            }
            isAnalyzing = false
        }
    }

    /// Two-way access to one item's settings; any change refreshes its preview.
    func settingsBinding(for id: NegativeItem.ID) -> Binding<ConversionSettings> {
        Binding(
            get: { [weak self] in
                self?.items.first { $0.id == id }?.settings ?? ConversionSettings()
            },
            set: { [weak self] newValue in
                guard let self, let i = self.index(of: id), self.items[i].settings != newValue else { return }
                self.items[i].settings = newValue
                self.items[i].exportStage = .none
                self.rerender(id)
            }
        )
    }

    func applySettingsToAll(from id: NegativeItem.ID) {
        guard let source = index(of: id) else { return }
        let settings = items[source].settings
        for i in items.indices where items[i].id != id && items[i].settings != settings {
            items[i].settings = settings
            items[i].exportStage = .none
            rerender(items[i].id)
        }
    }

    private func rerender(_ id: NegativeItem.ID) {
        guard let i = index(of: id), let preview = items[i].preview, let analysis = items[i].analysis else { return }
        items[i].renderGeneration += 1
        let generation = items[i].renderGeneration
        let settings = items[i].settings
        Task {
            let rendered = await Task.detached(priority: .userInitiated) { () -> Processing.Rendered in
                Processing.Rendered(image: ImagePipeline.renderPreview(preview, analysis: analysis, settings: settings))
            }.value
            // Only the most recent request may update the picture.
            if let j = index(of: id), items[j].renderGeneration == generation, let image = rendered.image {
                items[j].rendered = image
            }
        }
    }

    // MARK: Export

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder for the converted files"
        if panel.runModal() == .OK, let url = panel.url {
            setOutputFolder(url)
        }
    }

    private func setOutputFolder(_ url: URL) {
        // A folder chosen in the panel stays accessible until the app quits,
        // so the bookmark of the previous one is no longer needed.
        bookmarkedFolder?.stopAccessingSecurityScopedResource()
        bookmarkedFolder = nil
        outputFolder = url
        rememberOutputFolder(url)
    }

    private func rememberOutputFolder(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: Self.outputFolderBookmarkKey)
    }

    /// Reopens the folder chosen in an earlier session. If it cannot be found
    /// (deleted, or on a drive that is not connected), no folder is set and the
    /// app asks again at the next conversion. The bookmark is kept, so the
    /// folder comes back once the drive is connected again.
    private func restoreOutputFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.outputFolderBookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &isStale) else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            return
        }
        if accessing { bookmarkedFolder = url }
        outputFolder = url
        if isStale { rememberOutputFolder(url) }
    }

    func cancelExporting() {
        cancelExport = true
    }

    func export() {
        guard !isExporting else { return }
        if outputFolder == nil { chooseOutputFolder() }
        guard let folder = outputFolder else { return }

        struct Job {
            let id: NegativeItem.ID
            let url: URL
            let analysis: NegativeAnalysis
            let settings: ConversionSettings
        }
        var jobs: [Job] = []
        for i in items.indices where items[i].stage == .ready {
            guard let analysis = items[i].analysis else { continue }
            jobs.append(Job(id: items[i].id, url: items[i].url, analysis: analysis, settings: items[i].settings))
            items[i].exportStage = .queued
        }
        guard !jobs.isEmpty else { return }

        isExporting = true
        cancelExport = false
        exportDone = 0
        exportTotal = jobs.count
        statusMessage = ""
        let quality = jpegQuality
        let format = outputFormat

        Task {
            var failures = 0
            var written = 0
            var reserved = Set<String>()
            for job in jobs {
                if cancelExport {
                    if let i = index(of: job.id) { items[i].exportStage = .none }
                    continue
                }
                if let i = index(of: job.id) { items[i].exportStage = .exporting }
                let destination = Self.freeDestination(for: job.url, in: folder, format: format,
                                                       reserved: &reserved)
                let source = job.url
                let analysis = job.analysis
                let settings = job.settings
                let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                    do {
                        try ImagePipeline.export(source: source, analysis: analysis, settings: settings,
                                                 destination: destination, format: format, quality: quality)
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }.value
                exportDone += 1
                switch result {
                case .success:
                    written += 1
                    if let i = index(of: job.id) { items[i].exportStage = .done(destination.lastPathComponent) }
                case .failure(let error):
                    failures += 1
                    if let i = index(of: job.id) { items[i].exportStage = .failed(error.localizedDescription) }
                }
            }
            isExporting = false
            var parts = ["\(written) saved to \(folder.lastPathComponent)"]
            if failures > 0 { parts.append("\(failures) failed") }
            if cancelExport { parts.append("cancelled") }
            statusMessage = parts.joined(separator: ", ")
        }
    }

    /// A file name in `folder` that does not exist yet, so nothing is ever overwritten.
    private static func freeDestination(for source: URL, in folder: URL, format: OutputFormat,
                                        reserved: inout Set<String>) -> URL {
        let ext = format.fileExtension
        let base = source.deletingPathExtension().lastPathComponent + "_positive"
        var name = base + "." + ext
        var counter = 2
        while reserved.contains(name.lowercased())
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base)-\(counter).\(ext)"
            counter += 1
        }
        reserved.insert(name.lowercased())
        return folder.appendingPathComponent(name)
    }
}
