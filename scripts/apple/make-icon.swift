// Exports flat PNGs of Xenia's app icon from its Icon Composer document (apple/Resources/Xenia.icon),
// for the places that can't use the .icon itself: the sign-in logo (light and dark) and the
// README's icon. Run it after changing the icon in Icon Composer:
//
//   swift scripts/apple/make-icon.swift
//
// It uses ictool, which ships inside Xcode's Icon Composer.
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let icon = root.appending(path: "apple/Resources/Xenia.icon").path

func developerDir() -> String {
    let pipe = Pipe()
    let select = Process()
    select.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    select.arguments = ["-p"]
    select.standardOutput = pipe
    try? select.run()
    select.waitUntilExit()
    let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? "/Applications/Xcode.app/Contents/Developer" : path
}

let ictool = URL(fileURLWithPath: developerDir())
    .deletingLastPathComponent()
    .appending(path: "Applications/Icon Composer.app/Contents/Executables/ictool")

guard FileManager.default.isExecutableFile(atPath: ictool.path) else {
    FileHandle.standardError.write(Data("ictool not found at \(ictool.path). Select an Xcode with Icon Composer (xcode-select -s).\n".utf8))
    exit(1)
}

/// Renders one appearance of the icon, already masked to its platform's shape.
func export(_ output: String, platform: String, rendition: String, size: Int) {
    let path = root.appending(path: output).path
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = ictool
    process.arguments = [
        icon, "--export-image", "--output-file", path,
        "--platform", platform, "--rendition", rendition,
        "--width", "\(size)", "--height", "\(size)", "--scale", "1",
    ]
    process.standardOutput = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        FileHandle.standardError.write(Data("Couldn't run ictool: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    guard process.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("ictool failed for \(output)\n".utf8))
        exit(1)
    }
    print("Wrote \(output)")
}

export("apple/Resources/Assets.xcassets/Logo.imageset/logo.png", platform: "iOS", rendition: "Default", size: 512)
export("apple/Resources/Assets.xcassets/Logo.imageset/logo-dark.png", platform: "iOS", rendition: "Dark", size: 512)
// Shown at 128 points in the README; 256 pixels keeps it sharp on high-density screens.
export("docs/images/icon.png", platform: "macOS", rendition: "Default", size: 256)
