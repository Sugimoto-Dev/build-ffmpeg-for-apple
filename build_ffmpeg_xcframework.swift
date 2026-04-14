#!/usr/bin/env swift

import Foundation

struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum LicenseMode: String, CaseIterable {
    case lgpl
    case gpl
}

enum PlatformID: String, CaseIterable {
    case ios
    case iossimulator
    case macos
    case tvos
    case tvossimulator
}

struct Platform {
    let id: PlatformID
    let sdk: String
    let architectures: [String]
    let minimumVersion: String
    let xcodePlatformName: String
    let libraryIdentifier: String
}

struct Options {
    var source: URL
    var output: URL
    var work: URL
    var platforms: [PlatformID]
    var libraries: [String]
    var minimumVersions: [PlatformID: String]
    var jobs: Int
    var clean: Bool
    var zip: Bool
    var verbose: Bool
    var licenseMode: LicenseMode
    var enableLibass: Bool
    var enableDrawtext: Bool
    var enableAvdevice: Bool
    var avdevicePlatforms: [PlatformID]
    var dependencyPrefixTemplates: [String: String]
    var extraConfigureFlags: [String]
    var extraCFlags: [String]
    var extraLDFlags: [String]
    var pkgConfigPathTemplates: [String]
}

let defaultLibraries = [
    "avcodec",
    "avdevice",
    "avfilter",
    "avformat",
    "avutil",
    "swresample",
    "swscale",
]

let defaultPlatforms: [PlatformID] = [
    .ios,
    .iossimulator,
    .macos,
    .tvos,
    .tvossimulator,
]

let defaultMinimumVersions: [PlatformID: String] = [
    .ios: "14.0",
    .iossimulator: "14.0",
    .macos: "11.0",
    .tvos: "14.0",
    .tvossimulator: "14.0",
]

func printUsage() {
    let usage = """
    Usage:
      swift build_ffmpeg_xcframework.swift --source /path/to/FFmpeg --output /path/to/out

    Optional:
      --work /path/to/workdir
      --platforms ios,iossimulator,macos,tvos,tvossimulator
      --libraries avcodec,avdevice,avfilter,avformat,avutil,swresample,swscale
      --jobs 12
      --clean
      --zip
      --verbose
      --license lgpl|gpl
      --lgpl
      --gpl
      --enable-libass
      --enable-drawtext
      --enable-avdevice
      --avdevice-platforms ios,iossimulator,macos
      --dependency-prefix-template NAME=TEMPLATE
      --extra-configure-flag FLAG
      --extra-cflag FLAG
      --extra-ldflag FLAG
      --pkg-config-path-template TEMPLATE
      --min-ios 14.0
      --min-macos 11.0
      --min-tvos 14.0

    Notes:
      - 默认只构建 FFmpeg 自带库，不自动处理第三方依赖。
      - 默认许可模式是 LGPL；如果需要 GPL 构建，可传 --license gpl
        或 --gpl。GPL 模式会附加 --enable-gpl。
      - 开启 --enable-libass 后，需要额外提供以下依赖前缀模板:
        libass, freetype, harfbuzz, fribidi, unibreak
      - dependency-prefix-template 传的是“安装前缀”模板，脚本会自动使用
        {prefix}/lib/pkgconfig 参与 FFmpeg configure，并在打包时把这些静态库并进
        libavfilter.xcframework。
      - 当前脚本在 --enable-libass 模式下会默认附加
        --disable-filter=drawtext，因为很多精简版 harfbuzz 构建不包含 hb-ft.h。
      - 如果依赖是完整源码构建并且 harfbuzz 提供 hb-ft.h，可以加
        --enable-drawtext 显式保留 drawtext。
      - --enable-avdevice 只会在 --avdevice-platforms 指定的平台启用；
        其它平台会继续禁用 avdevice，避免 tvOS 等平台编译失败。
      - 模板支持变量: {platform} {arch} {sdk}

    Example:
      swift build_ffmpeg_xcframework.swift \
        --source /tmp/FFmpeg \
        --output /tmp/ffmpeg-xcframeworks \
        --work /tmp/ffmpeg-build \
        --license lgpl \
        --enable-libass \
        --dependency-prefix-template 'libass=/opt/deps/libass/{platform}/{arch}' \
        --dependency-prefix-template 'freetype=/opt/deps/libfreetype/{platform}/{arch}' \
        --dependency-prefix-template 'harfbuzz=/opt/deps/libharfbuzz/{platform}/{arch}' \
        --dependency-prefix-template 'fribidi=/opt/deps/libfribidi/{platform}/{arch}' \
        --dependency-prefix-template 'unibreak=/opt/deps/libunibreak/{platform}/{arch}'
    """
    FileHandle.standardError.write(Data(usage.utf8))
}

func parseOptions() throws -> Options {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let arguments = Array(CommandLine.arguments.dropFirst())

    var source: URL?
    var output: URL?
    var work = cwd.appendingPathComponent(".build/ffmpeg-xcframework", isDirectory: true)
    var platforms = defaultPlatforms
    var libraries = defaultLibraries
    var minimumVersions = defaultMinimumVersions
    var jobs = ProcessInfo.processInfo.activeProcessorCount
    var clean = false
    var zip = false
    var verbose = false
    var licenseMode: LicenseMode = .lgpl
    var enableLibass = false
    var enableDrawtext = false
    var enableAvdevice = false
    var avdevicePlatforms: [PlatformID] = [.ios, .iossimulator, .macos]
    var dependencyPrefixTemplates: [String: String] = [:]
    var extraConfigureFlags: [String] = []
    var extraCFlags: [String] = []
    var extraLDFlags: [String] = []
    var pkgConfigPathTemplates: [String] = []

    func requireValue(_ index: inout Int, for option: String) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw CLIError(message: "Missing value for \(option)")
        }
        return arguments[index]
    }

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]

        if argument == "--help" || argument == "-h" {
            printUsage()
            exit(0)
        } else if argument == "--source" {
            source = URL(fileURLWithPath: try requireValue(&index, for: argument), isDirectory: true)
        } else if argument.hasPrefix("--source=") {
            source = URL(fileURLWithPath: String(argument.dropFirst("--source=".count)), isDirectory: true)
        } else if argument == "--output" {
            output = URL(fileURLWithPath: try requireValue(&index, for: argument), isDirectory: true)
        } else if argument.hasPrefix("--output=") {
            output = URL(fileURLWithPath: String(argument.dropFirst("--output=".count)), isDirectory: true)
        } else if argument == "--work" {
            work = URL(fileURLWithPath: try requireValue(&index, for: argument), isDirectory: true)
        } else if argument.hasPrefix("--work=") {
            work = URL(fileURLWithPath: String(argument.dropFirst("--work=".count)), isDirectory: true)
        } else if argument == "--platforms" {
            platforms = try parsePlatforms(try requireValue(&index, for: argument))
        } else if argument.hasPrefix("--platforms=") {
            platforms = try parsePlatforms(String(argument.dropFirst("--platforms=".count)))
        } else if argument == "--libraries" {
            libraries = try parseLibraries(try requireValue(&index, for: argument))
        } else if argument.hasPrefix("--libraries=") {
            libraries = try parseLibraries(String(argument.dropFirst("--libraries=".count)))
        } else if argument == "--jobs" {
            jobs = try parsePositiveInt(try requireValue(&index, for: argument), option: argument)
        } else if argument.hasPrefix("--jobs=") {
            jobs = try parsePositiveInt(String(argument.dropFirst("--jobs=".count)), option: "--jobs")
        } else if argument == "--extra-configure-flag" {
            extraConfigureFlags.append(try requireValue(&index, for: argument))
        } else if argument.hasPrefix("--extra-configure-flag=") {
            extraConfigureFlags.append(String(argument.dropFirst("--extra-configure-flag=".count)))
        } else if argument == "--extra-cflag" {
            extraCFlags.append(try requireValue(&index, for: argument))
        } else if argument.hasPrefix("--extra-cflag=") {
            extraCFlags.append(String(argument.dropFirst("--extra-cflag=".count)))
        } else if argument == "--extra-ldflag" {
            extraLDFlags.append(try requireValue(&index, for: argument))
        } else if argument.hasPrefix("--extra-ldflag=") {
            extraLDFlags.append(String(argument.dropFirst("--extra-ldflag=".count)))
        } else if argument == "--pkg-config-path-template" {
            pkgConfigPathTemplates.append(try requireValue(&index, for: argument))
        } else if argument.hasPrefix("--pkg-config-path-template=") {
            pkgConfigPathTemplates.append(String(argument.dropFirst("--pkg-config-path-template=".count)))
        } else if argument == "--min-ios" {
            let value = try requireValue(&index, for: argument)
            minimumVersions[.ios] = value
            minimumVersions[.iossimulator] = value
        } else if argument.hasPrefix("--min-ios=") {
            let value = String(argument.dropFirst("--min-ios=".count))
            minimumVersions[.ios] = value
            minimumVersions[.iossimulator] = value
        } else if argument == "--min-macos" {
            minimumVersions[.macos] = try requireValue(&index, for: argument)
        } else if argument.hasPrefix("--min-macos=") {
            minimumVersions[.macos] = String(argument.dropFirst("--min-macos=".count))
        } else if argument == "--min-tvos" {
            let value = try requireValue(&index, for: argument)
            minimumVersions[.tvos] = value
            minimumVersions[.tvossimulator] = value
        } else if argument.hasPrefix("--min-tvos=") {
            let value = String(argument.dropFirst("--min-tvos=".count))
            minimumVersions[.tvos] = value
            minimumVersions[.tvossimulator] = value
        } else if argument == "--clean" {
            clean = true
        } else if argument == "--zip" {
            zip = true
        } else if argument == "--verbose" {
            verbose = true
        } else if argument == "--license" {
            let value = try requireValue(&index, for: argument)
            guard let parsed = LicenseMode(rawValue: value) else {
                throw CLIError(message: "Unsupported license mode: \(value)")
            }
            licenseMode = parsed
        } else if argument.hasPrefix("--license=") {
            let value = String(argument.dropFirst("--license=".count))
            guard let parsed = LicenseMode(rawValue: value) else {
                throw CLIError(message: "Unsupported license mode: \(value)")
            }
            licenseMode = parsed
        } else if argument == "--lgpl" {
            licenseMode = .lgpl
        } else if argument == "--gpl" {
            licenseMode = .gpl
        } else if argument == "--enable-libass" {
            enableLibass = true
        } else if argument == "--enable-drawtext" {
            enableDrawtext = true
        } else if argument == "--enable-avdevice" {
            enableAvdevice = true
        } else if argument == "--avdevice-platforms" {
            avdevicePlatforms = try parsePlatforms(try requireValue(&index, for: argument))
        } else if argument.hasPrefix("--avdevice-platforms=") {
            avdevicePlatforms = try parsePlatforms(String(argument.dropFirst("--avdevice-platforms=".count)))
        } else if argument == "--dependency-prefix-template" {
            let rawValue = try requireValue(&index, for: argument)
            let (name, template) = try parseNamedTemplate(rawValue, option: argument)
            dependencyPrefixTemplates[name] = template
        } else if argument.hasPrefix("--dependency-prefix-template=") {
            let rawValue = String(argument.dropFirst("--dependency-prefix-template=".count))
            let (name, template) = try parseNamedTemplate(rawValue, option: "--dependency-prefix-template")
            dependencyPrefixTemplates[name] = template
        } else {
            throw CLIError(message: "Unknown argument: \(argument)")
        }

        index += 1
    }

    guard let source else {
        throw CLIError(message: "Missing required argument: --source")
    }
    guard let output else {
        throw CLIError(message: "Missing required argument: --output")
    }

    return Options(
        source: source.standardizedFileURL,
        output: output.standardizedFileURL,
        work: work.standardizedFileURL,
        platforms: platforms,
        libraries: libraries,
        minimumVersions: minimumVersions,
        jobs: jobs,
        clean: clean,
        zip: zip,
        verbose: verbose,
        licenseMode: licenseMode,
        enableLibass: enableLibass,
        enableDrawtext: enableDrawtext,
        enableAvdevice: enableAvdevice,
        avdevicePlatforms: avdevicePlatforms,
        dependencyPrefixTemplates: dependencyPrefixTemplates,
        extraConfigureFlags: extraConfigureFlags,
        extraCFlags: extraCFlags,
        extraLDFlags: extraLDFlags,
        pkgConfigPathTemplates: pkgConfigPathTemplates
    )
}

func parseNamedTemplate(_ value: String, option: String) throws -> (String, String) {
    let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2 else {
        throw CLIError(message: "Invalid value for \(option): \(value)")
    }
    let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
    let template = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !template.isEmpty else {
        throw CLIError(message: "Invalid value for \(option): \(value)")
    }
    return (name, template)
}

func parsePositiveInt(_ value: String, option: String) throws -> Int {
    guard let intValue = Int(value), intValue > 0 else {
        throw CLIError(message: "Invalid value for \(option): \(value)")
    }
    return intValue
}

func parsePlatforms(_ value: String) throws -> [PlatformID] {
    let ids = value.split(separator: ",").map(String.init)
    guard !ids.isEmpty else {
        throw CLIError(message: "Empty --platforms list")
    }
    return try ids.map {
        guard let id = PlatformID(rawValue: $0) else {
            throw CLIError(message: "Unsupported platform: \($0)")
        }
        return id
    }
}

func parseLibraries(_ value: String) throws -> [String] {
    let libs = value
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard !libs.isEmpty else {
        throw CLIError(message: "Empty --libraries list")
    }

    let allowed = Set(defaultLibraries)
    for library in libs where !allowed.contains(library) {
        throw CLIError(message: "Unsupported library: \(library)")
    }
    return libs
}

func platform(for id: PlatformID, minimumVersions: [PlatformID: String]) throws -> Platform {
    guard let minimumVersion = minimumVersions[id] else {
        throw CLIError(message: "Missing minimum version for \(id.rawValue)")
    }

    switch id {
    case .ios:
        return Platform(id: id, sdk: "iphoneos", architectures: ["arm64"], minimumVersion: minimumVersion, xcodePlatformName: "ios", libraryIdentifier: "ios-arm64")
    case .iossimulator:
        return Platform(id: id, sdk: "iphonesimulator", architectures: ["arm64", "x86_64"], minimumVersion: minimumVersion, xcodePlatformName: "ios", libraryIdentifier: "ios-arm64_x86_64-simulator")
    case .macos:
        return Platform(id: id, sdk: "macosx", architectures: ["arm64", "x86_64"], minimumVersion: minimumVersion, xcodePlatformName: "macos", libraryIdentifier: "macos-arm64_x86_64")
    case .tvos:
        return Platform(id: id, sdk: "appletvos", architectures: ["arm64"], minimumVersion: minimumVersion, xcodePlatformName: "tvos", libraryIdentifier: "tvos-arm64")
    case .tvossimulator:
        return Platform(id: id, sdk: "appletvsimulator", architectures: ["arm64", "x86_64"], minimumVersion: minimumVersion, xcodePlatformName: "tvos", libraryIdentifier: "tvos-arm64_x86_64-simulator")
    }
}

final class Builder {
    let options: Options
    let fileManager = FileManager.default

    init(options: Options) {
        self.options = options
    }

    func run() throws {
        try validateInputs()

        if options.clean, fileManager.fileExists(atPath: options.work.path) {
            try fileManager.removeItem(at: options.work)
        }

        try createDirectory(options.output)
        try createDirectory(options.work)

        let platforms = try options.platforms.map { try platform(for: $0, minimumVersions: options.minimumVersions) }

        for platform in platforms {
            for arch in platform.architectures {
                try build(source: options.source, platform: platform, architecture: arch)
            }
        }

        for library in options.libraries {
            try createXCFramework(for: library, platforms: platforms)
        }

        if options.zip {
            try zipXCFrameworks()
        }
    }

    func validateInputs() throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: options.source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError(message: "FFmpeg source directory not found: \(options.source.path)")
        }

        let configure = options.source.appendingPathComponent("configure")
        guard fileManager.isExecutableFile(atPath: configure.path) else {
            throw CLIError(message: "configure script not found or not executable: \(configure.path)")
        }

        if options.enableLibass {
            let required = ["libass", "freetype", "harfbuzz", "fribidi", "unibreak"]
            let missing = required.filter { options.dependencyPrefixTemplates[$0] == nil }
            if !missing.isEmpty {
                throw CLIError(message: "Missing dependency prefix templates for libass mode: \(missing.joined(separator: ", "))")
            }
        }
    }

    func build(source: URL, platform: Platform, architecture: String) throws {
        let scratch = scratchURL(for: platform, architecture: architecture)
        let prefix = prefixURL(for: platform, architecture: architecture)
        try resetDirectory(scratch)
        try resetDirectory(prefix)

        let sdkPath = try xcrunSDKPath(platform.sdk)
        let cc = try xcrunFind(tool: "clang", sdk: platform.sdk)
        let targetTriple = makeTargetTriple(platform: platform, architecture: architecture)

        var extraCFlags = [
            "-arch", architecture,
            "-target", targetTriple,
            "-isysroot", sdkPath,
        ]
        extraCFlags.append(contentsOf: makeMinimumVersionFlags(platform: platform, architecture: architecture))
        extraCFlags.append(contentsOf: options.extraCFlags)

        var extraLDFlags = [
            "-arch", architecture,
            "-target", targetTriple,
            "-isysroot", sdkPath,
        ]
        extraLDFlags.append(contentsOf: makeMinimumVersionFlags(platform: platform, architecture: architecture))
        extraLDFlags.append(contentsOf: options.extraLDFlags)

        var configureArguments = [
            "--prefix=\(prefix.path)",
            "--enable-cross-compile",
            "--target-os=darwin",
            "--arch=\(ffmpegArchitectureName(architecture))",
            "--cc=\(cc)",
            "--sysroot=\(sdkPath)",
            "--pkg-config-flags=--static",
            "--disable-shared",
            "--enable-static",
            "--enable-pic",
            "--disable-programs",
            "--disable-doc",
            "--disable-htmlpages",
            "--disable-manpages",
            "--disable-podpages",
            "--disable-txtpages",
            "--extra-cflags=\(shellJoin(extraCFlags))",
            "--extra-ldflags=\(shellJoin(extraLDFlags))",
        ]

        if options.licenseMode == .gpl {
            configureArguments.append("--enable-gpl")
        }

        if options.enableAvdevice && options.avdevicePlatforms.contains(platform.id) {
            configureArguments.append("--enable-avdevice")
        } else {
            configureArguments.append(contentsOf: [
                "--disable-avdevice",
                "--disable-devices",
                "--disable-indevs",
                "--disable-outdevs",
            ])
        }

        if options.enableLibass {
            var libassArguments = [
                "--enable-libass",
                "--enable-libfreetype",
                "--enable-libharfbuzz",
                "--enable-libfribidi",
                "--enable-filter=ass",
                "--enable-filter=subtitles",
            ]
            if !options.enableDrawtext {
                libassArguments.append("--disable-filter=drawtext")
            }
            configureArguments.append(contentsOf: libassArguments)
        }

        configureArguments.append(contentsOf: options.extraConfigureFlags)

        var environment = ProcessInfo.processInfo.environment
        let pkgConfigPath = expandedPkgConfigPath(platform: platform, architecture: architecture)
        if !pkgConfigPath.isEmpty {
            environment["PKG_CONFIG_PATH"] = pkgConfigPath.joined(separator: ":")
        }

        log("Configuring \(platform.id.rawValue) \(architecture)")
        try runProcess(
            executable: source.appendingPathComponent("configure").path,
            arguments: configureArguments,
            currentDirectoryURL: scratch,
            environment: environment
        )

        log("Building \(platform.id.rawValue) \(architecture)")
        try runProcess(
            executable: "/usr/bin/make",
            arguments: ["-j", "\(options.jobs)", "install"],
            currentDirectoryURL: scratch,
            environment: environment
        )
    }

    func createXCFramework(for library: String, platforms: [Platform]) throws {
        let frameworkBase = options.work.appendingPathComponent("frameworks/\(library)", isDirectory: true)
        try resetDirectory(frameworkBase)

        var createArguments = ["-create-xcframework"]

        for platform in platforms {
            guard hasLibrary(library, platform: platform) else {
                continue
            }
            let frameworkURL = try makeFramework(for: library, platform: platform, outputDirectory: frameworkBase)
            createArguments.append(contentsOf: ["-framework", frameworkURL.path])
        }

        let moduleName = moduleName(for: library)
        let outputURL = options.output.appendingPathComponent("\(moduleName).xcframework", isDirectory: true)
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        createArguments.append(contentsOf: ["-output", outputURL.path])

        log("Creating \(moduleName).xcframework")
        try runProcess(
            executable: try xcrunFind(tool: "xcodebuild", sdk: nil),
            arguments: createArguments,
            currentDirectoryURL: options.work
        )
    }

    func makeFramework(for library: String, platform: Platform, outputDirectory: URL) throws -> URL {
        let moduleName = moduleName(for: library)
        let frameworkURL = outputDirectory.appendingPathComponent("\(platform.libraryIdentifier)/\(moduleName).framework", isDirectory: true)
        try resetDirectory(frameworkURL)

        let headersURL = frameworkURL.appendingPathComponent("Headers", isDirectory: true)
        let modulesURL = frameworkURL.appendingPathComponent("Modules", isDirectory: true)
        try createDirectory(headersURL)
        try createDirectory(modulesURL)

        let binaryURL = frameworkURL.appendingPathComponent(moduleName)
        let libraryPaths = platform.architectures.map {
            prefixURL(for: platform, architecture: $0)
                .appendingPathComponent("lib/lib\(library).a")
        }

        try createMergedBinary(for: library, platform: platform, libraryPaths: libraryPaths, outputURL: binaryURL)

        let headerSourceDir = prefixURL(for: platform, architecture: platform.architectures[0])
            .appendingPathComponent("include/lib\(library)", isDirectory: true)
        try copyDirectoryContents(from: headerSourceDir, to: headersURL)

        let moduleMap = """
        framework module \(moduleName) [system] {
            umbrella "."
            export *
        }
        """
        try moduleMap.write(to: modulesURL.appendingPathComponent("module.modulemap"), atomically: true, encoding: .utf8)

        let infoPlist = frameworkInfoPlist(moduleName: moduleName, platform: platform)
        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: frameworkURL.appendingPathComponent("Info.plist"))

        return frameworkURL
    }

    func hasLibrary(_ library: String, platform: Platform) -> Bool {
        platform.architectures.allSatisfy {
            let staticLib = prefixURL(for: platform, architecture: $0).appendingPathComponent("lib/lib\(library).a")
            let dynamicLib = prefixURL(for: platform, architecture: $0).appendingPathComponent("lib/lib\(library).dylib")
            return fileManager.fileExists(atPath: staticLib.path) || fileManager.fileExists(atPath: dynamicLib.path)
        }
    }

    func frameworkInfoPlist(moduleName: String, platform: Platform) -> [String: Any] {
        [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": moduleName,
            "CFBundleIdentifier": "org.ffmpeg.\(moduleName.lowercased())",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": moduleName,
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "MinimumOSVersion": platform.minimumVersion,
        ]
    }

    func zipXCFrameworks() throws {
        let contents = try fileManager.contentsOfDirectory(at: options.output, includingPropertiesForKeys: nil)
        for item in contents where item.pathExtension == "xcframework" {
            let zipURL = item.deletingPathExtension().appendingPathExtension("xcframework.zip")
            if fileManager.fileExists(atPath: zipURL.path) {
                try fileManager.removeItem(at: zipURL)
            }
            log("Zipping \(item.lastPathComponent)")
            try runProcess(
                executable: "/usr/bin/ditto",
                arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", item.path, zipURL.path],
                currentDirectoryURL: options.output
            )
        }
    }

    func expandedPkgConfigPath(platform: Platform, architecture: String) -> [String] {
        var values = options.pkgConfigPathTemplates.map {
            $0
                .replacingOccurrences(of: "{platform}", with: dependencyPlatformName(for: platform))
                .replacingOccurrences(of: "{arch}", with: architecture)
                .replacingOccurrences(of: "{sdk}", with: platform.sdk)
        }
        if options.enableLibass {
            let required = ["libass", "freetype", "harfbuzz", "fribidi", "unibreak"]
            values.append(contentsOf: required.map {
                dependencyPrefix(for: $0, platform: platform, architecture: architecture)
                    .appendingPathComponent("lib/pkgconfig", isDirectory: true)
                    .path
            })
        }
        return values
    }

    func createMergedBinary(for library: String, platform: Platform, libraryPaths: [URL], outputURL: URL) throws {
        if library == "avfilter", options.enableLibass {
            let perArchitectureMerged = try platform.architectures.map { arch in
                try mergedArchiveForAvfilter(platform: platform, architecture: arch)
            }
            if perArchitectureMerged.count == 1 {
                try copyItem(at: perArchitectureMerged[0], to: outputURL)
            } else {
                try runProcess(
                    executable: try xcrunFind(tool: "lipo", sdk: nil),
                    arguments: ["-create"] + perArchitectureMerged.map(\.path) + ["-output", outputURL.path],
                    currentDirectoryURL: options.work
                )
            }
            return
        }

        if libraryPaths.count == 1 {
            try copyItem(at: libraryPaths[0], to: outputURL)
        } else {
            try runProcess(
                executable: try xcrunFind(tool: "lipo", sdk: nil),
                arguments: ["-create"] + libraryPaths.map(\.path) + ["-output", outputURL.path],
                currentDirectoryURL: options.work
            )
        }
    }

    func mergedArchiveForAvfilter(platform: Platform, architecture: String) throws -> URL {
        let mergedURL = options.work.appendingPathComponent("merged/avfilter/\(platform.id.rawValue)/\(architecture)/libavfilter.a")
        try createDirectory(mergedURL.deletingLastPathComponent())

        let ffmpegArchive = prefixURL(for: platform, architecture: architecture).appendingPathComponent("lib/libavfilter.a")
        let dependencies = [
            dependencyLibrary(named: "libass", filename: "libass.a", platform: platform, architecture: architecture),
            dependencyLibrary(named: "freetype", filename: "libfreetype.a", platform: platform, architecture: architecture),
            dependencyLibrary(named: "harfbuzz", filename: "libharfbuzz.a", platform: platform, architecture: architecture),
            dependencyLibrary(named: "fribidi", filename: "libfribidi.a", platform: platform, architecture: architecture),
            dependencyLibrary(named: "unibreak", filename: "libunibreak.a", platform: platform, architecture: architecture),
        ]

        try runProcess(
            executable: try xcrunFind(tool: "libtool", sdk: nil),
            arguments: ["-static", "-o", mergedURL.path, ffmpegArchive.path] + dependencies.map(\.path),
            currentDirectoryURL: options.work
        )
        return mergedURL
    }

    func dependencyLibrary(named dependency: String, filename: String, platform: Platform, architecture: String) -> URL {
        dependencyPrefix(for: dependency, platform: platform, architecture: architecture)
            .appendingPathComponent("lib/\(filename)")
    }

    func dependencyPrefix(for dependency: String, platform: Platform, architecture: String) -> URL {
        let template = options.dependencyPrefixTemplates[dependency]!
        let resolved = template
            .replacingOccurrences(of: "{name}", with: dependency)
            .replacingOccurrences(of: "{platform}", with: dependencyPlatformName(for: platform))
            .replacingOccurrences(of: "{arch}", with: architecture)
            .replacingOccurrences(of: "{sdk}", with: platform.sdk)
        return URL(fileURLWithPath: resolved, isDirectory: true)
    }

    func dependencyPlatformName(for platform: Platform) -> String {
        switch platform.id {
        case .ios:
            return "ios"
        case .iossimulator:
            return "isimulator"
        case .macos:
            return "macos"
        case .tvos:
            return "tvos"
        case .tvossimulator:
            return "tvsimulator"
        }
    }

    func moduleName(for library: String) -> String {
        "lib\(library.lowercased())"
    }

    func prefixURL(for platform: Platform, architecture: String) -> URL {
        options.work.appendingPathComponent("prefix/\(platform.id.rawValue)/\(architecture)", isDirectory: true)
    }

    func scratchURL(for platform: Platform, architecture: String) -> URL {
        options.work.appendingPathComponent("scratch/\(platform.id.rawValue)/\(architecture)", isDirectory: true)
    }

    func makeTargetTriple(platform: Platform, architecture: String) -> String {
        switch platform.id {
        case .ios:
            return "\(architecture)-apple-ios\(platform.minimumVersion)"
        case .iossimulator:
            return "\(architecture)-apple-ios\(platform.minimumVersion)-simulator"
        case .macos:
            return "\(architecture)-apple-macos\(platform.minimumVersion)"
        case .tvos:
            return "\(architecture)-apple-tvos\(platform.minimumVersion)"
        case .tvossimulator:
            return "\(architecture)-apple-tvos\(platform.minimumVersion)-simulator"
        }
    }

    func makeMinimumVersionFlags(platform: Platform, architecture: String) -> [String] {
        switch platform.id {
        case .ios:
            return ["-miphoneos-version-min=\(platform.minimumVersion)"]
        case .iossimulator:
            return ["-mios-simulator-version-min=\(platform.minimumVersion)"]
        case .macos:
            return ["-mmacosx-version-min=\(platform.minimumVersion)"]
        case .tvos:
            return ["-mtvos-version-min=\(platform.minimumVersion)"]
        case .tvossimulator:
            return ["-mtvos-simulator-version-min=\(platform.minimumVersion)"]
        }
    }

    func ffmpegArchitectureName(_ architecture: String) -> String {
        architecture == "arm64" ? "aarch64" : architecture
    }

    func shellJoin(_ values: [String]) -> String {
        values.map {
            if $0.contains(" ") {
                return "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return $0
        }.joined(separator: " ")
    }

    func xcrunSDKPath(_ sdk: String) throws -> String {
        try captureOutput(executable: "/usr/bin/xcrun", arguments: ["--sdk", sdk, "--show-sdk-path"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func xcrunFind(tool: String, sdk: String?) throws -> String {
        var arguments = ["--find", tool]
        if let sdk {
            arguments = ["--sdk", sdk] + arguments
        }
        return try captureOutput(executable: "/usr/bin/xcrun", arguments: arguments)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func captureOutput(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
            throw CLIError(message: "\(executable) \(arguments.joined(separator: " ")) failed\n\(stderrString)")
        }

        return String(data: stdoutData, encoding: .utf8) ?? ""
    }

    func runProcess(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String]? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        if options.verbose {
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        } else {
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
        }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError(message: "Command failed: \(executable) \(arguments.joined(separator: " "))")
        }
    }

    func resetDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try createDirectory(url)
    }

    func createDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    func copyDirectoryContents(from source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            throw CLIError(message: "Header directory not found: \(source.path)")
        }
        let contents = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for item in contents {
            let target = destination.appendingPathComponent(item.lastPathComponent, isDirectory: false)
            try copyItem(at: item, to: target)
        }
    }

    func log(_ message: String) {
        FileHandle.standardError.write(Data("[build_ffmpeg_xcframework] \(message)\n".utf8))
    }
}

do {
    let options = try parseOptions()
    try Builder(options: options).run()
} catch {
    if CommandLine.arguments.dropFirst().contains("--verbose") {
        fputs("error: \(error)\n", stderr)
    } else {
        fputs("error: \(error.localizedDescription)\n", stderr)
    }
    printUsage()
    exit(1)
}
