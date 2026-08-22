import Foundation

/// 播放器向界面暴露的状态，失败时保留原因以便显示或记录。
enum PlaybackStatus: Equatable {
    case idle
    case loading
    case playing
    case paused
    case failed(String)
}

/// 当前队列的自动推进方式；手动上一首和下一首始终按可见队列移动。
enum PlaybackMode: Equatable {
    case list
    case repeatOne
    case shuffle

    var next: PlaybackMode {
        switch self {
        case .list: return .repeatOne
        case .repeatOne: return .shuffle
        case .shuffle: return .list
        }
    }
}

/// 单次播放状态快照；切歌后由播放器同时更新歌曲、进度与队列位置。
struct PlaybackSnapshot: Equatable {
    var status: PlaybackStatus = .idle
    var track: MusicTrack?
    var elapsed: TimeInterval = 0
    var duration: TimeInterval = 0
    var queueIndex: Int?
    var queueCount = 0
    var playbackMode: PlaybackMode = .list
    var queue = [MusicTrack]()
}
