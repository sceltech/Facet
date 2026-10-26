import Foundation
import simd

enum ExportUnit: String, CaseIterable, Identifiable, Codable {
    case mm, cm, m
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mm: "Millimeters"
        case .cm: "Centimeters"
        case .m: "Meters"
        }
    }
    /// Conversion factor from meters to this unit
    var factor: Float {
        switch self {
        case .mm: 1000
        case .cm: 100
        case .m: 1
        }
    }
}

struct ExportOptions: Codable {
    var name = "Model"
    var stl = true
    var obj = true
    var fbx = false
    var ply = false
    var usdz = false
    var unit: ExportUnit = .mm

    var anySelected: Bool { stl || obj || fbx || ply || usdz }
}

enum MeshExporter {

    // MARK: - Export pipeline

    static func run(result: ReconstructionResult,
                    options: ExportOptions,
                    calibration: Float,
                    folder: URL) -> (written: [String], errors: [String]) {
        var written: [String] = []
        var errors: [String] = []
        let fm = FileManager.default
        let name = sanitize(options.name)
        let factor = calibration * options.unit.factor

        if options.stl {
            let url = unique(folder.appendingPathComponent("\(name).stl"))
            do {
                try writeSTL(result.mesh, scale: factor, to: url)
                written.append(url.lastPathComponent)
            } catch { errors.append("STL: \(error.localizedDescription)") }
        }

        if options.obj {
            let dir = unique(folder.appendingPathComponent("\(name) OBJ", isDirectory: true))
            do {
                _ = try writeOBJFolder(source: result.objFolder, objFile: result.objURL,
                                       factor: factor, name: name, to: dir)
                written.append(dir.lastPathComponent + "/")
            } catch { errors.append("OBJ: \(error.localizedDescription)") }
        }

        if options.ply {
            let url = unique(folder.appendingPathComponent("\(name).ply"))
            do {
                try writePLY(result.mesh, scale: factor, to: url)
                written.append(url.lastPathComponent)
            } catch { errors.append("PLY: \(error.localizedDescription)") }
        }

        if options.usdz {
            let url = unique(folder.appendingPathComponent("\(name).usdz"))
            do {
                try fm.copyItem(at: result.usdzURL, to: url)
                written.append(url.lastPathComponent)
            } catch { errors.append("USDZ: \(error.localizedDescription)") }
        }

        if options.fbx {
            if let blender = blenderURL() {
                let tmp = fm.temporaryDirectory
                    .appendingPathComponent("Facet-FBX-\(UUID().uuidString)", isDirectory: true)
                do {
                    // FBX carries its own unit info, so pass the OBJ in meters.
                    let obj = try writeOBJFolder(source: result.objFolder, objFile: result.objURL,
                                                 factor: calibration, name: name, to: tmp)
                    let fbx = unique(folder.appendingPathComponent("\(name).fbx"))
                    try exportFBX(objFile: obj, to: fbx, blender: blender)
                    written.append(fbx.lastPathComponent)
                } catch { errors.append("FBX: \(error.localizedDescription)") }
                try? fm.removeItem(at: tmp)
            } else {
                errors.append("FBX: Blender not found (expected in /Applications).")
            }
        }

        return (written, errors)
    }

    // MARK: - STL (binary)

    static func writeSTL(_ mesh: TriMesh, scale: Float, to url: URL) throws {
        var data = Data(capacity: 84 + mesh.triangleCount * 50)
        var header = [UInt8](repeating: 0x20, count: 80)
        let title = Array("Facet STL".utf8)
        header.replaceSubrange(0..<title.count, with: title)
        data.append(contentsOf: header)
        appendInt(&data, UInt32(mesh.triangleCount))

        for t in 0..<mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[3 * t])] * scale
            let b = mesh.positions[Int(mesh.indices[3 * t + 1])] * scale
            let c = mesh.positions[Int(mesh.indices[3 * t + 2])] * scale
            var n = cross(b - a, c - a)
            let len = length(n)
            n = len > 0 ? n / len : .zero
            appendVec(&data, n)
            appendVec(&data, a)
            appendVec(&data, b)
            appendVec(&data, c)
            appendInt(&data, UInt16(0))
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - PLY (binary)

    static func writePLY(_ mesh: TriMesh, scale: Float, to url: URL) throws {
        let header = """
        ply
        format binary_little_endian 1.0
        comment Created with Facet
        element vertex \(mesh.positions.count)
        property float x
        property float y
        property float z
        element face \(mesh.triangleCount)
        property list uchar int vertex_indices
        end_header

        """
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + mesh.positions.count * 12 + mesh.triangleCount * 13)
        for p in mesh.positions { appendVec(&data, p * scale) }
        for t in 0..<mesh.triangleCount {
            data.append(UInt8(3))
            for k in 0..<3 {
                appendInt(&data, Int32(bitPattern: mesh.indices[3 * t + k]))
            }
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - OBJ with textures

    /// Copies material and textures and writes the scaled OBJ under a new name.
    @discardableResult
    static func writeOBJFolder(source: URL, objFile: URL, factor: Float,
                               name: String, to dest: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for item in items where item.lastPathComponent != objFile.lastPathComponent {
            try fm.copyItem(at: item, to: dest.appendingPathComponent(item.lastPathComponent))
        }

        let target = dest.appendingPathComponent("\(name).obj")
        if factor == 1 {
            try fm.copyItem(at: objFile, to: target)
            return target
        }

        let text = try String(contentsOf: objFile, encoding: .utf8)
        var out = String()
        out.reserveCapacity(text.utf8.count + text.utf8.count / 4)
        text.enumerateLines { line, _ in
            if line.hasPrefix("v ") {
                let p = line.split(separator: " ", omittingEmptySubsequences: true)
                if p.count >= 4, let x = Float(p[1]), let y = Float(p[2]), let z = Float(p[3]) {
                    out += "v \(x * factor) \(y * factor) \(z * factor)"
                    if p.count > 4 { out += " " + p[4...].joined(separator: " ") }
                    out += "\n"
                    return
                }
            }
            out += line
            out += "\n"
        }
        try out.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    // MARK: - FBX via Blender

    static func blenderURL() -> URL? {
        let candidates = [
            "/Applications/Blender.app/Contents/MacOS/Blender",
            NSHomeDirectory() + "/Applications/Blender.app/Contents/MacOS/Blender"
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func exportFBX(objFile: URL, to fbx: URL, blender: URL) throws {
        let script = """
        import bpy, sys
        argv = sys.argv[sys.argv.index("--") + 1:]
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.wm.obj_import(filepath=argv[0])
        bpy.ops.export_scene.fbx(filepath=argv[1], path_mode='COPY', embed_textures=True)
        """
        let process = Process()
        process.executableURL = blender
        process.arguments = ["-b", "--factory-startup", "--python-exit-code", "1",
                             "--python-expr", script, "--", objFile.path, fbx.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: fbx.path) else {
            let tail = String(decoding: output.suffix(1500), as: UTF8.self)
            throw ExportError.blender(tail)
        }
    }

    // MARK: - Helpers

    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Model" : cleaned
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    private static func appendInt<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendVec(_ data: inout Data, _ v: SIMD3<Float>) {
        appendInt(&data, v.x.bitPattern)
        appendInt(&data, v.y.bitPattern)
        appendInt(&data, v.z.bitPattern)
    }
}
