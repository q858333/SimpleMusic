import Foundation

/// 音乐条目的稳定展示与播放标识；媒体库或本地文件的读取由上层服务负责。
enum MusicSource: Hashable, Codable {
    /// 持久 ID 是系统媒体库 API 的边界，避免在领域模型中持有系统对象。
    case system(persistentID: UInt64)
    case downloaded(fileName: String)
}

/// 播放队列、下载列表和详情页共用的歌曲值类型。
struct MusicTrack: Identifiable, Hashable, Codable {
    static let unknownArtist = "未知艺人"
    static let unknownAlbum = "未知专辑"

    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let artworkData: Data?
    let source: MusicSource
}
