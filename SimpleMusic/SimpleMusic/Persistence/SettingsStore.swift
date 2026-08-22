import Foundation

/// 用户偏好在 UserDefaults 系统存储 API 上的窄封装，跨实例读取同一套设置。
struct SettingsStore {
    private enum Key {
        static let cellular = "allowsCellularDownloads"
        static let autoPlay = "autoPlayAfterDownload"
        static let audioEffectPreset = "audioEffectPreset"
        static let audioEffectWetDryMix = "audioEffectWetDryMix"
    }

    let defaults: UserDefaults

    var allowsCellularDownloads: Bool {
        get { defaults.bool(forKey: Key.cellular) }
        nonmutating set { defaults.set(newValue, forKey: Key.cellular) }
    }

    var autoPlayAfterDownload: Bool {
        get { defaults.bool(forKey: Key.autoPlay) }
        nonmutating set { defaults.set(newValue, forKey: Key.autoPlay) }
    }

    var audioEffectSettings: AudioEffectSettings {
        get {
            let preset = defaults.string(forKey: Key.audioEffectPreset)
                .flatMap(AudioEffectPreset.init(rawValue:)) ?? .off
            let storedMix = defaults.object(forKey: Key.audioEffectWetDryMix) as? NSNumber
            return AudioEffectSettings(
                preset: preset,
                wetDryMix: storedMix?.floatValue ?? 35
            )
        }
        nonmutating set {
            defaults.set(newValue.preset.rawValue, forKey: Key.audioEffectPreset)
            defaults.set(newValue.wetDryMix, forKey: Key.audioEffectWetDryMix)
        }
    }
}
