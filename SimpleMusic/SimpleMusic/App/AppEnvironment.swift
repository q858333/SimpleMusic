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

    lazy var downloadFileStore: DownloadFileStore = {
        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Downloads", isDirectory: true)
            return try DownloadFileStore(rootURL: root)
        } catch {
            fatalError("无法创建下载目录：\(error)")
        }
    }()

    lazy var downloadManager: DownloadManager = {
        DownloadManager(
            fileStore: downloadFileStore,
            musicStore: localMusicStore,
            settingsStore: settingsStore
        )
    }()

    lazy var playbackCoordinator = PlaybackCoordinator(
        localBackend: LocalPlaybackBackend(fileStore: downloadFileStore),
        systemBackend: SystemPlaybackBackend(libraryService: musicLibraryService)
    )

    private init() {}
}
