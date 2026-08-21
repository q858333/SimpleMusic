import MediaPlayer
import Combine
import UIKit
import XCTest
@testable import SimpleMusic

@MainActor
final class DownloadAndSettingsFlowTests: XCTestCase {
    func testClosingAndReleasingSheetDoesNotCancelActiveQueueJob() throws {
        let operation = ControlledQueueDownloadOperation()
        let queue = makeQueue(operation: operation)
        weak var weakController: DownloadSheetViewController?

        try autoreleasepool {
            var controller: DownloadSheetViewController? = DownloadSheetViewController(downloadQueue: queue)
            weakController = controller
            controller?.loadViewIfNeeded()
            try submit("https://example.com/a.m4a", in: try XCTUnwrap(controller))
            waitUntil { operation.startedURLs.count == 1 }

            controller?.presentationControllerDidDismiss(UIPresentationController(
                presentedViewController: try XCTUnwrap(controller),
                presenting: nil
            ))
            controller = nil
        }

        XCTAssertNil(weakController)
        XCTAssertEqual(operation.cancellationCount, 0)
        XCTAssertEqual(queue.jobs.first?.state, .downloading)
    }

    func testReopenedSheetShowsSameJobsAndLatestProgress() throws {
        let harness = makeQueueSheetHarness()
        let first = harness.controller
        first.loadViewIfNeeded()
        let sourceURL = url("a.m4a")
        try submit(sourceURL.absoluteString, in: first)
        let id = try XCTUnwrap(harness.queue.jobs.first?.id)
        waitUntil { harness.operation.startedURLs.count == 1 }
        harness.operation.report(url: sourceURL, progress: 0.37)

        let reopened = DownloadSheetViewController(downloadQueue: harness.queue)
        reopened.loadViewIfNeeded()
        layout(reopened)

        XCTAssertEqual(progressValue("download.job.\(id).progress", in: reopened), 0.37, accuracy: 0.001)
        XCTAssertTrue(labelTexts(in: reopened).contains(L10n.format("download.queue.progress", 37)))
    }

    func testSubmittingFourURLsRendersFourRowsWithFourthWaiting() throws {
        let harness = makeQueueSheetHarness(maximumActiveCount: 3)
        harness.controller.loadViewIfNeeded()

        for index in 1...4 {
            try submit("https://example.com/\(index).m4a", in: harness.controller)
        }
        waitUntil { harness.operation.startedURLs.count == 3 }
        layout(harness.controller)

        XCTAssertEqual(harness.queue.jobs.count, 4)
        XCTAssertEqual(harness.queue.jobs.filter { $0.state == .downloading }.count, 3)
        let waiting = try XCTUnwrap(harness.queue.jobs.first { $0.state == .queued })
        XCTAssertEqual(label("download.job.\(waiting.id).status", in: harness.controller)?.text, L10n.text("download.queue.waiting"))
    }

    func testRowActionsOnlyAffectMatchingJobID() throws {
        let harness = makeQueueSheetHarness(maximumActiveCount: 1)
        let first = try harness.queue.enqueue(url("one.m4a"))
        let second = try harness.queue.enqueue(url("two.m4a"))
        harness.controller.loadViewIfNeeded()
        layout(harness.controller)

        try tap("download.job.\(second).cancel", in: harness.controller)
        XCTAssertEqual(job(second, in: harness.queue).state, .cancelled)
        XCTAssertEqual(job(first, in: harness.queue).state, .downloading)

        try tap("download.job.\(second).retry", in: harness.controller)
        XCTAssertEqual(job(second, in: harness.queue).state, .queued)
    }

    func testSuccessfulRowPlayOnlyRunsOnceAndRemoveOnlyDeletesMatchingRecord() throws {
        let harness = makeQueueSheetHarness(maximumActiveCount: 1)
        let firstURL = url("one.m4a")
        let first = try harness.queue.enqueue(firstURL)
        let second = try harness.queue.enqueue(url("two.m4a"))
        waitUntil { harness.operation.startedURLs == [firstURL] }
        harness.operation.succeed(url: firstURL, track: track(id: "one"))
        waitUntil { self.job(first, in: harness.queue).state == .success }
        harness.controller.loadViewIfNeeded()
        layout(harness.controller)

        try tap("download.job.\(first).play", in: harness.controller)
        try tap("download.job.\(first).play", in: harness.controller)
        XCTAssertEqual(harness.playedTracks().map(\.id), ["one"])

        try tap("download.job.\(first).remove", in: harness.controller)
        XCTAssertNil(harness.queue.jobs.first { $0.id == first })
        XCTAssertNotNil(harness.queue.jobs.first { $0.id == second })
    }

    func testInvalidURLShowsInputErrorWithoutAddingJob() throws {
        let harness = makeQueueSheetHarness()
        harness.controller.loadViewIfNeeded()

        try submit("not a valid audio URL", in: harness.controller)

        XCTAssertTrue(harness.queue.jobs.isEmpty)
        XCTAssertEqual(label("download.input.error", in: harness.controller)?.text, L10n.text("download.error.invalid_url"))
    }

    func testMalformedHTTPURLsWithoutHostShowInputErrorWithoutStartingOperation() throws {
        for malformedURL in ["https:///song.m4a", "http:/example.com/song.m4a"] {
            let harness = makeQueueSheetHarness()
            harness.controller.loadViewIfNeeded()

            try submit(malformedURL, in: harness.controller)

            XCTAssertTrue(harness.queue.jobs.isEmpty, "url=\(malformedURL)")
            XCTAssertTrue(harness.operation.startedURLs.isEmpty, "url=\(malformedURL)")
            XCTAssertEqual(
                label("download.input.error", in: harness.controller)?.text,
                L10n.text("download.error.invalid_url"),
                "url=\(malformedURL)"
            )
        }
    }

    func testFailedRowUsesLocalizedReasonAndCanRetryOrRemove() throws {
        let harness = makeQueueSheetHarness(maximumActiveCount: 1)
        let sourceURL = url("failure.m4a")
        let id = try harness.queue.enqueue(sourceURL)
        waitUntil { harness.operation.startedURLs == [sourceURL] }
        harness.operation.fail(url: sourceURL, error: DownloadError.unsupportedResponse)
        waitUntil { self.job(id, in: harness.queue).state == .failure }
        harness.controller.loadViewIfNeeded()
        layout(harness.controller)

        XCTAssertEqual(label("download.job.\(id).status", in: harness.controller)?.text, L10n.text("download.error.invalid_payload"))
        try tap("download.job.\(id).retry", in: harness.controller)
        XCTAssertEqual(job(id, in: harness.queue).state, .downloading)
        harness.queue.cancel(id: id)
        waitUntil { self.job(id, in: harness.queue).state == .cancelled }
        layout(harness.controller)
        try tap("download.job.\(id).remove", in: harness.controller)
        waitUntil { harness.queue.jobs.isEmpty }
    }

    func testDownloadingRowExposesLocalizedProgressAndMinimumActionTarget() throws {
        let harness = makeQueueSheetHarness()
        let sourceURL = url("voiceover.m4a")
        let id = try harness.queue.enqueue(sourceURL)
        waitUntil { harness.operation.startedURLs == [sourceURL] }
        harness.operation.report(url: sourceURL, progress: 0.62)
        harness.controller.loadViewIfNeeded()
        layout(harness.controller)

        let progress = try XCTUnwrap(view("download.job.\(id).progress", in: harness.controller.view))
        let cancel = try XCTUnwrap(view("download.job.\(id).cancel", in: harness.controller.view) as? UIButton)
        XCTAssertEqual(progress.accessibilityValue, L10n.format("download.queue.accessibility.progress", 62))
        XCTAssertTrue(cancel.titleLabel?.adjustsFontForContentSizeCategory == true)
        XCTAssertTrue(hasMinimumHeight(44, view: cancel))
    }

    func testDownloadInputUsesLocalizedCopyAndMinimumTouchTargets() throws {
        let harness = makeQueueSheetHarness()
        harness.controller.loadViewIfNeeded()
        let field = try XCTUnwrap(view("download.url", in: harness.controller.view) as? UITextField)

        XCTAssertEqual(harness.controller.title, L10n.text("download.title"))
        XCTAssertEqual(field.accessibilityLabel, L10n.text("download.url_accessibility"))
        XCTAssertEqual(buttonTitle("download.submit", in: harness.controller), L10n.text("download.queue.add"))
        XCTAssertEqual(field.keyboardType, .URL)
        XCTAssertEqual(field.returnKeyType, .go)
        XCTAssertTrue(allViews(in: harness.controller.view).compactMap { $0 as? UIButton }.allSatisfy {
            hasMinimumHeight(44, view: $0)
        })
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

    func testPermissionCompletionRequestsSharedLibraryReload() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        var status = MPMediaLibraryAuthorizationStatus.notDetermined
        var reloadCount = 0
        let controller = SettingsViewController(
            settingsStore: SettingsStore(defaults: defaults),
            authorizationStatus: { status },
            requestAuthorization: {
                status = .authorized
                return .authorized
            },
            openSettings: {},
            onAuthorizationChange: { reloadCount += 1 }
        )
        controller.loadViewIfNeeded()

        try tap("settings.permission", in: controller)
        waitUntil { reloadCount == 1 }

        XCTAssertEqual(reloadCount, 1)
    }

    func testMusicLibraryChangeObserverRemovesObserverAndGenerationOnDeinit() {
        let center = NotificationCenter()
        let name = Notification.Name(#function)
        var beginCount = 0
        var endCount = 0
        var changeCount = 0
        var observer: MusicLibraryChangeObserver? = MusicLibraryChangeObserver(
            notificationCenter: center,
            notificationName: name,
            beginGenerating: { beginCount += 1 },
            endGenerating: { endCount += 1 },
            onChange: { changeCount += 1 }
        )

        center.post(name: name, object: nil)
        XCTAssertEqual(beginCount, 1)
        XCTAssertEqual(changeCount, 1)

        observer = nil
        center.post(name: name, object: nil)
        XCTAssertNil(observer)
        XCTAssertEqual(endCount, 1)
        XCTAssertEqual(changeCount, 1)
    }

    func testSettingsReleasesWhilePermissionRequestIsSuspended() throws {
        let request = SuspendedAuthorizationRequest()
        let weakController = try startSuspendedPermissionRequest(request)

        let releasedWhileSuspended = weakController.value == nil
        request.resume(with: .authorized)
        waitUntil { request.completionCount == 1 }

        XCTAssertTrue(releasedWhileSuspended)
    }

    func testSettingsAndAboutUseLocalizedCopy() throws {
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
        XCTAssertEqual(settings.title, L10n.text("settings.title"))
        XCTAssertEqual(switches[0].accessibilityLabel, L10n.text("settings.cellular_title"))
        XCTAssertEqual(switches[1].accessibilityLabel, L10n.text("settings.autoplay_title"))
        XCTAssertTrue(labelTexts(in: settings).contains(L10n.text("settings.permission_title")))
        XCTAssertTrue(labelTexts(in: settings).contains(L10n.text("settings.cellular_title")))
        XCTAssertTrue(labelTexts(in: settings).contains(L10n.text("settings.cellular_detail")))
        XCTAssertTrue(labelTexts(in: settings).contains(L10n.text("settings.autoplay_title")))
        XCTAssertTrue(labelTexts(in: settings).contains(L10n.text("settings.autoplay_detail")))
        XCTAssertTrue(labelTexts(in: settings).contains(L10n.text("settings.section.library")))
        XCTAssertTrue(labelTexts(in: settings).contains(L10n.text("settings.section.download")))
        XCTAssertTrue(labelTexts(in: settings).contains(L10n.text("settings.section.about")))
        XCTAssertEqual(
            buttonTitle("settings.about", in: settings),
            L10n.text("settings.about_title")
        )

        let about = AboutViewController()
        about.loadViewIfNeeded()
        let copy = labelTexts(in: about).joined(separator: " ")
        XCTAssertEqual(about.title, L10n.text("about.page_title"))
        XCTAssertTrue(copy.contains(L10n.text("app.name")))
        XCTAssertTrue(copy.contains(L10n.text("about.subtitle")))
        XCTAssertTrue(copy.contains(L10n.text("about.formats_title")))
        XCTAssertTrue(copy.contains(L10n.text("about.formats_detail")))
        XCTAssertTrue(copy.contains(L10n.text("about.privacy_title")))
        XCTAssertTrue(copy.contains(L10n.text("about.privacy_detail")))
    }

    func testPermissionStatusesUseLocalizedCopy() throws {
        let cases: [(MPMediaLibraryAuthorizationStatus, String)] = [
            (.notDetermined, "settings.permission_status.not_requested"),
            (.denied, "settings.permission_status.denied"),
            (.restricted, "settings.permission_status.restricted"),
            (.authorized, "settings.permission_status.authorized")
        ]

        for (status, key) in cases {
            let defaults = UserDefaults(suiteName: "\(#function).\(key)")!
            defaults.removePersistentDomain(forName: "\(#function).\(key)")
            let settings = makeSettingsController(
                settingsStore: SettingsStore(defaults: defaults),
                status: { status }
            )
            settings.loadViewIfNeeded()

            XCTAssertTrue(
                labelTexts(in: settings).contains(L10n.text(key)),
                "status=\(status)"
            )
        }
    }

    func testSettingsActionPushesOnlyOnceOnPhoneAndPad() throws {
        for kind in [AppRootKind.phone, .pad] {
            let viewModel = LibraryViewModel(
                library: FlowStubMusicLibrary(),
                localStore: FlowStubLocalMusicStore()
            )
            let dependencies = AppRootDependencies(
                identity: NSObject(),
                libraryViewModel: viewModel,
                snapshotPublisher: Empty<PlaybackSnapshot, Never>().eraseToAnyPublisher(),
                onPlay: { _, _ in },
                onTogglePlay: {},
                makeSettingsViewController: { self.makeIsolatedSettingsController() }
            )
            let root = AppCoordinator.makeMainViewControllerFactory(dependencies: dependencies)(kind)
            let library = try XCTUnwrap(descendant(LibraryViewController.self, in: root))
            let navigation = try XCTUnwrap(library.navigationController)
            let originalCount = navigation.viewControllers.count

            try XCTUnwrap(library.onSettings)()
            try XCTUnwrap(library.onSettings)()

            XCTAssertEqual(navigation.viewControllers.count, originalCount + 1, "root=\(kind)")
            XCTAssertTrue(navigation.topViewController is SettingsViewController, "root=\(kind)")
        }
    }

    func testAboutButtonPushesOnlyOnce() throws {
        let settings = makeIsolatedSettingsController()
        let navigation = UINavigationController(rootViewController: settings)
        navigation.loadViewIfNeeded()
        settings.loadViewIfNeeded()

        try tap("settings.about", in: settings)
        try tap("settings.about", in: settings)

        XCTAssertEqual(navigation.viewControllers.count, 2)
        XCTAssertTrue(navigation.topViewController is AboutViewController)
    }

    func testPrivacyCardOpensPolicyInInternalWebView() throws {
        let about = AboutViewController()
        let navigation = UINavigationController(rootViewController: about)
        navigation.loadViewIfNeeded()
        about.loadViewIfNeeded()

        let privacyCard = try XCTUnwrap(
            view("about.privacy", in: about.view) as? UIControl
        )
        privacyCard.sendActions(for: .touchUpInside)

        let privacy = try XCTUnwrap(
            navigation.topViewController as? PrivacyWebViewController
        )
        XCTAssertEqual(
            privacy.url.absoluteString,
            "https://disktoneweb.dengcheez.workers.dev/privacy"
        )
    }

    func testAboutContentScrollsWithoutAmbiguityAtAccessibilityXXXLOnSmallScreen() throws {
        let host = UIViewController()
        host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 360)
        let about = AboutViewController()
        host.addChild(about)
        host.setOverrideTraitCollection(
            UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
            forChild: about
        )
        let aboutView = about.view!
        aboutView.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(aboutView)
        NSLayoutConstraint.activate([
            aboutView.topAnchor.constraint(equalTo: host.view.topAnchor),
            aboutView.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            aboutView.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            aboutView.bottomAnchor.constraint(equalTo: host.view.bottomAnchor)
        ])
        about.didMove(toParent: host)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let scroll = try XCTUnwrap(view("about.scroll", in: aboutView) as? UIScrollView)
        let content = try XCTUnwrap(view("about.content", in: aboutView))
        XCTAssertTrue(allViews(in: aboutView).allSatisfy { !$0.hasAmbiguousLayout })
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        XCTAssertLessThanOrEqual(content.frame.maxY, scroll.contentSize.height + 0.5)
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

    private func makeQueueSheetHarness(maximumActiveCount: Int = 3) -> QueueSheetHarness {
        let operation = ControlledQueueDownloadOperation()
        var playedTracks = [SimpleMusic.MusicTrack]()
        let queue = makeQueue(
            operation: operation,
            maximumActiveCount: maximumActiveCount,
            onPlay: { playedTracks.append($0) }
        )
        return QueueSheetHarness(
            controller: DownloadSheetViewController(downloadQueue: queue),
            queue: queue,
            operation: operation,
            playedTracks: { playedTracks }
        )
    }

    private func makeQueue(
        operation: ControlledQueueDownloadOperation,
        maximumActiveCount: Int = 3,
        onPlay: @escaping @MainActor (SimpleMusic.MusicTrack) -> Void = { _ in }
    ) -> DownloadQueue {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = SettingsStore(defaults: defaults)
        settings.autoPlayAfterDownload = false
        let queue = DownloadQueue(
            store: DownloadQueueStore(fileURL: nil),
            operation: operation.perform,
            settingsStore: settings,
            recovery: { _ in .cleaned },
            onReload: {},
            onPlay: onPlay,
            maximumActiveCount: maximumActiveCount
        )
        return queue
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

    private func makeIsolatedSettingsController() -> SettingsViewController {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return makeSettingsController(
            settingsStore: SettingsStore(defaults: defaults),
            status: { .authorized }
        )
    }

    private func startSuspendedPermissionRequest(
        _ request: SuspendedAuthorizationRequest
    ) throws -> WeakReference<SettingsViewController> {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let controller = SettingsViewController(
            settingsStore: SettingsStore(defaults: defaults),
            authorizationStatus: { .notDetermined },
            requestAuthorization: { await request.perform() },
            openSettings: {}
        )
        let weakController = WeakReference(controller)
        controller.handlePermission()
        waitUntil { request.callCount == 1 }
        return weakController
    }

    private func submit(_ value: String, in controller: DownloadSheetViewController) throws {
        let field = try XCTUnwrap(view("download.url", in: controller.view) as? UITextField)
        field.text = value
        try tap("download.submit", in: controller)
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

    private func layout(_ controller: UIViewController) {
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    private func url(_ name: String) -> URL {
        URL(string: "https://example.com/\(name)")!
    }

    private func job(_ id: UUID, in queue: DownloadQueue) -> DownloadJob {
        guard let job = queue.jobs.first(where: { $0.id == id }) else {
            XCTFail("Missing job \(id)")
            fatalError()
        }
        return job
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

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
private final class SuspendedAuthorizationRequest {
    private var continuation: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>?
    private(set) var callCount = 0
    private(set) var completionCount = 0

    func perform() async -> MPMediaLibraryAuthorizationStatus {
        callCount += 1
        let status = await withCheckedContinuation { continuation = $0 }
        completionCount += 1
        return status
    }

    func resume(with status: MPMediaLibraryAuthorizationStatus) {
        continuation?.resume(returning: status)
        continuation = nil
    }
}

@MainActor
private final class ControlledQueueDownloadOperation {
    private final class Invocation {
        let url: URL
        let progress: @MainActor @Sendable (Double) -> Void
        var continuation: CheckedContinuation<SimpleMusic.MusicTrack, Error>?

        init(
            url: URL,
            progress: @escaping @MainActor @Sendable (Double) -> Void,
            continuation: CheckedContinuation<SimpleMusic.MusicTrack, Error>
        ) {
            self.url = url
            self.progress = progress
            self.continuation = continuation
        }
    }

    private var invocations = [Invocation]()
    private(set) var cancellationCount = 0
    var startedURLs: [URL] { invocations.map(\.url) }

    func perform(
        url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
        reservation: @escaping @MainActor @Sendable (String) throws -> Void
    ) async throws -> SimpleMusic.MusicTrack {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                invocations.append(Invocation(url: url, progress: progress, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self,
                      let invocation = invocations.last(where: {
                          $0.url == url && $0.continuation != nil
                      }),
                      let continuation = invocation.continuation else { return }
                cancellationCount += 1
                invocation.continuation = nil
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func report(url: URL, progress: Double) {
        invocations.last(where: { $0.url == url && $0.continuation != nil })?.progress(progress)
    }

    func succeed(url: URL, track: SimpleMusic.MusicTrack) {
        guard let invocation = invocations.last(where: { $0.url == url && $0.continuation != nil }),
              let continuation = invocation.continuation else { return }
        invocation.continuation = nil
        continuation.resume(returning: track)
    }

    func fail(url: URL, error: Error) {
        guard let invocation = invocations.last(where: { $0.url == url && $0.continuation != nil }),
              let continuation = invocation.continuation else { return }
        invocation.continuation = nil
        continuation.resume(throwing: error)
    }
}

private struct QueueSheetHarness {
    let controller: DownloadSheetViewController
    let queue: DownloadQueue
    let operation: ControlledQueueDownloadOperation
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

private func labelTexts(in controller: UIViewController) -> [String] {
    allViews(in: controller.view).compactMap { ($0 as? UILabel)?.text }
}

private func buttonTitle(_ identifier: String, in controller: UIViewController) -> String? {
    let button = (view(identifier, in: controller.view) as? UIButton)
        ?? (controller.navigationItem.leftBarButtonItem?.customView as? UIButton)
    return button?.configuration?.title
}

private func label(_ identifier: String, in controller: UIViewController) -> UILabel? {
    view(identifier, in: controller.view) as? UILabel
}

private func progressValue(_ identifier: String, in controller: UIViewController) -> Double {
    Double((view(identifier, in: controller.view) as? UIProgressView)?.progress ?? -1)
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
