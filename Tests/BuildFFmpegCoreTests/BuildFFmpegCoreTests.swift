import Foundation
import Testing
@testable import BuildFFmpegCore

@Test
func localCommandIncludesExpectedFlags() {
    let configuration = CommandConfiguration(
        releaseTag: "ffmpeg-n8.1",
        licenseMode: .gpl,
        enableAvdevice: true,
        avdevicePlatforms: [.ios, .macos]
    )

    #expect(configuration.localCommand.contains("--license gpl"))
    #expect(configuration.localCommand.contains("--enable-libass"))
    #expect(configuration.localCommand.contains("--enable-drawtext"))
    #expect(configuration.localCommand.contains("--enable-avdevice"))
    #expect(configuration.localCommand.contains("--avdevice-platforms ios,macos"))
}

@Test
func ghWorkflowCommandEscapesEmptyReleaseTag() {
    let configuration = CommandConfiguration(releaseTag: "")
    #expect(configuration.ghWorkflowCommand.contains("--field release_tag=''"))
    #expect(configuration.ghWorkflowCommand.contains("--field license_mode='lgpl'"))
}

@Test
func presetStoreSavesLoadsAndDeletesPreset() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = PresetStore(rootDirectory: root)
    let configuration = CommandConfiguration(ffmpegRef: "custom")

    try store.save(name: "test", configuration: configuration)
    let listed = try store.list()
    #expect(listed.count == 1)
    #expect(listed.first?.configuration.ffmpegRef == "custom")

    try store.delete(name: "test")
    #expect(try store.list().isEmpty)
}

@Test
func recentConfigurationRoundTrips() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = PresetStore(rootDirectory: root)
    let configuration = CommandConfiguration(ffmpegRef: "roundtrip", minimumTVOS: "17.0")

    try store.saveRecent(configuration)
    let loaded = try store.loadRecent()

    #expect(loaded == configuration)
}

@Test
func importedPresetIsPersisted() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = PresetStore(rootDirectory: root)

    let importDirectory = root.appendingPathComponent("import", isDirectory: true)
    try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)
    let sourceURL = importDirectory.appendingPathComponent("incoming.json")
    let preset = PresetFile(
        name: "imported",
        configuration: CommandConfiguration(enableAvdevice: false)
    )
    let data = try JSONEncoder().encode(preset)
    try data.write(to: sourceURL)

    let imported = try store.importPreset(from: sourceURL)
    let listed = try store.list()

    #expect(imported.name == "imported")
    #expect(listed.count == 1)
    #expect(listed.first?.configuration.enableAvdevice == false)
}
