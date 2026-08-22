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

    func testNewAudioEffectPresetRawValuesRoundTripThroughSettingsStore() {
        let suiteName = "\(#function).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let presets: [AudioEffectPreset] = [
            .panoramicSurround,
            .classicRock,
            .dynamicElectronic,
            .clearVocal
        ]

        for preset in presets {
            store.audioEffectSettings = AudioEffectSettings(preset: preset, wetDryMix: 67)
            let restored = SettingsStore(defaults: defaults).audioEffectSettings
            XCTAssertEqual(restored.preset, preset)
            XCTAssertEqual(restored.wetDryMix, 67)
        }
    }

    func testPanoramicProfileScalesEQAndReverbWithIntensity() {
        let full = AudioEffectPreset.panoramicSurround.resolvedProfile(intensity: 100)
        let half = AudioEffectPreset.panoramicSurround.resolvedProfile(intensity: 50)

        XCTAssertEqual(full.bands.map(\.frequency), [120, 600, 7_000])
        XCTAssertEqual(full.bands.map(\.gain), [1.5, -1.5, 2])
        XCTAssertEqual(half.bands.map(\.gain), [0.75, -0.75, 1])
        XCTAssertEqual(full.reverb, .largeRoom)
        XCTAssertEqual(full.wetDryMix, 30)
        XCTAssertEqual(half.wetDryMix, 15)
    }

    func testOffProfileBypassesEQAndReverb() {
        let profile = AudioEffectPreset.off.resolvedProfile(intensity: 100)
        XCTAssertTrue(profile.bands.isEmpty)
        XCTAssertNil(profile.reverb)
        XCTAssertEqual(profile.wetDryMix, 0)
    }
}
