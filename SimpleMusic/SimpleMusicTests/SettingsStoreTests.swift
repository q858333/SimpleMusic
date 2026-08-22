import XCTest
@testable import SimpleMusic

final class SettingsStoreTests: XCTestCase {
    func testSettingsPersistAcrossInstances() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        SettingsStore(defaults: defaults).allowsCellularDownloads = true

        XCTAssertTrue(SettingsStore(defaults: defaults).allowsCellularDownloads)
    }

    /// 混响预设和强度必须跨歌曲、跨页面保持，重新创建设置对象后仍能读取。
    func testAudioEffectSettingsPersistAcrossInstances() {
        let suiteName = "\(#function).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let writer = SettingsStore(defaults: defaults)
        writer.audioEffectSettings = AudioEffectSettings(preset: .cathedral, wetDryMix: 72)

        XCTAssertEqual(
            SettingsStore(defaults: defaults).audioEffectSettings,
            AudioEffectSettings(preset: .cathedral, wetDryMix: 72)
        )
    }
}
