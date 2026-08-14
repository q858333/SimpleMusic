import Foundation

/// 播放器向界面暴露的状态，失败时保留原因以便显示或记录。
enum PlaybackStatus: Equatable {
    case idle
    case loading
    case playing
    case paused
    case failed(String)
}

/// 单次播放状态快照；切歌后由播放器同时更新歌曲、进度与队列位置。
struct PlaybackSnapshot: Equatable {
    var status: PlaybackStatus = .idle
    var track: MusicTrack?
    var elapsed: TimeInterval = 0
    var duration: TimeInterval = 0
    var queueIndex: Int?
    var queueCount = 0
}
