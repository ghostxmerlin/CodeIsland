import AppKit
import CodeIslandCore

/// Plays Luna's lines (Resources/LunaVoice: lines.json + <id>.wav, the X10A Tab5's voice pack) one at a time; the
/// rules live in LunaVoiceQueue; LunaVoiceCard shows the line while it plays. Used by SoundManager when the sound
/// style is "Luna voice".
@MainActor
final class LunaVoicePlayer: NSObject, NSSoundDelegate {
    static let shared = LunaVoicePlayer()

    private(set) lazy var lines: [LunaLine] = {
        guard let url = Self.resource("lines", "json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([LunaLine].self, from: data)) ?? []
    }()
    private var queue = LunaVoiceQueue()
    private var current: NSSound?

    /// A cue for `group` (LunaVoiceRules): spoken now, or after the line that is playing.
    func speak(_ group: String) {
        guard queue.push(group, now: Date()) else { return }
        if current == nil { playNext() }
    }

    /// One line of the group straight away (the Settings preview).
    func preview(_ group: String) {
        current?.stop()
        current = nil
        queue = LunaVoiceQueue()
        speak(group)
    }

    private func playNext() {
        guard let line = queue.next(from: lines, random: { Int.random(in: 0..<$0) }),
              let url = Self.resource(line.id, "wav"),
              let sound = NSSound(contentsOf: url, byReference: false) else {
            current = nil
            LunaVoiceCard.shared.finished()
            return
        }
        LunaVoiceCard.shared.show(line)
        sound.volume = SoundVolumeCurve.amplitude(forPercent: UserDefaults.standard.integer(forKey: SettingsKey.soundVolume))
        sound.delegate = self
        current = sound
        sound.play()
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        MainActor.assumeIsolated {
            guard sound === current else { return }
            current = nil
            playNext()
        }
    }

    private static func resource(_ name: String, _ ext: String) -> URL? {
        Bundle.appModule.url(forResource: name, withExtension: ext, subdirectory: "Resources/LunaVoice")
            ?? Bundle.appModule.url(forResource: name, withExtension: ext, subdirectory: "LunaVoice")
    }
}
