import Foundation
import simd

/// Plain triangle mesh (positions in meters, as delivered by Object Capture).
struct TriMesh {
    let positions: [SIMD3<Float>]
    let indices: [UInt32]
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>

    init(positions: [SIMD3<Float>], indices: [UInt32]) {
        self.positions = positions
        self.indices = indices
        if positions.isEmpty {
            boundsMin = .zero
            boundsMax = .zero
        } else {
            var lo = positions[0]
            var hi = positions[0]
            for p in positions {
                lo = pointwiseMin(lo, p)
                hi = pointwiseMax(hi, p)
            }
            boundsMin = lo
            boundsMax = hi
        }
    }

    var triangleCount: Int { indices.count / 3 }
    var size: SIMD3<Float> { boundsMax - boundsMin }
}

enum ExportError: LocalizedError {
    case noMesh
    case blender(String)

    var errorDescription: String? {
        switch self {
        case .noMesh:
            return "No mesh was found."
        case .blender(let log):
            return "Blender conversion failed.\n\(log)"
        }
    }
}

enum MeshIO {
    static func findOBJ(in folder: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension.lowercased() == "obj" }
    }

    /// Reads geometry (v / f) from an OBJ file; polygons are triangulated.
    static func loadOBJ(_ url: URL) throws -> TriMesh {
        let text = try String(contentsOf: url, encoding: .utf8)
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        text.enumerateLines { line, _ in
            if line.hasPrefix("v ") {
                let p = line.split(separator: " ", omittingEmptySubsequences: true)
                if p.count >= 4, let x = Float(p[1]), let y = Float(p[2]), let z = Float(p[3]) {
                    positions.append(SIMD3<Float>(x, y, z))
                }
            } else if line.hasPrefix("f ") {
                var face: [UInt32] = []
                for token in line.split(separator: " ", omittingEmptySubsequences: true).dropFirst() {
                    let first = token.split(separator: "/", omittingEmptySubsequences: false).first ?? ""
                    guard var i = Int(first) else { continue }
                    i = i < 0 ? positions.count + i : i - 1
                    guard i >= 0 else { continue }
                    face.append(UInt32(i))
                }
                if face.count >= 3 {
                    for k in 1..<(face.count - 1) {
                        indices.append(face[0])
                        indices.append(face[k])
                        indices.append(face[k + 1])
                    }
                }
            }
        }

        // Drop invalid triangles
        let n = UInt32(positions.count)
        var clean: [UInt32] = []
        clean.reserveCapacity(indices.count)
        var t = 0
        while t + 2 < indices.count {
            let a = indices[t], b = indices[t + 1], c = indices[t + 2]
            if a < n && b < n && c < n {
                clean.append(a); clean.append(b); clean.append(c)
            }
            t += 3
        }
        guard !positions.isEmpty, !clean.isEmpty else { throw ExportError.noMesh }
        return TriMesh(positions: positions, indices: clean)
    }
}
