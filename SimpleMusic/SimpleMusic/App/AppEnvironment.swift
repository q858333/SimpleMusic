import CoreData
import MediaPlayer
import UIKit

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settingsStore = SettingsStore(defaults: .standard)
    let deviceIdentifierService = DeviceIdentifierService()
    let downloadNetworkMonitor = DownloadNetworkMonitor()
    let musicLibraryService = MusicLibraryService()
    private let appConfigurationService: AppConfigurationService
    private var libraryChangeObserver: MusicLibraryChangeObserver?
    private var localMusicCatalog: LocalMusicCatalog?
    private let injectedDownloadStorageResolution: DownloadStorageResolution?
    private lazy var downloadStorageResolution = injectedDownloadStorageResolution
        ?? DownloadStorageFactory().resolve()
    private lazy var libraryPersistentContainer: NSPersistentContainer = {
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            return appDelegate.persistentContainer
        }
        // 单元测试或非常规生命周期下，本地歌曲与播放列表仍共用同一内存索引。
        return Self.makeInMemoryContainer()
    }()

    lazy var localMusicStore: LocalMusicStore = {
        LocalMusicStore(container: libraryPersistentContainer)
    }()

    lazy var playlistStore = PlaylistStore(container: libraryPersistentContainer)

    var downloadFileStore: DownloadFileStore? { downloadStorageResolution.store }
    var downloadStorageWarning: String? { downloadStorageResolution.warning }
    /// 所有下载 UI 共用服务端下发的能力开关；默认关闭，网络失败时保留当前值。
    private(set) var downloadFeatureEnabled = false

    lazy var downloadManager: DownloadManager? = {
        guard let downloadFileStore else { return nil }
        return DownloadManager(
            fileStore: downloadFileStore,
            musicStore: localMusicStore,
            settingsStore: settingsStore,
            networkStatusProvider: downloadNetworkMonitor
        )
    }()

    lazy var downloadQueue: DownloadQueue? = {
        guard let downloadManager, let downloadFileStore else { return nil }
        let store: DownloadQueueStore
        do {
            store = try .applicationSupport()
        } catch {
            NSLog("下载队列账本不可用，改用内存状态：%@", String(describing: error))
            store = DownloadQueueStore(fileURL: nil)
        }
        let recovery = DownloadRecoveryService(
            fileStore: downloadFileStore,
            musicStore: localMusicStore
        )
        do {
            try recovery.cleanupRetainedTemporaryFiles()
        } catch {
            NSLog("下载临时文件清理失败：%@", String(describing: error))
        }
        return DownloadQueue(
            store: store,
            operation: { url, progress, onReservation in
                try await downloadManager.download(
                    from: url,
                    progress: progress,
                    onReservation: onReservation
                )
            },
            settingsStore: settingsStore,
            recovery: recovery.reconcile(fileName:),
            onReload: { [weak libraryViewModel] in
                Task { await libraryViewModel?.requestReload() }
            },
            onPlay: { [playbackCoordinator] track in
                try? playbackCoordinator.play(queue: [track], startAt: 0)
            }
        )
    }()

    lazy var libraryViewModel: LibraryViewModel = {
        let localSource: any LocalMusicLoading
        let deleteLocalTrack: (@MainActor @Sendable (MusicTrack) async throws -> Void)?
        if let downloadFileStore {
            let catalog = LocalMusicCatalog(
                musicStore: localMusicStore,
                fileStore: downloadFileStore
            )
            localMusicCatalog = catalog
            localSource = catalog
            deleteLocalTrack = { track in
                try await catalog.delete(track)
            }
        } else {
            localSource = UnavailableLocalMusicSource(
                message: downloadStorageWarning ?? L10n.text("storage.download.unavailable_short")
            )
            deleteLocalTrack = nil
        }
        let viewModel = LibraryViewModel(
            library: musicLibraryService,
            localStore: localSource,
            storageWarning: (UIApplication.shared.delegate as? AppDelegate)?.persistentStoreWarning,
            deleteLocalTrack: deleteLocalTrack
        )
        libraryChangeObserver = MusicLibraryChangeObserver { [weak viewModel] in
            Task { await viewModel?.requestReload() }
        }
        return viewModel
    }()

    lazy var playlistViewModel: PlaylistViewModel = {
        do {
            return try PlaylistViewModel(store: playlistStore, library: libraryViewModel)
        } catch {
            fatalError("播放列表初始化失败：\(error)")
        }
    }()

    lazy var playbackCoordinator = PlaybackCoordinator(
        localBackend: LocalPlaybackBackend(fileStore: downloadFileStore),
        systemBackend: SystemPlaybackBackend(libraryService: musicLibraryService),
        initialAudioEffectSettings: settingsStore.audioEffectSettings
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

    init(
        downloadStorageResolution: DownloadStorageResolution? = nil,
        appConfigurationService: AppConfigurationService? = nil
    ) {
        injectedDownloadStorageResolution = downloadStorageResolution
        self.appConfigurationService = appConfigurationService ?? AppConfigurationService()
        // 下载偏好已从设置页移除：统一恢复为可使用蜂窝网络，且完成后不打断当前播放。
        settingsStore.allowsCellularDownloads = true
        settingsStore.autoPlayAfterDownload = false
        do {
            try nowPlayingService.start()
        } catch {
            // 后台音频不是应用启动前提；保留前台播放器并记录系统会话失败以便诊断。
            NSLog("后台音频服务启动失败：%@", String(describing: error))
        }
    }

    /// 返回安装首次运行时由 IDFV 生成并缓存到钥匙串的稳定设备号。
    func deviceIdentifier() throws -> String {
        try deviceIdentifierService.deviceIdentifier()
    }

    /// 返回本次启动由 APNs 回调的最新 Token；回调前为 nil。
    var apnsDeviceToken: String? {
        APNsTokenStore.shared.currentToken
    }

    /// 冷启动完成配置请求；只有开关改变时才要求根界面重新构造。
    func refreshRemoteConfiguration() async -> Bool {
        do {
            let downloadsEnabled = try await appConfigurationService.fetch().downloadsEnabled
            let changed = downloadFeatureEnabled != downloadsEnabled
            downloadFeatureEnabled = downloadsEnabled
            return changed
        } catch {
            NSLog("应用配置拉取失败：%@", String(describing: error))
            return false
        }
    }

    private static func makeInMemoryContainer() -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "SimpleMusic")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error {
                NSLog("内存索引初始化失败：%@", String(describing: error))
            }
        }
        return container
    }
}

private final class UnavailableLocalMusicSource: LocalMusicLoading {
    let message: String

    init(message: String) {
        self.message = message
    }

    func loadTracks() async throws -> [MusicTrack] {
        throw DownloadCapabilityError(message: message)
    }
}

private struct DownloadCapabilityError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
