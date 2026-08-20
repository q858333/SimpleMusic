import CoreData
import MediaPlayer
import UIKit

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settingsStore = SettingsStore(defaults: .standard)
    let musicLibraryService = MusicLibraryService()
    private var libraryChangeObserver: MusicLibraryChangeObserver?
    private var localMusicCatalog: LocalMusicCatalog?
    private lazy var downloadStorageResolution = DownloadStorageFactory().resolve()

    lazy var localMusicStore: LocalMusicStore = {
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            return LocalMusicStore(container: appDelegate.persistentContainer)
        }
        // 单元测试或非常规生命周期下仍使用内存索引，不伪装成持久数据。
        return LocalMusicStore(container: Self.makeInMemoryContainer())
    }()

    var downloadFileStore: DownloadFileStore? { downloadStorageResolution.store }
    var downloadStorageWarning: String? { downloadStorageResolution.warning }

    lazy var downloadManager: DownloadManager? = {
        guard let downloadFileStore else { return nil }
        return DownloadManager(
            fileStore: downloadFileStore,
            musicStore: localMusicStore,
            settingsStore: settingsStore
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
