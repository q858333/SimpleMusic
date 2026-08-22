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
    case panoramicSurround
    case classicRock
    case dynamicElectronic
    case clearVocal
}

nonisolated enum AudioEffectFilterKind: Equatable, Sendable {
    case lowShelf
    case parametric
    case highShelf
}

nonisolated struct AudioEffectBandProfile: Equatable, Sendable {
    let kind: AudioEffectFilterKind
    let frequency: Float
    let bandwidth: Float
    let gain: Float
}

nonisolated enum AudioEffectReverbProfile: Equatable, Sendable {
    case smallRoom
    case mediumRoom
    case largeRoom
    case mediumHall
    case largeHall
    case cathedral
    case plate
}

nonisolated struct ResolvedAudioEffectProfile: Equatable, Sendable {
    let bands: [AudioEffectBandProfile]
    let reverb: AudioEffectReverbProfile?
    let wetDryMix: Float
}

nonisolated extension AudioEffectPreset {
    func resolvedProfile(intensity: Float) -> ResolvedAudioEffectProfile {
        let scale = min(100, max(0, intensity)) / 100
        let baseBands: [AudioEffectBandProfile]
        let reverb: AudioEffectReverbProfile?
        let maximumWetMix: Float

        switch self {
        case .off:
            return ResolvedAudioEffectProfile(bands: [], reverb: nil, wetDryMix: 0)
        case .panoramicSurround:
            baseBands = [
                .init(kind: .lowShelf, frequency: 120, bandwidth: 1, gain: 1.5),
                .init(kind: .parametric, frequency: 600, bandwidth: 1, gain: -1.5),
                .init(kind: .highShelf, frequency: 7_000, bandwidth: 1, gain: 2)
            ]
            reverb = .largeRoom
            maximumWetMix = 30
        case .classicRock:
            baseBands = [
                .init(kind: .lowShelf, frequency: 90, bandwidth: 1, gain: 3),
                .init(kind: .parametric, frequency: 300, bandwidth: 1, gain: -1),
                .init(kind: .parametric, frequency: 1_800, bandwidth: 1, gain: 2.5),
                .init(kind: .highShelf, frequency: 6_000, bandwidth: 1, gain: 2)
            ]
            reverb = .plate
            maximumWetMix = 12
        case .dynamicElectronic:
            baseBands = [
                .init(kind: .lowShelf, frequency: 70, bandwidth: 1, gain: 4),
                .init(kind: .parametric, frequency: 500, bandwidth: 1, gain: -2),
                .init(kind: .highShelf, frequency: 8_000, bandwidth: 1, gain: 3)
            ]
            reverb = .plate
            maximumWetMix = 16
        case .clearVocal:
            baseBands = [
                .init(kind: .parametric, frequency: 250, bandwidth: 1, gain: -2),
                .init(kind: .parametric, frequency: 2_500, bandwidth: 1, gain: 3),
                .init(kind: .highShelf, frequency: 6_000, bandwidth: 1, gain: 2)
            ]
            reverb = .smallRoom
            maximumWetMix = 8
        case .smallRoom, .mediumRoom, .largeRoom, .mediumHall, .largeHall, .cathedral, .plate:
            baseBands = []
            reverb = legacyReverbProfile
            maximumWetMix = 100
        }

        let bands = baseBands.map {
            AudioEffectBandProfile(
                kind: $0.kind,
                frequency: $0.frequency,
                bandwidth: $0.bandwidth,
                gain: $0.gain * scale
            )
        }
        return ResolvedAudioEffectProfile(
            bands: bands,
            reverb: reverb,
            wetDryMix: maximumWetMix * scale
        )
    }

    private var legacyReverbProfile: AudioEffectReverbProfile? {
        switch self {
        case .off, .panoramicSurround, .classicRock, .dynamicElectronic, .clearVocal:
            return nil
        case .smallRoom: return .smallRoom
        case .mediumRoom: return .mediumRoom
        case .largeRoom: return .largeRoom
        case .mediumHall: return .mediumHall
        case .largeHall: return .largeHall
        case .cathedral: return .cathedral
        case .plate: return .plate
        }
    }
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
