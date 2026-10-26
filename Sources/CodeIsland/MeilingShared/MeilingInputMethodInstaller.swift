import Carbon
import Foundation

/// Copies the embedded MeilingInputMethod.app (built by scripts/build-meiling-ime.sh, embedded by build.sh) into
/// ~/Library/Input Methods and registers + enables its input mode.
enum MeilingInputMethodInstaller {
    static let bundleName = "MeilingInputMethod.app"

    static func install() -> String {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent(bundleName),
              FileManager.default.fileExists(atPath: source.path) else {
            return "This AISM has no embedded \(bundleName). Run scripts/build-meiling-ime.sh, then build.sh."
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods")
        let target = folder.appendingPathComponent(bundleName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            return "Copy failed: \(error.localizedDescription)"
        }
        let status = TISRegisterInputSource(target as CFURL)
        guard status == noErr else { return "Copied to \(target.path), but registration failed (\(status)). Log out and back in." }
        // Both the input method and its mode: with only the mode enabled, the mode never shows up as enabled.
        let filter = [kTISPropertyBundleID as String: "com.aism.inputmethod.Meiling"] as CFDictionary
        if let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] {
            list.forEach { TISEnableInputSource($0) }
        }
        return MeilingInputSwitcher.installed
            ? "Installed and enabled the Meyrin input method. No need to select it: AISM switches to it while dictating."
            : "Installed. Add \"Meyrin\" in System Settings → Keyboard → Input Sources."
    }
}
