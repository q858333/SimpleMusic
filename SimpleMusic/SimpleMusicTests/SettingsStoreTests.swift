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

    func testPanoramicProfileUsesLiteralValuesAtZeroHalfAndFullIntensity() {
        XCTAssertEqual(
            AudioEffectPreset.panoramicSurround.resolvedProfile(intensity: 0),
            ResolvedAudioEffectProfile(
                bands: [
                    .init(kind: .lowShelf, frequency: 120, bandwidth: 1, gain: 0),
                    .init(kind: .parametric, frequency: 600, bandwidth: 1, gain: 0),
                    .init(kind: .highShelf, frequency: 7_000, bandwidth: 1, gain: 0),
                ],
                reverb: .largeRoom,
                wetDryMix: 0
            )
        )
        XCTAssertEqual(
            AudioEffectPreset.panoramicSurround.resolvedProfile(intensity: 50),
            ResolvedAudioEffectProfile(
                bands: [
                    .init(kind: .lowShelf, frequency: 120, bandwidth: 1, gain: 0.75),
                    .init(kind: .parametric, frequency: 600, bandwidth: 1, gain: -0.75),
                    .init(kind: .highShelf, frequency: 7_000, bandwidth: 1, gain: 1),
                ],
                reverb: .largeRoom,
                wetDryMix: 15
            )
        )
        XCTAssertEqual(
            AudioEffectPreset.panoramicSurround.resolvedProfile(intensity: 100),
            ResolvedAudioEffectProfile(
                bands: [
                    .init(kind: .lowShelf, frequency: 120, bandwidth: 1, gain: 1.5),
                    .init(kind: .parametric, frequency: 600, bandwidth: 1, gain: -1.5),
                    .init(kind: .highShelf, frequency: 7_000, bandwidth: 1, gain: 2),
                ],
                reverb: .largeRoom,
                wetDryMix: 30
            )
        )
    }

    func testClassicRockProfileUsesLiteralValuesAtZeroHalfAndFullIntensity() {
        XCTAssertEqual(
            AudioEffectPreset.classicRock.resolvedProfile(intensity: 0),
            ResolvedAudioEffectProfile(
                bands: [
                    .init(kind: .lowShelf, frequency: 90, bandwidth: 1, gain: 0),
                    .init(kind: .parametric, frequency: 300, bandwidth: 1, gain: 0),
                    .init(kind: .parametric, frequency: 1_800, bandwidth: 1, gain: 0),
                    .init(kind: .highShelf, frequency: 6_000, bandwidth: 1, gain: 0),
                ],
                reverb: .plate,
                wetDryMix: 0
            )
        )
        XCTAssertEqual(
            AudioEffectPreset.classicRock.resolvedProfile(intensity: 50),
            ResolvedAudioEffectProfile(
                bands: [
                    .init(kind: .lowShelf, frequency: 90, bandwidth: 1, gain: 1.5),
                    .init(kind: .parametric, frequency: 300, bandwidth: 1, gain: -0.5),
                    .init(kind: .parametric, frequency: 1_800, bandwidth: 1, gain: 1.25),
                    .init(kind: .highShelf, frequency: 6_000, bandwidth: 1, gain: 1),
                ],
                reverb: .plate,
                wetDryMix: 6
            )
        )
        XCTAssertEqual(
            AudioEffectPreset.classicRock.resolvedProfile(intensity: 100),
            ResolvedAudioEffectProfile(
                bands: [
                    .init(kind: .lowShelf, frequency: 90, bandwidth: 1, gain: 3),
                    .init(kind: .parametric, frequency: 300, bandwidth: 1, gain: -1),
                    .init(kind: .parametric, frequency: 1_800, bandwidth: 1, gain: 2.5),
                    .init(kind: .highShelf, frequency: 6_000, bandwidth: 1, gain: 2),
                ],
                reverb: .plate,
                wetDryMix: 12
            )
        )
    }

    func testDynamicElectronicProfileUsesLiteralValuesAtZeroHalfAndFullIntensity() {
        XCTAssertEqual(
            AudioEffectPreset.dynamicElectronic.resolvedProfile(intensity: 0),
            ResolvedAudioEffectProfile(
                bands: [
                    .init(kind: .lowShelf, frequency: 70, bandwidth: 1, gain: 0),
                    .init(kind: .parametric, frequency: 500, bandwidth: 1, gain: 0),
                    .init(kind: .highShelf, frequency: 8_000, bandwidth: 1, gain: 0),
                ],
                reverb: .plate,
                wetDryMix: 0
            )
        )
        XCTAssertEqual(
            AudioEffectPreset.dynamicElectronic.resolvedProfile(intensity: 50),
            ResolvedAudioEffectProfile(
                bands: [
                    .init(kind: .lowShelf, frequency: 70, bandwidth: 1, gain: 2),
                    .init(kind: .parametric, frequency: 500, bandwidth: 1, gain: -1),
                    .init(kind: .highShelf, frequency: 8_000, bandwidth: 1, gain: 1.5),
                ],
                reverb: .plate,
                wetDryMix: 8
            )
        )
        XCTAssertEqual(
            AudioEffectPreset.dynamicElectronic.resolvedProfile(intensity: 100),
            ResolvedAudioEffectProfile(
                bands: [
                    .init(kind: .lowShelf, frequency: 70, bandwidth: 1, gain: 4),
                    .init(kind: .parametric, frequency: 500, bandwidth: 1, gain: -2),
                    .init(kind: .highShelf, frequency: 8_000, bandwidth: 1, gain: 3),
                ],
                reverb: .plate,
                wetDryMix: 16
            )
        )
    }

    func testClearVocalProfileUsesLiteralValuesAtZeroHalfAndFullIntensity() {
        XCTAssertEqual(
            AudioEffectPreset.clearVocal.resolvedProfile(intensity: 0),
            ResolvedAudioEffectProfile(
                bands: [
                    .init(kind: .parametric, frequency: 250, bandwidth: 1, gain: 0),
                    .init(kind: .parametric, frequency: 2_500, bandwidth: 1, gain: 0),
                    .init(kind: .highShelf, frequency: 6_000, bandwidth: 1, gain: 0),
                ],
                reverb: .smallRoom,
                wetDryMix: 0
            )
        )
        XCTAssertEqual(
            AudioEffectPreset.clearVocal.resolvedProfile(intensity: 50),
            ResolvedAudioEffectProfile(
                bands: [
                    .init(kind: .parametric, frequency: 250, bandwidth: 1, gain: -1),
                    .init(kind: .parametric, frequency: 2_500, bandwidth: 1, gain: 1.5),
                    .init(kind: .highShelf, frequency: 6_000, bandwidth: 1, gain: 1),
                ],
                reverb: .smallRoom,
                wetDryMix: 4
            )
        )
        XCTAssertEqual(
            AudioEffectPreset.clearVocal.resolvedProfile(intensity: 100),
            ResolvedAudioEffectProfile(
                bands: [
                    .init(kind: .parametric, frequency: 250, bandwidth: 1, gain: -2),
                    .init(kind: .parametric, frequency: 2_500, bandwidth: 1, gain: 3),
                    .init(kind: .highShelf, frequency: 6_000, bandwidth: 1, gain: 2),
                ],
                reverb: .smallRoom,
                wetDryMix: 8
            )
        )
    }

    func testLegacyReverbProfileKeepsOriginalIntensityContract() {
        XCTAssertEqual(
            AudioEffectPreset.cathedral.resolvedProfile(intensity: 42),
            ResolvedAudioEffectProfile(bands: [], reverb: .cathedral, wetDryMix: 42)
        )
    }

    func testAudioEffectSettingsClampIntensityToSupportedRange() {
        XCTAssertEqual(
            AudioEffectSettings(preset: .classicRock, wetDryMix: -1).wetDryMix,
            0
        )
        XCTAssertEqual(
            AudioEffectSettings(preset: .classicRock, wetDryMix: 101).wetDryMix,
            100
        )
    }

    func testLegacyRawValueRestoresWithoutMigration() {
        let suiteName = "\(#function).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("largeHall", forKey: "audioEffectPreset")
        defaults.set(61, forKey: "audioEffectWetDryMix")

        XCTAssertEqual(
            SettingsStore(defaults: defaults).audioEffectSettings,
            AudioEffectSettings(preset: .largeHall, wetDryMix: 61)
        )
    }

    func testUnknownRawValueFallsBackToOff() {
        let suiteName = "\(#function).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("futureSpatialPreset", forKey: "audioEffectPreset")
        defaults.set(44, forKey: "audioEffectWetDryMix")

        XCTAssertEqual(
            SettingsStore(defaults: defaults).audioEffectSettings,
            AudioEffectSettings(preset: .off, wetDryMix: 44)
        )
    }

    func testOffProfileBypassesEQAndReverb() {
        let profile = AudioEffectPreset.off.resolvedProfile(intensity: 100)
        XCTAssertTrue(profile.bands.isEmpty)
        XCTAssertNil(profile.reverb)
        XCTAssertEqual(profile.wetDryMix, 0)
    }
}
