import Combine
import Foundation
import MediaPlayer

/// 系统资料库边界使用异步接口，便于刷新代次在来源读取悬挂时仍保持正确。
@MainActor
protocol MusicLibraryLoading: AnyObject {
    var authorizationStatus: MPMediaLibraryAuthorizationStatus { get }
    func loadTracks() async throws -> [MusicTrack]
}

/// 本地索引与页面隔离，测试和正式环境都只交换统一歌曲模型。
@MainActor
protocol LocalMusicLoading: AnyObject {
    func loadTracks() async throws -> [MusicTrack]
}

extension MusicLibraryService: MusicLibraryLoading {
    func loadTracks() async throws -> [MusicTrack] {
        try fetchTracks()
    }
}

extension LocalMusicStore: LocalMusicLoading {
    func loadTracks() async throws -> [MusicTrack] {
        try fetchTracks()
    }
}

enum LibrarySectionState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case permissionRequired
    case failed(String)
}

/// 汇总系统歌曲与下载歌曲；不拥有播放状态，只提供页面展示和本地搜索数据。
@MainActor
final class LibraryViewModel {
    @Published private(set) var tracks = [MusicTrack]()
    @Published private(set) var systemState: LibrarySectionState = .idle
    @Published private(set) var localState: LibrarySectionState = .idle

    private let library: any MusicLibraryLoading
    private let localStore: any LocalMusicLoading
    private var systemTracks = [MusicTrack]()
    private var localTracks = [MusicTrack]()
    private var reloadGeneration: UInt64 = 0

    init(library: any MusicLibraryLoading, localStore: any LocalMusicLoading) {
        self.library = library
        self.localStore = localStore
    }

    func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let isAuthorized = library.authorizationStatus == .authorized

        systemState = isAuthorized ? .loading : .permissionRequired
        localState = .loading

        let systemResult: Result<[MusicTrack], Error>?
        if isAuthorized {
            systemResult = await load { try await self.library.loadTracks() }
        } else {
            systemResult = nil
        }
        let localResult = await load { try await self.localStore.loadTracks() }

        // 较早刷新可以继续释放资源，但不能再改写新一代页面状态。
        guard generation == reloadGeneration else { return }

        if let systemResult {
            switch systemResult {
            case let .success(loadedTracks):
                systemTracks = loadedTracks
                systemState = loadedTracks.isEmpty ? .empty : .loaded
            case .failure:
                systemState = .failed("无法读取系统音乐资料库")
            }
        } else {
            systemTracks = []
        }

        switch localResult {
        case let .success(loadedTracks):
            localTracks = loadedTracks
            localState = loadedTracks.isEmpty ? .empty : .loaded
        case .failure:
            localState = .failed("无法读取已下载歌曲")
        }

        tracks = systemTracks + localTracks
    }

    func filter(query: String) -> [MusicTrack] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tracks }

        return tracks.filter { track in
            [track.title, track.artist, track.album].contains { value in
                value.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ) != nil
            }
        }
    }

    private func load(
        _ operation: @escaping @MainActor () async throws -> [MusicTrack]
    ) async -> Result<[MusicTrack], Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }
}
