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
}
