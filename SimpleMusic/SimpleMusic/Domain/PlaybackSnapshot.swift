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

/// 本地歌曲可用的系统混响预设；`off` 保留原始音频输出。
nonisolated enum AudioEffectPreset: String, CaseIterable, Equatable, Sendable {
    case off
    case smallRoom
    case mediumRoom
    case largeRoom
    case mediumHall
    case largeHall
    case cathedral
    case plate
}

/// 混响参数使用 0...100 的百分比，便于直接绑定 UIKit 滑块和持久化。
nonisolated struct AudioEffectSettings: Equatable, Sendable {
    var preset: AudioEffectPreset
    var wetDryMix: Float

    init(preset: AudioEffectPreset = .off, wetDryMix: Float = 35) {
        self.preset = preset
        self.wetDryMix = min(100, max(0, wetDryMix))
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
    var audioEffectSettings = AudioEffectSettings()
    var queue = [MusicTrack]()
}
