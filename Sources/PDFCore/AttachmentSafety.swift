import Foundation
import UniformTypeIdentifiers

/// Checks for files embedded in a PDF, whose names and contents come from
/// whoever made the document.
public enum AttachmentSafety {
    /// A file name safe to suggest: no folders, no control or
    /// bidirectional-override characters (which can disguise an extension,
    /// as in "invoice‮fdp.app"), no leading dots, never empty.
    public static func cleanFilename(_ name: String) -> String {
        let hidden: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                   0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF]
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if hidden.contains(scalar.value) || scalar.properties.generalCategory == .control { continue }
            if scalar == "/" || scalar == ":" || scalar == "\\" { scalars.append("_"); continue }
            scalars.append(scalar)
        }
        var cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 200 { cleaned = String(cleaned.suffix(200)) }
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    private static let riskyExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "zsh", "bash", "csh", "ksh", "py", "pl", "rb", "js", "jar",
        "pkg", "mpkg", "dmg", "iso", "sparseimage", "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "cpgz",
        "workflow", "scpt", "scptd", "applescript", "action", "prefpane", "kext", "plugin", "bundle", "framework",
        "dylib", "webloc", "inetloc", "fileloc", "url", "exe", "msi", "bat", "cmd", "ps1", "vbs", "scr", "lnk",
        "docm", "xlsm", "pptm", "html", "htm", "svg", "shortcut", "mobileconfig", "configprofile",
    ]

    /// True for kinds of file that can run code or contain apps (programs,
    /// scripts, installers, disk images, archives): worth a warning first.
    public static func isRisky(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext.isEmpty { return true }   // could be a Unix executable
        if riskyExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return [UTType.executable, .application, .applicationBundle, .script, .shellScript, .archive, .diskImage,
                .package, .installerPackage].contains { type.conforms(to: $0) }
    }
}

extension UTType {
    static let installerPackage = UTType("com.apple.installer-package-archive") ?? .data
}
