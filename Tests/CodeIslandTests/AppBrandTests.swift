import XCTest
@testable import CodeIsland

/// The fork ships as "AISM". Only what the user reads changes: the bundle id,
/// ~/.codeisland, hook markers and wire names stay, so settings, granted
/// permissions and installed hooks carry over.
final class AppBrandTests: XCTestCase {
    private func infoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testAppIsNamedAISM() throws {
        let plist = try infoPlist()
        XCTAssertEqual(AppBrand.name, "AISM")
        XCTAssertEqual(plist["CFBundleName"] as? String, AppBrand.name)
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, AppBrand.name)
    }

    func testBundleIdentifierIsKeptSoSettingsCarryOver() throws {
        XCTAssertEqual(try infoPlist()["CFBundleIdentifier"] as? String, "com.codeisland.app")
    }

    func testNoTranslationStillSaysCodeIsland() {
        for (language, table) in L10n.strings {
            for (key, value) in table where value.contains("CodeIsland") {
                XCTFail("\(language).\(key) still says CodeIsland: \(value)")
            }
        }
        XCTAssertTrue(L10n.strings["en"]?["settings_title"]?.contains("AISM") == true)
    }
}
