import MediaPlayer
import Combine
import UIKit
import XCTest
@testable import SimpleMusic

@MainActor
final class DownloadAndSettingsFlowTests: XCTestCase {
    func testDownloadStateShowsOnlyItsMatchingView() throws {
        let harness = makeDownloadHarness()
        let controller = harness.controller
        controller.loadViewIfNeeded()

        assertVisibleState("input", in: controller)

        controller.state = .downloading(progress: 0.42)
        assertVisibleState("downloading", in: controller)

        controller.state = .success(track(id: "finished"))
        assertVisibleState("success", in: controller)

        controller.state = .failure(message: "无法下载")
        assertVisibleState("failure", in: controller)
    }

    func testDownloadInputUsesURLKeyboardReturnKeyAndMinimumTouchTargets() throws {
        let harness = makeDownloadHarness()
        let controller = harness.controller
        controller.loadViewIfNeeded()
        let field = try XCTUnwrap(view("download.url", in: controller.view) as? UITextField)
        let buttons = allViews(in: controller.view).compactMap { $0 as? UIButton }

        XCTAssertEqual(field.keyboardType, .URL)
        XCTAssertEqual(field.returnKeyType, .go)
        XCTAssertTrue(controller.textFieldShouldReturn(field))
        XCTAssertFalse(buttons.isEmpty)
        XCTAssertTrue(buttons.allSatisfy { hasMinimumHeight(44, view: $0) })
    }

    func testSubmittingTwiceStartsOnlyOneDownloadAndProgressUpdatesState() throws {
        let operation = ControlledDownloadOperation()
        let harness = makeDownloadHarness(operation: operation)
        harness.controller.loadViewIfNeeded()
        try setURL("https://example.com/song.mp3", in: harness.controller)

        try tap("download.submit", in: harness.controller)
        try tap("download.submit", in: harness.controller)
        waitUntil { operation.callCount == 1 }
        operation.reportProgress(0.65, at: 0)

        XCTAssertEqual(operation.callCount, 1)
        XCTAssertEqual(harness.controller.state, .downloading(progress: 0.65))
        operation.succeed(track: Self.track(id: "finished"), at: 0)
        waitUntil { harness.controller.state == .success(Self.track(id: "finished")) }
    }

    func testManagerOwnsURLValidationBoundary() throws {
        var receivedURL: URL?
        let harness = makeDownloadHarness { url, _ in
            receivedURL = url
            throw DownloadError.unsupportedURL
        }
        harness.controller.loadViewIfNeeded()
        try setURL("https://example.com/not-a-file", in: harness.controller)

        try tap("download.submit", in: harness.controller)
        waitUntil {
            if case .failure = harness.controller.state { return true }
            return false
        }

        XCTAssertEqual(receivedURL?.absoluteString, "https://example.com/not-a-file")
    }

    func testCancelThenNewSubmitIgnoresOldProgressAndCompletion() throws {
        let operation = ControlledDownloadOperation()
        let harness = makeDownloadHarness(operation: operation)
        harness.controller.loadViewIfNeeded()
        try setURL("https://example.com/old.mp3", in: harness.controller)
        try tap("download.submit", in: harness.controller)
        waitUntil { operation.callCount == 1 }

        try tap("download.cancel", in: harness.controller)
        XCTAssertEqual(harness.controller.state, .input)
        waitUntil { operation.cancellationCount == 1 }

        try setURL("https://example.com/new.mp3", in: harness.controller)
        try tap("download.submit", in: harness.controller)
        waitUntil { operation.callCount == 2 }
        operation.reportProgress(0.9, at: 0)
        operation.succeed(track: track(id: "old"), at: 0)
        waitUntil { operation.completionCount == 1 }

        XCTAssertEqual(harness.controller.state, .downloading(progress: 0))
        XCTAssertEqual(harness.reloadCount(), 0)
        XCTAssertTrue(harness.playedTracks().isEmpty)

        operation.succeed(track: track(id: "new"), at: 1)
        waitUntil { harness.controller.state == .success(Self.track(id: "new")) }
        XCTAssertEqual(harness.reloadCount(), 1)
    }

    func testSuccessfulDownloadStaysUntilImmediatePlayWhenAutoPlayIsOff() throws {
        let harness = makeDownloadHarness { _, _ in Self.track(id: "manual") }
        harness.controller.loadViewIfNeeded()
        try setURL("https://example.com/manual.m4a", in: harness.controller)

        try tap("download.submit", in: harness.controller)
        waitUntil { harness.controller.state == .success(Self.track(id: "manual")) }

        XCTAssertEqual(harness.reloadCount(), 1)
        XCTAssertTrue(harness.playedTracks().isEmpty)
        try tap("download.play", in: harness.controller)
        XCTAssertEqual(harness.playedTracks().map(\.id), ["manual"])
    }

    func testSuccessfulDownloadAutoPlaysWhenSettingIsOn() throws {
        let harness = makeDownloadHarness(autoPlay: true) { _, _ in Self.track(id: "automatic") }
        harness.controller.loadViewIfNeeded()
        try setURL("https://example.com/automatic.wav", in: harness.controller)

        try tap("download.submit", in: harness.controller)
        waitUntil { harness.playedTracks().count == 1 }

        XCTAssertEqual(harness.reloadCount(), 1)
        XCTAssertEqual(harness.playedTracks().map(\.id), ["automatic"])
    }

    func testSettingsSwitchesReadAndWriteSettingsStore() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = SettingsStore(defaults: defaults)
        store.allowsCellularDownloads = true
        let controller = makeSettingsController(settingsStore: store, status: { .authorized })
        controller.loadViewIfNeeded()
        let cellular = try XCTUnwrap(view("settings.cellular", in: controller.view) as? UISwitch)
        let autoPlay = try XCTUnwrap(view("settings.autoplay", in: controller.view) as? UISwitch)

        XCTAssertTrue(cellular.isOn)
        XCTAssertFalse(autoPlay.isOn)
        cellular.isOn = false
        cellular.sendActions(for: .valueChanged)
        autoPlay.isOn = true
        autoPlay.sendActions(for: .valueChanged)

        XCTAssertFalse(store.allowsCellularDownloads)
        XCTAssertTrue(store.autoPlayAfterDownload)
    }

    func testPermissionActionRequestsFirstTimeAndOpensSettingsWhenDenied() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        var status = MPMediaLibraryAuthorizationStatus.notDetermined
        var requestCount = 0
        var openSettingsCount = 0
        let controller = SettingsViewController(
            settingsStore: SettingsStore(defaults: defaults),
            authorizationStatus: { status },
            requestAuthorization: {
                requestCount += 1
                status = .denied
                return .denied
            },
            openSettings: { openSettingsCount += 1 }
        )
        controller.loadViewIfNeeded()

        try tap("settings.permission", in: controller)
        waitUntil { requestCount == 1 }
        XCTAssertEqual(openSettingsCount, 0)

        try tap("settings.permission", in: controller)
        XCTAssertEqual(openSettingsCount, 1)
    }

    func testSettingsUsesRealSwitchesDynamicTypeAndAboutContentIsFixed() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let settings = makeSettingsController(
            settingsStore: SettingsStore(defaults: defaults),
            status: { .restricted }
        )
        settings.loadViewIfNeeded()
        let switches = allViews(in: settings.view).compactMap { $0 as? UISwitch }
        let labels = allViews(in: settings.view).compactMap { $0 as? UILabel }

        XCTAssertEqual(switches.count, 2)
        XCTAssertTrue(labels.filter { $0.text != nil }.allSatisfy(\.adjustsFontForContentSizeCategory))

        let about = AboutViewController()
        about.loadViewIfNeeded()
        let copy = allViews(in: about.view).compactMap { ($0 as? UILabel)?.text }.joined(separator: " ")
        XCTAssertTrue(copy.contains("MP3、M4A、WAV"))
        XCTAssertTrue(copy.contains("仅保存在本机"))
        XCTAssertTrue(copy.contains("不解析音乐平台或普通网页链接"))
    }

    func testRootFactoryWiresDownloadAndSettingsIntoTheSharedLibraryController() throws {
        let viewModel = LibraryViewModel(
            library: FlowStubMusicLibrary(),
            localStore: FlowStubLocalMusicStore()
        )
        var downloadFactoryCount = 0
        var settingsFactoryCount = 0
        let dependencies = AppRootDependencies(
            identity: NSObject(),
            libraryViewModel: viewModel,
            snapshotPublisher: Empty<PlaybackSnapshot, Never>().eraseToAnyPublisher(),
            onPlay: { _, _ in },
            onTogglePlay: {},
            makeDownloadViewController: {
                downloadFactoryCount += 1
                return UIViewController()
            },
            makeSettingsViewController: {
                settingsFactoryCount += 1
                return UIViewController()
            }
        )
        let root = AppCoordinator.makeMainViewControllerFactory(dependencies: dependencies)(.phone)
        root.loadViewIfNeeded()
        let library = try XCTUnwrap(descendant(LibraryViewController.self, in: root))

        XCTAssertTrue(library.viewModel === viewModel)
        try XCTUnwrap(library.onDownload)()
        try XCTUnwrap(library.onSettings)()
        XCTAssertEqual(downloadFactoryCount, 1)
        XCTAssertEqual(settingsFactoryCount, 1)
    }

    private func makeDownloadHarness(
        autoPlay: Bool = false,
        operation: ControlledDownloadOperation? = nil,
        download: DownloadSheetViewController.DownloadOperation? = nil
    ) -> DownloadHarness {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = SettingsStore(defaults: defaults)
        store.autoPlayAfterDownload = autoPlay
        var reloadCount = 0
        var playedTracks = [SimpleMusic.MusicTrack]()
        let resolvedDownload: DownloadSheetViewController.DownloadOperation
        if let download {
            resolvedDownload = download
        } else if let operation {
            resolvedDownload = { url, progress in try await operation.perform(url: url, progress: progress) }
        } else {
            resolvedDownload = { _, _ in Self.track(id: "default") }
        }
        let controller = DownloadSheetViewController(
            download: resolvedDownload,
            settingsStore: store,
            onReload: { reloadCount += 1 },
            onPlay: { playedTracks.append($0) }
        )
        return DownloadHarness(
            controller: controller,
            reloadCount: { reloadCount },
            playedTracks: { playedTracks }
        )
    }

    private func makeDownloadHarness(
        autoPlay: Bool = false,
        download: @escaping DownloadSheetViewController.DownloadOperation
    ) -> DownloadHarness {
        makeDownloadHarness(autoPlay: autoPlay, operation: nil, download: download)
    }

    private func makeSettingsController(
        settingsStore: SettingsStore,
        status: @escaping () -> MPMediaLibraryAuthorizationStatus
    ) -> SettingsViewController {
        SettingsViewController(
            settingsStore: settingsStore,
            authorizationStatus: status,
            requestAuthorization: { status() },
            openSettings: {}
        )
    }

    private func assertVisibleState(
        _ expected: String,
        in controller: DownloadSheetViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for name in ["input", "downloading", "success", "failure"] {
            let stateView = view("download.state.\(name)", in: controller.view)
            XCTAssertEqual(stateView?.isHidden, name != expected, "state=\(name)", file: file, line: line)
        }
    }

    private func setURL(_ value: String, in controller: DownloadSheetViewController) throws {
        let field = try XCTUnwrap(view("download.url", in: controller.view) as? UITextField)
        field.text = value
    }

    private func tap(_ identifier: String, in controller: UIViewController) throws {
        let button = try XCTUnwrap(view(identifier, in: controller.view) as? UIButton)
        button.sendActions(for: .touchUpInside)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(predicate(), "异步状态未在 \(timeout) 秒内完成")
    }

    private static func track(id: String) -> SimpleMusic.MusicTrack {
        SimpleMusic.MusicTrack(
            id: id,
            title: id,
            artist: "artist",
            album: "album",
            duration: 30,
            artworkData: nil,
            source: .downloaded(fileName: "\(id).mp3")
        )
    }

    private func track(id: String) -> SimpleMusic.MusicTrack { Self.track(id: id) }
}

@MainActor
private final class FlowStubMusicLibrary: MusicLibraryLoading {
    var authorizationStatus: MPMediaLibraryAuthorizationStatus = .denied
    func loadTracks() async throws -> [SimpleMusic.MusicTrack] { [] }
}

private final class FlowStubLocalMusicStore: LocalMusicLoading {
    func loadTracks() async throws -> [SimpleMusic.MusicTrack] { [] }
}

@MainActor
private final class ControlledDownloadOperation {
    typealias Progress = @MainActor @Sendable (Double) -> Void

    private var continuations = [CheckedContinuation<SimpleMusic.MusicTrack, Error>]()
    private var progressHandlers = [Progress]()
    private(set) var callCount = 0
    private(set) var completionCount = 0
    private(set) var cancellationCount = 0

    func perform(url: URL, progress: @escaping Progress) async throws -> SimpleMusic.MusicTrack {
        callCount += 1
        let index = callCount - 1
        progressHandlers.append(progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, index < continuations.count else { return }
                cancellationCount += 1
            }
        }
    }

    func reportProgress(_ value: Double, at index: Int) {
        progressHandlers[index](value)
    }

    func succeed(track: SimpleMusic.MusicTrack, at index: Int) {
        completionCount += 1
        continuations[index].resume(returning: track)
    }
}

private struct DownloadHarness {
    let controller: DownloadSheetViewController
    let reloadCount: () -> Int
    let playedTracks: () -> [SimpleMusic.MusicTrack]
}

private func view(_ identifier: String, in root: UIView) -> UIView? {
    if root.accessibilityIdentifier == identifier { return root }
    for child in root.subviews {
        if let match = view(identifier, in: child) { return match }
    }
    return nil
}

private func allViews(in root: UIView) -> [UIView] {
    [root] + root.subviews.flatMap(allViews)
}

private func hasMinimumHeight(_ value: CGFloat, view: UIView) -> Bool {
    view.constraints.contains {
        $0.firstItem === view
            && $0.firstAttribute == .height
            && ($0.relation == .greaterThanOrEqual || $0.relation == .equal)
            && $0.constant >= value
    }
}

private func descendant<T: UIViewController>(_: T.Type, in root: UIViewController) -> T? {
    if let match = root as? T { return match }
    for child in root.children {
        if let match = descendant(T.self, in: child) { return match }
    }
    return nil
}
