import AppKit
import BuildFFmpegCore
import SwiftUI
import UniformTypeIdentifiers

struct PresetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var preset: PresetFile

    init(preset: PresetFile) {
        self.preset = preset
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        preset = try JSONDecoder().decode(PresetFile.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder().encode(preset)
        return .init(regularFileWithContents: data)
    }
}

@MainActor
final class CommandBuilderModel: ObservableObject {
    @Published var configuration: CommandConfiguration {
        didSet { configurationDidChange() }
    }
    @Published var presetName = ""
    @Published var savedPresets: [PresetFile] = []
    @Published var selectedPresetName = ""
    @Published var workflowStatus = ""
    @Published var workflowLog = ""
    @Published var isRunningWorkflow = false
    @Published var exportDocument: PresetDocument?
    @Published var isExporting = false
    @Published var isImporting = false

    private let presetStore: PresetStore
    private let workflowRunner: WorkflowRunning

    init(
        presetStore: PresetStore = PresetStore(),
        workflowRunner: WorkflowRunning = GHWorkflowRunner()
    ) {
        self.presetStore = presetStore
        self.workflowRunner = workflowRunner
        self.configuration = (try? presetStore.loadRecent()) ?? CommandConfiguration()
        reloadPresets()
    }

    var localCommand: String { configuration.localCommand }
    var workflowInputs: String { configuration.workflowInputs }
    var ghWorkflowCommand: String { configuration.ghWorkflowCommand }

    func reloadPresets() {
        savedPresets = (try? presetStore.list()) ?? []
        if selectedPresetName.isEmpty {
            selectedPresetName = savedPresets.first?.name ?? ""
        }
    }

    func savePreset() {
        let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try presetStore.save(name: trimmed, configuration: configuration)
            presetName = trimmed
            reloadPresets()
            selectedPresetName = trimmed
        } catch {
            workflowStatus = "Save preset failed"
            workflowLog = error.localizedDescription
        }
    }

    func loadSelectedPreset() {
        guard let preset = savedPresets.first(where: { $0.name == selectedPresetName }) else { return }
        configuration = preset.configuration
        presetName = preset.name
    }

    func deleteSelectedPreset() {
        guard !selectedPresetName.isEmpty else { return }
        do {
            try presetStore.delete(name: selectedPresetName)
            reloadPresets()
            selectedPresetName = savedPresets.first?.name ?? ""
        } catch {
            workflowStatus = "Delete preset failed"
            workflowLog = error.localizedDescription
        }
    }

    func prepareExport() {
        let name = selectedPresetName.isEmpty ? presetName : selectedPresetName
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        exportDocument = PresetDocument(preset: .init(name: trimmed, configuration: configuration))
        isExporting = true
    }

    func importPreset(from url: URL) {
        do {
            let preset = try presetStore.importPreset(from: url)
            reloadPresets()
            selectedPresetName = preset.name
            presetName = preset.name
            configuration = preset.configuration
        } catch {
            workflowStatus = "Import preset failed"
            workflowLog = error.localizedDescription
        }
    }

    func runWorkflow() {
        guard !isRunningWorkflow else { return }
        isRunningWorkflow = true
        workflowStatus = "Running workflow..."
        workflowLog = ""

        Task {
            let result = await workflowRunner.run(configuration: configuration)
            await MainActor.run {
                isRunningWorkflow = false
                switch result {
                case .success(let output):
                    workflowStatus = "Workflow triggered"
                    workflowLog = output
                case .failure(let output):
                    workflowStatus = "Workflow trigger failed"
                    workflowLog = output
                }
            }
        }
    }

    private func configurationDidChange() {
        try? presetStore.saveRecent(configuration)
    }
}

struct ContentView: View {
    @StateObject private var model = CommandBuilderModel()
    @State private var importedDocument: PresetDocument?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                presetSection
                versionsSection
                featureSection
                platformSection
                avdeviceSection
                outputSection(title: "Local Build Command", content: model.localCommand)
                outputSection(title: "GitHub Actions Inputs", content: model.workflowInputs)
                outputSection(title: "gh workflow run", content: model.ghWorkflowCommand)
                workflowRunSection
            }
            .padding(20)
        }
        .frame(minWidth: 980, minHeight: 860)
        .fileExporter(
            isPresented: $model.isExporting,
            document: model.exportDocument,
            contentType: .json,
            defaultFilename: model.selectedPresetName.isEmpty ? "ffmpeg-preset" : model.selectedPresetName
        ) { _ in }
        .fileImporter(
            isPresented: $model.isImporting,
            allowedContentTypes: [.json]
        ) { result in
            if case .success(let url) = result {
                model.importPreset(from: url)
            }
        }
    }

    private var presetSection: some View {
        GroupBox("Preset") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Preset Name", text: $model.presetName)
                    Picker("Saved Presets", selection: $model.selectedPresetName) {
                        Text("None").tag("")
                        ForEach(model.savedPresets, id: \.name) { preset in
                            Text(preset.name).tag(preset.name)
                        }
                    }
                }
                HStack {
                    Button("Save") { model.savePreset() }
                    Button("Load") { model.loadSelectedPreset() }
                    Button("Delete") { model.deleteSelectedPreset() }
                    Button("Import") { model.isImporting = true }
                    Button("Export") { model.prepareExport() }
                }
            }
        }
    }

    private var versionsSection: some View {
        GroupBox("Versions") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    labeledField("FFmpeg Ref", text: $model.configuration.ffmpegRef)
                    labeledField("libass Ref", text: $model.configuration.libassRef)
                    labeledField("Release Tag", text: $model.configuration.releaseTag)
                }
                HStack {
                    labeledField("Min iOS", text: $model.configuration.minimumIOS)
                    labeledField("Min macOS", text: $model.configuration.minimumMacOS)
                    labeledField("Min tvOS", text: $model.configuration.minimumTVOS)
                    VStack(alignment: .leading) {
                        Text("License")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("License", selection: $model.configuration.licenseMode) {
                            ForEach(LicenseMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(minWidth: 180)
                    }
                }
            }
        }
    }

    private var featureSection: some View {
        GroupBox("Features") {
            HStack {
                Toggle("Enable libass", isOn: $model.configuration.enableLibass)
                Toggle("Enable drawtext", isOn: $model.configuration.enableDrawtext)
                Toggle("Enable avdevice", isOn: $model.configuration.enableAvdevice)
            }
        }
    }

    private var platformSection: some View {
        GroupBox("Build Platforms") {
            platformToggles(
                selected: Binding(
                    get: { Set(model.configuration.platforms) },
                    set: { newValue in
                        model.configuration.platforms = BuildPlatform.allCases.filter { newValue.contains($0) }
                    }
                )
            )
        }
    }

    private var avdeviceSection: some View {
        GroupBox("avdevice Platforms") {
            platformToggles(
                selected: Binding(
                    get: { Set(model.configuration.avdevicePlatforms) },
                    set: { newValue in
                        model.configuration.avdevicePlatforms = BuildPlatform.allCases.filter { newValue.contains($0) }
                    }
                )
            )
        }
    }

    private func platformToggles(selected: Binding<Set<BuildPlatform>>) -> some View {
        HStack {
            ForEach(BuildPlatform.allCases) { platform in
                Toggle(
                    platform.displayName,
                    isOn: Binding(
                        get: { selected.wrappedValue.contains(platform) },
                        set: { isSelected in
                            var value = selected.wrappedValue
                            if isSelected {
                                value.insert(platform)
                            } else {
                                value.remove(platform)
                            }
                            selected.wrappedValue = value
                        }
                    )
                )
            }
        }
    }

    private func labeledField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)
        }
    }

    private func outputSection(title: String, content: String) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal) {
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Copy") {
                    copyToPasteboard(content)
                }
            }
        }
    }

    private var workflowRunSection: some View {
        GroupBox("Workflow Run") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(model.isRunningWorkflow ? "Running..." : "Run Workflow via gh") {
                        model.runWorkflow()
                    }
                    .disabled(model.isRunningWorkflow)
                    Text(model.workflowStatus)
                        .foregroundStyle(.secondary)
                }

                if !model.workflowLog.isEmpty {
                    ScrollView {
                        Text(model.workflowLog)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 140)
                }
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@main
struct BuildFFmpegCommandBuilderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
