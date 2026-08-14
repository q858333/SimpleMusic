import Foundation

/// 用户偏好在 UserDefaults 系统存储 API 上的窄封装，跨实例读取同一套设置。
struct SettingsStore {
    private enum Key {
        static let cellular = "allowsCellularDownloads"
        static let autoPlay = "autoPlayAfterDownload"
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
}
