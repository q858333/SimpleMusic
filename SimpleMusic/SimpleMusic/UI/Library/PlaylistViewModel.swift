import Combine
import Foundation

/// 将播放列表歌曲 ID 按当前统一资料库解析，列表项不持有歌曲元数据快照。
@MainActor
final class PlaylistViewModel {
    @Published private(set) var playlists: [Playlist]

    private let store: PlaylistStore
    private let library: LibraryViewModel
    private var tracksCancellable: AnyCancellable?

    init(store: PlaylistStore, library: LibraryViewModel) throws {
        self.store = store
        self.library = library
        playlists = try store.fetchPlaylists()
        tracksCancellable = library.$tracks
            .dropFirst()
            .sink { [weak self] tracks in
                MainActor.assumeIsolated {
                    self?.removeMissingTrackIDs(using: tracks)
                }
            }
    }

    func tracks(for playlistID: String) -> [MusicTrack] {
        guard let playlist = playlists.first(where: { $0.id == playlistID }) else { return [] }
        var tracksByID = [String: MusicTrack]()
        for track in library.tracks {
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

    private func removeMissingTrackIDs(using tracks: [MusicTrack]) {
        let availableTrackIDs = Set(tracks.map(\.id))
        let missingTrackIDs = Set(playlists.flatMap(\.trackIDs)).subtracting(availableTrackIDs)
        guard missingTrackIDs.isEmpty == false else { return }

        do {
            try store.removeMissingTrackIDs(Array(missingTrackIDs))
            try refreshPlaylists()
        } catch {
            NSLog("播放列表失效歌曲清理失败：%@", String(describing: error))
        }
    }

    private func refreshPlaylists() throws {
        playlists = try store.fetchPlaylists()
    }
}
