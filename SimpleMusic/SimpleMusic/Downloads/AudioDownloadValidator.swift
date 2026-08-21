import AudioToolbox
import Foundation

/// 下载边界拒绝的 URL 或响应类型。
enum DownloadError: Error {
    case unsupportedURL
    case unsupportedResponse
}

/// 下载入口的媒体类型白名单，隔离网页链接和未验证的网络响应。
struct AudioDownloadValidator {
    /// 由当前系统的 Audio File Services 提供可读音频类型，避免手写列表遗漏格式。
    static let extensions = systemAudioStrings(for: kAudioFileGlobalInfo_AllExtensions)
    static let mimeTypes = systemAudioStrings(for: kAudioFileGlobalInfo_AllMIMETypes)

    func validate(url: URL) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              Self.extensions.contains(url.pathExtension.lowercased()) else {
            throw DownloadError.unsupportedURL
        }
    }

    /// 响应必须与原始直链和音频 MIME 同时匹配，不能仅因扩展名而信任内容。
    func validate(response: URLResponse, sourceURL: URL) throws {
        try validate(url: sourceURL)

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let mime = http.mimeType?.lowercased(),
              Self.mimeTypes.contains(mime) else {
            throw DownloadError.unsupportedResponse
        }
    }

    private static func systemAudioStrings(for property: AudioFilePropertyID) -> Set<String> {
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        var values: Unmanaged<CFArray>?
        let status = withUnsafeMutablePointer(to: &values) { pointer in
            AudioFileGetGlobalInfo(
                property,
                0,
                nil,
                &dataSize,
                UnsafeMutableRawPointer(pointer)
            )
        }
        guard status == noErr,
              let strings = values?.takeRetainedValue() as? [String] else {
            return []
        }
        return Set(strings.map { $0.lowercased() })
    }
}
