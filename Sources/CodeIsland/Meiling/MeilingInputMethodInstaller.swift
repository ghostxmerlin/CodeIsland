import Carbon
import Foundation

/// Copies the embedded MeilingInputMethod.app (built by scripts/build-meiling-ime.sh, embedded by build.sh) into
/// ~/Library/Input Methods and registers + enables its input mode.
enum MeilingInputMethodInstaller {
    static let bundleName = "MeilingInputMethod.app"

    static func install() -> String {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent(bundleName),
              FileManager.default.fileExists(atPath: source.path) else {
            return "这个 AISM 没有内嵌 \(bundleName)。先运行 scripts/build-meiling-ime.sh，再运行 build.sh。"
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods")
        let target = folder.appendingPathComponent(bundleName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            return "复制失败：\(error.localizedDescription)"
        }
        let status = TISRegisterInputSource(target as CFURL)
        guard status == noErr else { return "已复制到 \(target.path)，但注册失败（\(status)）。请注销后再登录。" }
        let filter = [kTISPropertyInputSourceID as String: MeilingInputSwitcher.sourceID] as CFDictionary
        if let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] {
            list.forEach { TISEnableInputSource($0) }
        }
        return MeilingInputSwitcher.installed
            ? "已安装并启用“美玲”输入法。平时不用选它，听写时 AISM 会自动切换。"
            : "已安装。请到“系统设置 → 键盘 → 输入法”里添加“美玲”。"
    }
}
