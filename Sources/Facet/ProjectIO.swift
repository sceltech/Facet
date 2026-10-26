import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// A .facet project: a package folder with the model, textures and settings.
    static let facetProject = UTType(exportedAs: "local.facet.project", conformingTo: .package)
}

struct ProjectSettings: Codable {
    var version = 1
    var inputFolder: String?
    var detail: String
    var objectMasking: Bool
    var sequentialOrdering: Bool
    var highSensitivity: Bool
    var scaleFactor: Double
    var exportOptions: ExportOptions
}

struct LoadedProject {
    let settings: ProjectSettings
    let result: ReconstructionResult
}

enum ProjectError: LocalizedError {
    case invalid
    var errorDescription: String? { "This is not a valid Facet project." }
}

/// Package layout:
///   Name.facet/
///     project.json   settings, scale, export options, photo folder
///     model.usdz     textured model for the preview
///     obj/           OBJ + material + textures (basis for all exports)
enum ProjectIO {
    static func save(result: ReconstructionResult, settings: ProjectSettings, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".facet-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: result.usdzURL, to: tmp.appendingPathComponent("model.usdz"))
            try fm.copyItem(at: result.objFolder, to: tmp.appendingPathComponent("obj", isDirectory: true))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: tmp.appendingPathComponent("project.json"))
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Copies the project into a fresh working folder, so the .facet file can be
    /// moved or overwritten while it is open.
    static func load(from url: URL, into work: URL) throws -> LoadedProject {
        let fm = FileManager.default
        let json = url.appendingPathComponent("project.json")
        guard fm.fileExists(atPath: json.path) else { throw ProjectError.invalid }
        let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data(contentsOf: json))

        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let usdz = work.appendingPathComponent("model.usdz")
        let objDir = work.appendingPathComponent("obj", isDirectory: true)
        try fm.copyItem(at: url.appendingPathComponent("model.usdz"), to: usdz)
        try fm.copyItem(at: url.appendingPathComponent("obj", isDirectory: true), to: objDir)

        guard let obj = MeshIO.findOBJ(in: objDir) else { throw ProjectError.invalid }
        let mesh = try MeshIO.loadOBJ(obj)
        return LoadedProject(settings: settings,
                             result: ReconstructionResult(usdzURL: usdz, objURL: obj, objFolder: objDir, mesh: mesh))
    }
}
