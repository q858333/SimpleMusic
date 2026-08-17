import UIKit

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settingsStore = SettingsStore(defaults: .standard)
    let musicLibraryService = MusicLibraryService()

    lazy var localMusicStore: LocalMusicStore = {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
            fatalError("应用启动后才能创建本地音乐索引")
        }
        return LocalMusicStore(container: appDelegate.persistentContainer)
    }()

    lazy var downloadManager: DownloadManager = {
        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Downloads", isDirectory: true)
            return DownloadManager(
                fileStore: try DownloadFileStore(rootURL: root),
                musicStore: localMusicStore,
                settingsStore: settingsStore
            )
        } catch {
            fatalError("无法创建下载目录：\(error)")
        }
    }()

    private init() {}
}
