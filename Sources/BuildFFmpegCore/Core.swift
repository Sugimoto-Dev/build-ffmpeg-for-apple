import Foundation

public enum LicenseMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case lgpl
    case gpl

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lgpl: "LGPL"
        case .gpl: "GPL"
        }
    }
}

public enum BuildPlatform: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case ios
    case iossimulator
    case macos
    case tvos
    case tvossimulator

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ios: "iOS"
        case .iossimulator: "iOS Simulator"
        case .macos: "macOS"
        case .tvos: "tvOS"
        case .tvossimulator: "tvOS Simulator"
        }
    }
}

public struct CommandConfiguration: Codable, Equatable, Sendable {
    public var ffmpegRef: String
    public var libassRef: String
    public var releaseTag: String
    public var minimumIOS: String
    public var minimumMacOS: String
    public var minimumTVOS: String
    public var licenseMode: LicenseMode
    public var enableLibass: Bool
    public var enableDrawtext: Bool
    public var enableAvdevice: Bool
    public var platforms: [BuildPlatform]
    public var avdevicePlatforms: [BuildPlatform]

    public init(
        ffmpegRef: String = "n8.1",
        libassRef: String = "0.17.4",
        releaseTag: String = "",
        minimumIOS: String = "14.0",
        minimumMacOS: String = "11.0",
        minimumTVOS: String = "14.0",
        licenseMode: LicenseMode = .lgpl,
        enableLibass: Bool = true,
        enableDrawtext: Bool = true,
        enableAvdevice: Bool = true,
        platforms: [BuildPlatform] = BuildPlatform.allCases,
        avdevicePlatforms: [BuildPlatform] = [.ios, .iossimulator, .macos]
    ) {
        self.ffmpegRef = ffmpegRef
        self.libassRef = libassRef
        self.releaseTag = releaseTag
        self.minimumIOS = minimumIOS
        self.minimumMacOS = minimumMacOS
        self.minimumTVOS = minimumTVOS
        self.licenseMode = licenseMode
        self.enableLibass = enableLibass
        self.enableDrawtext = enableDrawtext
        self.enableAvdevice = enableAvdevice
        self.platforms = platforms
        self.avdevicePlatforms = avdevicePlatforms
    }

    public var workflowName: String { "build-ffmpeg.yml" }

    public var workflowFieldArguments: [(String, String)] {
        [
            ("ffmpeg_ref", ffmpegRef),
            ("libass_ref", libassRef),
            ("license_mode", licenseMode.rawValue),
            ("release_tag", releaseTag),
        ]
    }

    public var workflowInputs: String {
        workflowFieldArguments
            .map { "\($0.0): \($0.1.isEmpty ? "(empty)" : $0.1)" }
            .joined(separator: "\n")
    }

    public var localCommand: String {
        var parts = [
            "xcrun swift build_ffmpeg_xcframework.swift",
            "--source /path/to/FFmpeg",
            "--output /path/to/out",
            "--work /path/to/work",
            "--platforms \(platforms.map { $0.rawValue }.joined(separator: ","))",
            "--min-ios \(minimumIOS)",
            "--min-macos \(minimumMacOS)",
            "--min-tvos \(minimumTVOS)",
            "--license \(licenseMode.rawValue)",
        ]

        if enableLibass {
            parts.append("--enable-libass")
            if enableDrawtext {
                parts.append("--enable-drawtext")
            }
            parts.append(#"--dependency-prefix-template "libass=$DEPS_DIR/libass/{platform}/thin/{arch}""#)
            parts.append(#"--dependency-prefix-template "freetype=$DEPS_DIR/libfreetype/{platform}/thin/{arch}""#)
            parts.append(#"--dependency-prefix-template "harfbuzz=$DEPS_DIR/libharfbuzz/{platform}/thin/{arch}""#)
            parts.append(#"--dependency-prefix-template "fribidi=$DEPS_DIR/libfribidi/{platform}/thin/{arch}""#)
            parts.append(#"--dependency-prefix-template "unibreak=$DEPS_DIR/libunibreak/{platform}/thin/{arch}""#)
        }

        if enableAvdevice {
            parts.append("--enable-avdevice")
            parts.append("--avdevice-platforms \(avdevicePlatforms.map { $0.rawValue }.joined(separator: ","))")
        }

        parts.append("--zip")
        parts.append("--verbose")
        return parts.joined(separator: " \\\n  ")
    }

    public var ghWorkflowCommand: String {
        var parts = [
            "gh workflow run \(workflowName)",
            "--ref main",
        ]
        parts.append(contentsOf: workflowFieldArguments.map { "--field \($0.0)=\(shellEscape($0.1))" })
        return parts.joined(separator: " ")
    }
}

public struct PresetFile: Codable, Equatable, Sendable {
    public var name: String
    public var configuration: CommandConfiguration

    public init(name: String, configuration: CommandConfiguration) {
        self.name = name
        self.configuration = configuration
    }
}

public enum WorkflowRunResult: Equatable, Sendable {
    case success(String)
    case failure(String)
}

public protocol WorkflowRunning: Sendable {
    func run(configuration: CommandConfiguration) async -> WorkflowRunResult
}

public struct GHWorkflowRunner: WorkflowRunning {
    public init() {}

    public func run(configuration: CommandConfiguration) async -> WorkflowRunResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ghArguments(configuration: configuration)

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                let combined = String(data: outputData + errorData, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume(returning: .success(combined))
                } else {
                    continuation.resume(returning: .failure(combined))
                }
            } catch {
                continuation.resume(returning: .failure(error.localizedDescription))
            }
        }
    }

    private func ghArguments(configuration: CommandConfiguration) -> [String] {
        var arguments = ["gh", "workflow", "run", configuration.workflowName, "--ref", "main"]
        arguments.append(contentsOf: configuration.workflowFieldArguments.flatMap { ["--field", "\($0.0)=\($0.1)"] })
        return arguments
    }
}

public final class PresetStore: @unchecked Sendable {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let appSupport = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            self.rootDirectory = (appSupport ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
                .appendingPathComponent("BuildFFmpegCommandBuilder", isDirectory: true)
                .appendingPathComponent("Presets", isDirectory: true)
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func list() throws -> [PresetFile] {
        try ensureDirectory()
        let urls = try fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "recent.json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try urls.map { try decodePreset(at: $0) }
    }

    public func save(name: String, configuration: CommandConfiguration) throws {
        try ensureDirectory()
        let preset = PresetFile(name: name, configuration: configuration)
        try writePreset(preset, to: presetURL(name: name))
    }

    public func delete(name: String) throws {
        let url = presetURL(name: name)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func saveRecent(_ configuration: CommandConfiguration) throws {
        try ensureDirectory()
        let preset = PresetFile(name: "recent", configuration: configuration)
        try writePreset(preset, to: recentURL)
    }

    public func loadRecent() throws -> CommandConfiguration? {
        guard fileManager.fileExists(atPath: recentURL.path) else { return nil }
        return try decodePreset(at: recentURL).configuration
    }

    public func exportPreset(named name: String, to destination: URL) throws {
        let preset = try decodePreset(at: presetURL(name: name))
        try writePreset(preset, to: destination)
    }

    @discardableResult
    public func importPreset(from source: URL) throws -> PresetFile {
        let preset = try decodePreset(at: source)
        try save(name: preset.name, configuration: preset.configuration)
        return preset
    }

    private var recentURL: URL {
        rootDirectory.appendingPathComponent("recent.json")
    }

    private func presetURL(name: String) -> URL {
        rootDirectory.appendingPathComponent("\(sanitize(name)).json")
    }

    private func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalarView = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(scalarView)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    private func decodePreset(at url: URL) throws -> PresetFile {
        let data = try Data(contentsOf: url)
        return try decoder.decode(PresetFile.self, from: data)
    }

    private func writePreset(_ preset: PresetFile, to url: URL) throws {
        let data = try encoder.encode(preset)
        try data.write(to: url, options: .atomic)
    }
}

private func shellEscape(_ value: String) -> String {
    if value.isEmpty { return "''" }
    return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}
