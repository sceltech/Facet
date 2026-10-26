import Foundation
import RealityKit
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum DetailLevel: String, CaseIterable, Identifiable {
    case preview, reduced, medium, full
    var id: String { rawValue }

    var label: String {
        switch self {
        case .preview: "Preview (fast)"
        case .reduced: "Reduced"
        case .medium: "Medium"
        case .full: "Full (best quality)"
        }
    }

    var requestDetail: PhotogrammetrySession.Request.Detail {
        switch self {
        case .preview: .preview
        case .reduced: .reduced
        case .medium: .medium
        case .full: .full
        }
    }
}

enum Phase: Equatable {
    case idle, running, finished, cancelled
    case failed(String)
}

struct ImageStats {
    var heic = 0
    var jpeg = 0
    var png = 0
    var total: Int { heic + jpeg + png }

    var summary: String {
        var parts: [String] = []
        if heic > 0 { parts.append("\(heic) HEIC") }
        if jpeg > 0 { parts.append("\(jpeg) JPG") }
        if png > 0 { parts.append("\(png) PNG") }
        let head = "\(total) images"
        return parts.isEmpty ? head : head + " · " + parts.joined(separator: " · ")
    }

    static func scan(_ folder: URL) -> ImageStats {
        var s = ImageStats()
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for item in items {
            switch item.pathExtension.lowercased() {
            case "heic", "heif": s.heic += 1
            case "jpg", "jpeg": s.jpeg += 1
            case "png": s.png += 1
            default: break
            }
        }
        return s
    }
}

struct ReconstructionResult {
    let usdzURL: URL
    let objURL: URL
    let objFolder: URL
    let mesh: TriMesh
}

@MainActor
final class ReconstructionModel: ObservableObject {
    // Input
    @Published var inputFolder: URL?
    @Published var imageStats = ImageStats()

    // Settings
    @Published var detail: DetailLevel = .medium
    @Published var objectMasking = true
    @Published var sequentialOrdering = false
    @Published var highSensitivity = false

    // Progress
    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var stageText = ""
    @Published var remainingText = ""
    @Published var log: [String] = []

    // Result & export
    @Published var result: ReconstructionResult?
    @Published var scaleFactor: Double = 1 {
        didSet { if result != nil && scaleFactor != oldValue { isDirty = true } }
    }
    @Published var exportOptions = ExportOptions()
    @Published var isExporting = false
    @Published var exportMessage: String?
    @Published var lastExportFolder: URL?

    // Project file
    @Published var projectURL: URL?
    @Published var isDirty = false

    private var session: PhotogrammetrySession?
    private var progressByRequest: [String: Double] = [:]
    private var workDir: URL?

    var isSupported: Bool { PhotogrammetrySession.isSupported }
    var blenderURL: URL? { MeshExporter.blenderURL() }

    var failureMessage: String? {
        if case .failed(let msg) = phase { return msg }
        return nil
    }

    func setFolder(_ url: URL) {
        guard confirmDiscardIfNeeded("choosing new photos") else { return }
        projectURL = nil
        inputFolder = url
        imageStats = ImageStats.scan(url)
        exportOptions.name = url.lastPathComponent
        result = nil
        scaleFactor = 1
        phase = .idle
        progress = 0
        log = []
        exportMessage = nil
        isDirty = false
    }

    func start() {
        guard let input = inputFolder else { return }
        if result != nil {
            guard confirmDiscardIfNeeded("starting a new reconstruction") else { return }
        }
        projectURL = nil
        isDirty = false
        let fm = FileManager.default
        if let old = workDir { try? fm.removeItem(at: old) }

        let work = fm.temporaryDirectory
            .appendingPathComponent("Facet", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let objDir = work.appendingPathComponent("obj", isDirectory: true)
        let usdz = work.appendingPathComponent("model.usdz")
        do {
            try fm.createDirectory(at: objDir, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Could not create working folder: \(error.localizedDescription)")
            return
        }
        workDir = work

        var config = PhotogrammetrySession.Configuration()
        config.sampleOrdering = sequentialOrdering ? .sequential : .unordered
        config.featureSensitivity = highSensitivity ? .high : .normal
        config.isObjectMaskingEnabled = objectMasking

        let session: PhotogrammetrySession
        do {
            session = try PhotogrammetrySession(input: input, configuration: config)
        } catch {
            phase = .failed("Could not start session: \(error.localizedDescription)")
            return
        }
        self.session = session

        result = nil
        scaleFactor = 1
        exportMessage = nil
        log = []
        progress = 0
        progressByRequest = [:]
        stageText = "Reading images…"
        remainingText = ""
        phase = .running

        let d = detail.requestDetail
        // Two outputs from one computation: USDZ for the preview,
        // OBJ folder (with textures) as the basis for all exports.
        let requests: [PhotogrammetrySession.Request] = [
            .modelFile(url: usdz, detail: d),
            .modelFile(url: objDir, detail: d)
        ]

        Task { [weak self] in
            do {
                try session.process(requests: requests)
                for try await output in session.outputs {
                    self?.handle(output, usdz: usdz, objDir: objDir)
                }
            } catch {
                self?.fail("Error: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        session?.cancel()
    }

    func calibrate(axis: Int, realMillimeters: Double) {
        guard let r = result, (0...2).contains(axis) else { return }
        let measured = Double(r.mesh.size[axis]) * 1000
        guard measured > 0, realMillimeters > 0 else { return }
        scaleFactor = realMillimeters / measured
    }

    func export(to folder: URL) {
        guard let r = result else { return }
        let options = exportOptions
        let calibration = Float(scaleFactor)
        isExporting = true
        exportMessage = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                MeshExporter.run(result: r, options: options, calibration: calibration, folder: folder)
            }.value
            var lines: [String] = []
            if !outcome.written.isEmpty {
                lines.append("Exported: " + outcome.written.joined(separator: ", "))
            }
            lines.append(contentsOf: outcome.errors)
            exportMessage = lines.joined(separator: "\n")
            lastExportFolder = folder
            isExporting = false
        }
    }

    // MARK: - Photogrammetry session outputs

    private func handle(_ output: PhotogrammetrySession.Output, usdz: URL, objDir: URL) {
        switch output {
        case .inputComplete:
            appendLog("All images read.")
            stageText = "Reconstructing…"
        case .requestProgress(let request, let fraction):
            progressByRequest[String(describing: request)] = fraction
            updateProgress()
        case .requestProgressInfo(_, let info):
            if let stage = info.processingStage {
                stageText = Self.stageName(stage)
            }
            if let t = info.estimatedRemainingTime, t > 0 {
                remainingText = "about " + Self.format(t) + " remaining"
            }
        case .requestComplete(let request, _):
            progressByRequest[String(describing: request)] = 1
            updateProgress()
        case .requestError(_, let error):
            fail("Reconstruction error: \(error.localizedDescription)")
        case .invalidSample(let id, let reason):
            appendLog("Image \(id) invalid: \(reason)")
        case .skippedSample(let id):
            appendLog("Image \(id) skipped.")
        case .automaticDownsampling:
            appendLog("Note: images were automatically downsampled due to memory limits.")
        case .processingComplete:
            finish(usdz: usdz, objDir: objDir)
        case .processingCancelled:
            guard phase == .running else { break }
            session = nil
            phase = .cancelled
            stageText = "Cancelled."
            remainingText = ""
        default:
            break
        }
    }

    private func updateProgress() {
        progress = min(1, progressByRequest.values.reduce(0, +) / 2.0)
    }

    private func finish(usdz: URL, objDir: URL) {
        guard phase == .running else { return }
        session = nil
        stageText = "Loading model…"
        remainingText = ""
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> Result<(URL, TriMesh), Error> in
                do {
                    guard let obj = MeshIO.findOBJ(in: objDir) else { throw ExportError.noMesh }
                    return .success((obj, try MeshIO.loadOBJ(obj)))
                } catch {
                    return .failure(error)
                }
            }.value
            switch loaded {
            case .success(let (obj, mesh)):
                result = ReconstructionResult(usdzURL: usdz, objURL: obj, objFolder: objDir, mesh: mesh)
                progress = 1
                stageText = "Done."
                phase = .finished
                isDirty = true
            case .failure(let error):
                fail("Could not load model: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Project files

    func save() {
        if let url = projectURL {
            writeProject(to: url)
        } else {
            saveAs()
        }
    }

    func saveAs() {
        guard result != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.facetProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (projectURL?.deletingPathExtension().lastPathComponent
                                      ?? MeshExporter.sanitize(exportOptions.name)) + ".facet"
        panel.message = "Saves the 3D model, textures and settings so you can reopen it later."
        if panel.runModal() == .OK, let url = panel.url {
            writeProject(to: url)
        }
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.facetProject]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Open a Facet project"
        if panel.runModal() == .OK, let url = panel.url {
            openProject(at: url)
        }
    }

    func openProject(at url: URL) {
        guard phase != .running else { return }
        guard confirmDiscardIfNeeded("opening another project") else { return }
        let fm = FileManager.default
        if let old = workDir { try? fm.removeItem(at: old) }
        let work = fm.temporaryDirectory
            .appendingPathComponent("Facet", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        workDir = work
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> Result<LoadedProject, Error> in
                Result { try ProjectIO.load(from: url, into: work) }
            }.value
            switch loaded {
            case .success(let project):
                apply(project, from: url)
            case .failure(let error):
                showError("Could not open “\(url.lastPathComponent)”", error)
            }
        }
    }

    /// Asks to save unsaved results. Returns false if the user cancelled.
    func confirmDiscardIfNeeded(_ context: String) -> Bool {
        guard isDirty, result != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the 3D model before \(context)?"
        alert.informativeText = "If you don't save, the reconstruction is lost and has to be computed again."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save()
            return !isDirty
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func writeProject(to url: URL) {
        guard let r = result else { return }
        let settings = ProjectSettings(
            inputFolder: inputFolder?.path,
            detail: detail.rawValue,
            objectMasking: objectMasking,
            sequentialOrdering: sequentialOrdering,
            highSensitivity: highSensitivity,
            scaleFactor: scaleFactor,
            exportOptions: exportOptions)
        do {
            try ProjectIO.save(result: r, settings: settings, to: url)
            projectURL = url
            isDirty = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            showError("Could not save project", error)
        }
    }

    private func apply(_ project: LoadedProject, from url: URL) {
        let s = project.settings
        if let path = s.inputFolder, FileManager.default.fileExists(atPath: path) {
            inputFolder = URL(fileURLWithPath: path, isDirectory: true)
            imageStats = ImageStats.scan(inputFolder!)
        } else {
            inputFolder = nil
            imageStats = ImageStats()
        }
        detail = DetailLevel(rawValue: s.detail) ?? .medium
        objectMasking = s.objectMasking
        sequentialOrdering = s.sequentialOrdering
        highSensitivity = s.highSensitivity
        exportOptions = s.exportOptions
        result = project.result
        scaleFactor = s.scaleFactor
        phase = .finished
        progress = 1
        stageText = "Done."
        remainingText = ""
        log = []
        exportMessage = nil
        projectURL = url
        isDirty = false
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func fail(_ message: String) {
        guard phase == .running else { return }
        session?.cancel()
        session = nil
        phase = .failed(message)
        stageText = ""
        remainingText = ""
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    private static func stageName(_ stage: Any) -> String {
        let key = String(describing: stage)
        let names = [
            "preProcessing": "Preprocessing",
            "imageAlignment": "Aligning images",
            "pointCloudGeneration": "Generating point cloud",
            "meshGeneration": "Generating mesh",
            "textureMapping": "Creating textures",
            "optimization": "Optimizing"
        ]
        return names[key] ?? "Reconstructing…"
    }

    private static func format(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_US")
        f.calendar = calendar
        return f.string(from: t) ?? ""
    }
}
