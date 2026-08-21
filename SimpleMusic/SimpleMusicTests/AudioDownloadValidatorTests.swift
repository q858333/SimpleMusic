import AudioToolbox
import Foundation
import XCTest
@testable import SimpleMusic

final class AudioDownloadValidatorTests: XCTestCase {
    func testRejectsWebPageAndAcceptsAudioDirectLink() throws {
        let validator = AudioDownloadValidator()

        XCTAssertThrowsError(try validator.validate(url: URL(string: "https://example.com/page")!))
        XCTAssertNoThrow(try validator.validate(url: URL(string: "https://example.com/song.m4a")!))
    }

    func testResponseMustHaveMatchingAudioMime() throws {
        let url = URL(string: "https://example.com/song.mp3")!
        let html = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!

        XCTAssertThrowsError(try AudioDownloadValidator().validate(response: html, sourceURL: url))
    }

    func testRejectsNonSuccessfulHTTPStatus() throws {
        let url = URL(string: "https://example.com/song.mp3")!
        let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!

        XCTAssertThrowsError(try AudioDownloadValidator().validate(response: response, sourceURL: url))
    }

    func testRejectsResponseWithoutContentType() throws {
        let url = URL(string: "https://example.com/song.mp3")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!

        XCTAssertThrowsError(try AudioDownloadValidator().validate(response: response, sourceURL: url))
    }

    func testRejectsNonHTTPSURLs() throws {
        let validator = AudioDownloadValidator()

        XCTAssertThrowsError(try validator.validate(url: URL(string: "file:///tmp/song.mp3")!))
        XCTAssertThrowsError(try validator.validate(url: URL(string: "ftp://example.com/song.mp3")!))
    }

    func testSuccessfulResponseRequiresSupportedURLAndAudioMime() throws {
        let url = URL(string: "https://example.com/song.wav")!
        let audio = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])!

        XCTAssertNoThrow(try AudioDownloadValidator().validate(response: audio, sourceURL: url))
    }

    /// 如果下载入口仍维护少量手写扩展名，系统新增或已有的可读音频格式会被错误拒绝。
    func testAcceptsEveryAudioFileExtensionRecognizedBySystem() throws {
        let extensions = try systemAudioStrings(for: kAudioFileGlobalInfo_AllExtensions)
        XCTAssertFalse(extensions.isEmpty)

        for pathExtension in extensions {
            let url = try XCTUnwrap(URL(string: "https://example.com/song.\(pathExtension)"))
            XCTAssertNoThrow(
                try AudioDownloadValidator().validate(url: url),
                "应支持系统识别的 .\(pathExtension) 音频文件"
            )
        }
    }

    /// 如果响应校验仍只接受 mp3/m4a/wav MIME，其余系统可读音频会在落盘验证前被拦截。
    func testAcceptsEveryAudioMIMETypeRecognizedBySystem() throws {
        let mimeTypes = try systemAudioStrings(for: kAudioFileGlobalInfo_AllMIMETypes)
        XCTAssertFalse(mimeTypes.isEmpty)
        let url = try XCTUnwrap(URL(string: "https://example.com/song.mp3"))

        for mimeType in mimeTypes {
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": mimeType]
            ))
            XCTAssertNoThrow(
                try AudioDownloadValidator().validate(response: response, sourceURL: url),
                "应支持系统识别的 \(mimeType) 音频响应"
            )
        }
    }

    func testRejectsVideoMIMEForSystemContainerExtension() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/movie.mp4"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "video/mp4"]
        ))

        XCTAssertThrowsError(
            try AudioDownloadValidator().validate(response: response, sourceURL: url)
        )
    }

    private func systemAudioStrings(for property: AudioFilePropertyID) throws -> [String] {
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
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(values?.takeRetainedValue() as? [String])
    }
}
