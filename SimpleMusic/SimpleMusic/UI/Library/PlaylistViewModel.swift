import Combine
import Foundation

/// 将播放列表歌曲 ID 按当前统一资料库解析，列表项不持有歌曲元数据快照。
@MainActor
final class PlaylistViewModel {
    @Published private(set) var playlists: [Playlist]
    @Published private(set) var resolutionRevision: UInt64 = 0

    private let store: PlaylistStore
    private let library: LibraryViewModel
    private var libraryTracks: [MusicTrack]
    private var knownSourcesByTrackID = [String: MusicSourceKind]()
    private var cancellables = Set<AnyCancellable>()

    init(store: PlaylistStore, library: LibraryViewModel) throws {
        self.store = store
        self.library = library
        libraryTracks = library.tracks
        playlists = try store.fetchPlaylists()
        library.$tracks
            .sink { [weak self] tracks in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.libraryTracks = tracks
                    self.recordSources(in: tracks)
                    self.resolutionRevision &+= 1
                }
            }
            .store(in: &cancellables)
        library.$completedReload
            .compactMap { $0 }
            .sink { [weak self] completion in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.removeMissingTrackIDs(using: completion)
                }
            }
            .store(in: &cancellables)
    }

    func tracks(for playlistID: String) -> [MusicTrack] {
        guard let playlist = playlists.first(where: { $0.id == playlistID }) else { return [] }
        var tracksByID = [String: MusicTrack]()
        for track in libraryTracks {
            tracksByID[track.id] = track
        }
        return playlist.trackIDs.compactMap { tracksByID[$0] }
    }

    @discardableResult
    func createPlaylist(named name: String) throws -> Playlist {
        let playlist = try store.create(name: name)
        try refreshPlaylists()
        return playlist
    }

    func renamePlaylist(id: String, name: String) throws {
        try store.rename(id: id, name: name)
        try refreshPlaylists()
    }

    func deletePlaylist(id: String) throws {
        try store.delete(id: id)
        try refreshPlaylists()
    }

    func add(_ track: MusicTrack, to playlistID: String) throws {
        try store.add(trackID: track.id, to: playlistID)
        try refreshPlaylists()
    }

    private func removeMissingTrackIDs(using completion: LibraryReloadCompletion) {
        if let systemTrackIDs = completion.systemTrackIDs {
            for trackID in systemTrackIDs {
                knownSourcesByTrackID[trackID] = .system
            }
        }
        if let localTrackIDs = completion.localTrackIDs {
            for trackID in localTrackIDs {
                knownSourcesByTrackID[trackID] = .local
            }
        }

        let availableTrackIDs = (completion.systemTrackIDs ?? [])
            .union(completion.localTrackIDs ?? [])
        let missingTrackIDs = Set(playlists.flatMap(\.trackIDs)).filter { trackID in
            guard availableTrackIDs.contains(trackID) == false else { return false }
            switch sourceKind(for: trackID) {
            case .system:
                return completion.systemTrackIDs != nil
            case .local:
                return completion.localTrackIDs != nil
            case nil:
                return completion.systemTrackIDs != nil && completion.localTrackIDs != nil
            }
        }
        guard missingTrackIDs.isEmpty == false else { return }

        do {
            try store.removeMissingTrackIDs(Array(missingTrackIDs))
            try refreshPlaylists()
        } catch {
            NSLog("播放列表失效歌曲清理失败：%@", String(describing: error))
        }
    }

    private func recordSources(in tracks: [MusicTrack]) {
        for track in tracks {
            switch track.source {
            case .system:
                knownSourcesByTrackID[track.id] = .system
            case .downloaded:
                knownSourcesByTrackID[track.id] = .local
            }
        }
    }

    private func sourceKind(for trackID: String) -> MusicSourceKind? {
        if let knownSource = knownSourcesByTrackID[trackID] {
            return knownSource
        }
        if trackID.hasPrefix("system-"), UInt64(trackID.dropFirst("system-".count)) != nil {
            return .system
        }
        if UUID(uuidString: trackID) != nil {
            return .local
        }
        return nil
    }

    private func refreshPlaylists() throws {
        playlists = try store.fetchPlaylists()
    }
}

private enum MusicSourceKind {
    case system
    case local
}
