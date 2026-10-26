import SwiftUI
import AppKit
import SceneKit

struct ContentView: View {
    @EnvironmentObject var model: ReconstructionModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 340)
            Divider()
            MainArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.projectURL?.deletingPathExtension().lastPathComponent ?? "Facet")
        .navigationSubtitle(model.isDirty ? "Edited" : "")
        .dropDestination(for: URL.self) { urls, _ in
            guard model.phase != .running, let url = urls.first else { return false }
            if url.pathExtension.lowercased() == "facet" {
                model.openProject(at: url)
                return true
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return false }
            model.setFolder(url)
            return true
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: ReconstructionModel

    var body: some View {
        Form {
            Section("Photos") {
                Button("Choose Folder…", action: chooseFolder)
                    .disabled(model.phase == .running)
                if let folder = model.inputFolder {
                    Text(folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(model.imageStats.summary)
                    if model.imageStats.total < 20 {
                        Label("At least 20 images recommended", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Reconstruction") {
                Picker("Detail Level", selection: $model.detail) {
                    ForEach(DetailLevel.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Isolate Object", isOn: $model.objectMasking)
                    .help("Ignores the background. Required if the object was flipped to capture top and bottom.")
                Toggle("Photos in Capture Order", isOn: $model.sequentialOrdering)
                    .help("Faster if the photos were taken in sequence while circling the object.")
                Toggle("High Sensitivity", isOn: $model.highSensitivity)
                    .help("For low-texture surfaces such as smooth, single-color plastics.")
            }
            .disabled(model.phase == .running)

            Section {
                if model.phase == .running {
                    Button("Cancel", role: .destructive) { model.cancel() }
                } else {
                    Button("Create 3D Model") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.inputFolder == nil || model.imageStats.total == 0 || !model.isSupported)
                }
                if !model.isSupported {
                    Text("Object Capture is not supported on this Mac.")
                        .foregroundStyle(.red)
                }
            }

            if model.result != nil {
                ScaleSection()
                ExportSection()
                ProjectSection()
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder containing your photos (HEIC, JPG or PNG)"
        if panel.runModal() == .OK, let url = panel.url {
            model.setFolder(url)
        }
    }
}

// MARK: - Scale

struct ScaleSection: View {
    @EnvironmentObject var model: ReconstructionModel
    @State private var axis = 0
    @State private var realMM: Double = 0

    var body: some View {
        Section("Scale") {
            if let r = model.result {
                let s = r.mesh.size * Float(model.scaleFactor) * 1000
                LabeledContent("Width (X)", value: Self.mm(s.x))
                LabeledContent("Height (Y)", value: Self.mm(s.y))
                LabeledContent("Depth (Z)", value: Self.mm(s.z))
                if model.scaleFactor != 1 {
                    LabeledContent("Factor", value: String(format: "%.4f", model.scaleFactor))
                }
                Picker("Known Dimension", selection: $axis) {
                    Text("Width (X)").tag(0)
                    Text("Height (Y)").tag(1)
                    Text("Depth (Z)").tag(2)
                }
                TextField("Real dimension in mm", value: $realMM, format: .number)
                HStack {
                    Button("Apply") { model.calibrate(axis: axis, realMillimeters: realMM) }
                        .disabled(realMM <= 0)
                    Button("Reset") { model.scaleFactor = 1 }
                        .disabled(model.scaleFactor == 1)
                }
                Text("Without depth data in the photos, the scale is only estimated. Measure an outer edge of the real object and enter it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func mm(_ v: Float) -> String { String(format: "%.1f mm", v) }
}

// MARK: - Export

struct ExportSection: View {
    @EnvironmentObject var model: ReconstructionModel

    var body: some View {
        Section("Export") {
            TextField("File Name", text: $model.exportOptions.name)
            Toggle("STL (3D printing)", isOn: $model.exportOptions.stl)
            Toggle("OBJ with textures", isOn: $model.exportOptions.obj)
            Toggle("FBX with textures", isOn: $model.exportOptions.fbx)
                .disabled(model.blenderURL == nil)
            if model.blenderURL == nil {
                Text("FBX export requires Blender in the Applications folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("PLY", isOn: $model.exportOptions.ply)
            Toggle("USDZ (original scale, AR Quick Look)", isOn: $model.exportOptions.usdz)
            Picker("Unit (STL, OBJ, PLY)", selection: $model.exportOptions.unit) {
                ForEach(ExportUnit.allCases) { Text($0.label).tag($0) }
            }
            Button(model.isExporting ? "Exporting…" : "Export…", action: chooseTarget)
                .buttonStyle(.borderedProminent)
                .disabled(model.isExporting || !model.exportOptions.anySelected)
            if model.isExporting {
                ProgressView().controlSize(.small)
            }
            if let msg = model.exportMessage {
                Text(msg).font(.caption).textSelection(.enabled)
                if let folder = model.lastExportFolder {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
            }
        }
    }

    private func chooseTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a destination folder for the export"
        if panel.runModal() == .OK, let url = panel.url {
            model.export(to: url)
        }
    }
}

// MARK: - Project

struct ProjectSection: View {
    @EnvironmentObject var model: ReconstructionModel

    var body: some View {
        Section("Project") {
            if let url = model.projectURL {
                LabeledContent("File", value: url.lastPathComponent)
            }
            HStack {
                Button("Save Project") { model.save() }
                if model.projectURL != nil {
                    Button("Save As…") { model.saveAs() }
                }
            }
            Text(model.isDirty
                 ? "Unsaved changes. Save to reopen this model later without recomputing."
                 : "All changes saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Main area

struct MainArea: View {
    @EnvironmentObject var model: ReconstructionModel

    var body: some View {
        if let r = model.result {
            ZStack(alignment: .bottomLeading) {
                ModelPreview(url: r.usdzURL)
                Text("\(r.mesh.triangleCount.formatted()) triangles · \(r.mesh.positions.count.formatted()) vertices")
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(12)
            }
        } else if model.phase == .idle {
            DropHint()
        } else {
            ProgressPanel()
        }
    }
}

struct DropHint: View {
    @EnvironmentObject var model: ReconstructionModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            if model.inputFolder != nil {
                Text("Ready: \(model.imageStats.summary)").font(.title3)
                Text("Check the settings and click “Create 3D Model”.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Drop a folder of photos here").font(.title3)
                Text("HEIC, JPG or PNG · 20 images or more").foregroundStyle(.secondary)
                Button("Open Project…") { model.openProjectPanel() }
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(.tertiary)
                .padding(24)
        )
    }
}

struct ProgressPanel: View {
    @EnvironmentObject var model: ReconstructionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.failureMessage {
                Label(error, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if model.phase == .cancelled {
                Label("Cancelled.", systemImage: "stop.circle")
            } else {
                Text(model.stageText).font(.headline)
                ProgressView(value: model.progress)
                HStack {
                    Text("\(Int(model.progress * 100)) %")
                    Spacer()
                    Text(model.remainingText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !model.log.isEmpty {
                Text("Log").font(.subheadline).padding(.top, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { entry in
                            Text(entry.element).font(.caption.monospaced())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer()
        }
        .padding(24)
    }
}

struct ModelPreview: View {
    let url: URL
    @State private var scene: SCNScene?

    var body: some View {
        Group {
            if let scene {
                SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
            } else {
                ProgressView("Loading preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            scene = try? SCNScene(url: url, options: nil)
        }
    }
}
