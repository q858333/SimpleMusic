import XCTest
@testable import SimpleMusic

final class SettingsStoreTests: XCTestCase {
    func testSettingsPersistAcrossInstances() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        SettingsStore(defaults: defaults).allowsCellularDownloads = true

        XCTAssertTrue(SettingsStore(defaults: defaults).allowsCellularDownloads)
    }
}
