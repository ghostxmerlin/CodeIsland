import XCTest
@testable import CodeIsland
import CodeIslandCore

/// With the "Luna voice" style, event sounds become Luna's lines where the Tab5 speaks, and silence elsewhere;
/// the master toggle and the per-event toggles still decide first.
@MainActor
final class LunaSoundStyleTests: XCTestCase {
    private var played: [String] = []
    private var saved: [String: Any?] = [:]
    private let keys = [SettingsKey.soundEnabled, SettingsKey.soundStyle, SettingsKey.soundApprovalNeeded,
                        SettingsKey.soundTaskComplete, SettingsKey.soundSessionStart, SettingsKey.soundBoot,
                        SettingsKey.quietHoursEnabled, SettingsKey.autoMuteWhenAway]

    override func setUp() {
        super.setUp()
        played = []
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        SoundManager.shared.playSink = { [weak self] name in self?.played.append(name) }
        SceneMuteMonitor.shared.resetForTesting()
        for key in [SettingsKey.soundEnabled, SettingsKey.soundApprovalNeeded, SettingsKey.soundTaskComplete,
                    SettingsKey.soundSessionStart, SettingsKey.soundBoot] {
            UserDefaults.standard.set(true, forKey: key)
        }
        UserDefaults.standard.set(false, forKey: SettingsKey.quietHoursEnabled)
        UserDefaults.standard.set(false, forKey: SettingsKey.autoMuteWhenAway)
    }

    override func tearDown() {
        SoundManager.shared.playSink = nil
        SceneMuteMonitor.shared.resetForTesting()
        for key in keys {
            if let value = saved[key] ?? nil { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testLunaSpeaksWhereTheTab5DoesAndIsSilentElsewhere() {
        UserDefaults.standard.set(SoundStyle.luna.rawValue, forKey: SettingsKey.soundStyle)
        SoundManager.shared.handleEvent("PermissionRequest")
        SoundManager.shared.handleEvent("Stop")
        SoundManager.shared.handleEvent("SessionStart")
        SoundManager.shared.playBoot()
        XCTAssertEqual(played, ["luna:red", "luna:blue", "luna:boot"])
    }

    func testThePerEventToggleStillDecides() {
        UserDefaults.standard.set(SoundStyle.luna.rawValue, forKey: SettingsKey.soundStyle)
        UserDefaults.standard.set(false, forKey: SettingsKey.soundApprovalNeeded)
        SoundManager.shared.handleEvent("PermissionRequest")
        XCTAssertEqual(played, [])
    }

    func testTheOriginalStyleKeepsTheEffects() {
        UserDefaults.standard.set(SoundStyle.original.rawValue, forKey: SettingsKey.soundStyle)
        SoundManager.shared.handleEvent("PermissionRequest")
        SoundManager.shared.handleEvent("SessionStart")
        XCTAssertEqual(played, ["8bit_approval", "8bit_start"])
    }
}
