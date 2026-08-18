import MediaPlayer
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

    lazy var nowPlayingService = NowPlayingService(
        snapshotPublisher: playbackCoordinator.snapshotPublisher,
        commands: SystemRemoteCommandRegister(),
        infoCenter: MPNowPlayingInfoCenter.default(),
        audioSession: SystemPlaybackAudioSession(),
        controls: NowPlayingControls(
            play: { [playbackCoordinator] in playbackCoordinator.togglePlay() },
            pause: { [playbackCoordinator] in playbackCoordinator.togglePlay() },
            next: { [playbackCoordinator] in try playbackCoordinator.next() },
            previous: { [playbackCoordinator] in try playbackCoordinator.previous() },
            seek: { [playbackCoordinator] elapsed in playbackCoordinator.seek(to: elapsed) }
        )
    )

    private init() {
        do {
            try nowPlayingService.start()
        } catch {
            // 后台音频不是应用启动前提；保留前台播放器并记录系统会话失败以便诊断。
            NSLog("后台音频服务启动失败：%@", String(describing: error))
        }
    }
}
