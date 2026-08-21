# SimpleMusic 应用内下载队列实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把单任务下载页改为应用级持久化下载队列，支持最多 3 个并发、页面关闭后继续、逐项进度与取消，并在进程终止后把未完成任务恢复为“已中断”。

**Architecture:** `AppEnvironment` 持有唯一 `DownloadQueue`；队列负责 FIFO 调度、状态、generation 隔离、JSON 账本和播放/资料库回调，`DownloadManager` 继续负责单个文件的网络与文件事务。下载页订阅队列快照并渲染可滚动任务列表，不再拥有或取消传输 `Task`。

**Tech Stack:** Swift 5、UIKit、Combine、Foundation、Core Data、XCTest、iOS 15.0+、CocoaPods、SnapKit。

**Spec:** `docs/superpowers/specs/2026-08-21-download-queue-design.md`

**Working Directory:** 所有命令均从 `/Users/db/Documents/git/my/music/SimpleMusic/SimpleMusic` 执行；文档和文件路径也以该目录为基准。

## Global Constraints

- 应用内同时最多 3 个活动下载，其余任务严格按提交顺序 FIFO 等待。
- 关闭、下拉收起或释放下载页面不得取消队列任务；只有任务行的取消动作可以取消对应 ID。
- 使用普通前台 `URLSession`；进入后台只在 iOS 允许的执行时间内继续，不实现系统后台 session 或断点续传。
- 进程终止后，上次 `queued/downloading` 任务变成 `interrupted`，不会自动请求网络；手动重试从进度 0 开始。
- 恢复时先查本地索引，再清理精确的受控 reservation 文件；不得跟随符号链接或删除下载根之外的路径。
- 多任务完成不得抢占播放；只有提交时没有其他未完成任务、且当时自动播放设置开启的尝试可自动播放一次。
- 英文是默认回退语言；所有新增用户文案和 VoiceOver 文案同时提供 `en`、`zh-Hans`、`zh-Hant`。
- 保持 iOS 15.0、仅竖屏、CocoaPods 和 SnapKit；不增加第三方依赖。
- 新增中文注释只解释所有权、generation、恢复顺序和文件安全等非显而易见约束。
- 不改动或暂存现有用户文件：`xcuserdata`、`music-note-red@2x.png`、`music-note-red@3x.png`、`Base.lproj/LaunchScreen.storyboard`。
- 每个任务严格执行可信 RED、最小 GREEN、聚焦回归、`git diff --check` 和中文 commit。

---

## File Structure

### 新建文件

- `SimpleMusic/Downloads/DownloadJob.swift`：可编码的任务快照、稳定状态和错误类别。
- `SimpleMusic/Downloads/DownloadQueueStore.swift`：Application Support JSON 账本和测试内存实现边界。
- `SimpleMusic/Downloads/DownloadQueue.swift`：应用级队列、三并发 FIFO、generation、自动播放和恢复编排。
- `SimpleMusic/Downloads/DownloadRecoveryService.swift`：按“索引优先、受控文件清理其次”恢复 reservation。
- `SimpleMusic/UI/Download/DownloadJobCell.swift`：单个任务的状态、进度和操作按钮。
- `SimpleMusicTests/DownloadQueueTests.swift`：账本、调度、取消、重试、恢复和播放语义测试。
- `docs/testing/2026-08-21-download-queue-verification.md`：最终行为、构建和已知边界证据。

### 修改文件

- `SimpleMusic/Downloads/DownloadManager.swift`：增加 reservation 文件名阶段回调，默认参数保持旧调用兼容。
- `SimpleMusic/Persistence/LocalMusicStore.swift`：增加按文件名查询索引的后台安全入口。
- `SimpleMusic/App/AppEnvironment.swift`：创建唯一下载队列、JSON store、恢复服务和共享回调。
- `SimpleMusic/App/AppCoordinator.swift`：下载工厂注入共享队列，不再给页面注入单任务 operation。
- `SimpleMusic/UI/Download/DownloadSheetViewController.swift`：改成输入区和任务列表，页面生命周期不再取消任务。
- `SimpleMusic/en.lproj/Localizable.strings`：下载队列英文默认文案。
- `SimpleMusic/zh-Hans.lproj/Localizable.strings`：下载队列简体中文文案。
- `SimpleMusic/zh-Hant.lproj/Localizable.strings`：下载队列台湾繁体中文文案。
- `SimpleMusicTests/DownloadManagerConcurrencyTests.swift`：reservation 回调顺序和失败回滚。
- `SimpleMusicTests/LocalMusicStoreTests.swift`：按文件名查询和恢复索引边界。
- `SimpleMusicTests/DownloadAndSettingsFlowTests.swift`：多任务 UI、关闭不取消、重开同步和逐项操作。
- `SimpleMusicTests/AppCoordinatorTests.swift`：iPhone/iPad 下载入口复用同一队列。
- `SimpleMusicTests/LocalizationTests.swift`：新增 key、格式参数和生产字面量审计回归。
- `SimpleMusic.xcodeproj/project.pbxproj`：只登记新 `DownloadQueueTests.swift` 的 test target membership；App target 使用文件系统同步根组。

---

### Task 1: 建立下载任务模型与 JSON 账本

**Files:**
- Create: `SimpleMusic/Downloads/DownloadJob.swift`
- Create: `SimpleMusic/Downloads/DownloadQueueStore.swift`
- Create: `SimpleMusicTests/DownloadQueueTests.swift`
- Modify: `SimpleMusic.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Foundation `Codable`、`URL`、`UUID`、原子 `Data.write`。
- Produces:
  - `DownloadJob: Codable, Equatable, Identifiable`
  - `DownloadJob.State: String, Codable`
  - `DownloadJob.FailureReason: String, Codable`
  - `@MainActor protocol DownloadQueuePersisting`
  - `@MainActor final class DownloadQueueStore`
  - `DownloadQueueStore.load() throws -> [DownloadJob]`
  - `DownloadQueueStore.save(_ jobs: [DownloadJob]) throws`
  - `DownloadQueueStore.applicationSupport(fileManager:) throws -> DownloadQueueStore`

- [ ] **Step 1: 写账本 round-trip、损坏保护和内存模式失败测试**

在 `DownloadQueueTests.swift` 创建以下首组测试；helper 用 `FileManager.default.temporaryDirectory` 下唯一子目录，并在 `tearDown` 只删除该精确目录：

```swift
import XCTest
@testable import SimpleMusic

@MainActor
final class DownloadQueueTests: XCTestCase {
    func testQueueStoreRoundTripsRecoverableJobFields() throws {
        let fileURL = try makeTemporaryDirectory()
            .appendingPathComponent("download-queue.json")
        let store = DownloadQueueStore(fileURL: fileURL)
        let job = DownloadJob(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sourceURL: URL(string: "https://example.com/a.m4a")!,
            displayName: "a.m4a",
            state: .downloading,
            progress: 0.45,
            createdAt: Date(timeIntervalSince1970: 42),
            attempt: 3,
            failureReason: nil,
            reservedFileName: "a-1234.m4a"
        )

        try store.save([job])

        XCTAssertEqual(try DownloadQueueStore(fileURL: fileURL).load(), [job])
    }

    func testCorruptQueueLedgerThrowsWithoutReplacingOriginalBytes() throws {
        let fileURL = try makeTemporaryDirectory()
            .appendingPathComponent("download-queue.json")
        let original = Data("{not-json".utf8)
        try original.write(to: fileURL)

        XCTAssertThrowsError(try DownloadQueueStore(fileURL: fileURL).load())
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testMemoryQueueStoreDoesNotWriteAFile() throws {
        let initial = [makeJob(state: .interrupted)]
        let store = DownloadQueueStore(fileURL: nil, initialJobs: initial)

        XCTAssertEqual(try store.load(), initial)
        try store.save([])
        XCTAssertEqual(try store.load(), [])
    }

    private func makeJob(state: DownloadJob.State) -> DownloadJob {
        DownloadJob(
            id: UUID(),
            sourceURL: URL(string: "https://example.com/test.m4a")!,
            displayName: "test.m4a",
            state: state,
            progress: 0,
            createdAt: Date(timeIntervalSince1970: 1),
            attempt: 0,
            failureReason: nil,
            reservedFileName: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
```

- [ ] **Step 2: 把测试文件加入 test target 并取得可信 RED**

在 `project.pbxproj` 添加唯一的 `PBXFileReference`、`PBXBuildFile`、Tests group child 和 Tests Sources entry，例如：

```text
D21000000000000000000001 /* DownloadQueueTests.swift in Sources */
D21000000000000000000002 /* DownloadQueueTests.swift */
```

运行：

```bash
set -o pipefail
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO \
  -only-testing:SimpleMusicTests/DownloadQueueTests test CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee /tmp/download-queue-task1-red.log
```

预期：exit 65，错误只包含缺少 `DownloadJob`、`DownloadQueueStore` 等生产类型；测试 helper 的语法或 actor 错误不算可信 RED。

- [ ] **Step 3: 实现稳定的 Codable 任务模型**

`DownloadJob.swift` 使用无关联值状态，确保 JSON schema 稳定；成功的 `MusicTrack` 不进入任务模型：

```swift
import Foundation

struct DownloadJob: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case queued
        case downloading
        case success
        case failure
        case cancelled
        case interrupted
    }

    enum FailureReason: String, Codable {
        case unsupportedURL
        case invalidPayload
        case generic
        case recovery
    }

    let id: UUID
    let sourceURL: URL
    var displayName: String
    var state: State
    var progress: Double
    let createdAt: Date
    var attempt: UInt64
    var failureReason: FailureReason?
    var reservedFileName: String?
}
```

- [ ] **Step 4: 实现 JSON 和内存两种同接口 store**

`DownloadQueueStore.swift` 的生产接口固定为：

```swift
import Foundation

@MainActor
protocol DownloadQueuePersisting: AnyObject {
    func load() throws -> [DownloadJob]
    func save(_ jobs: [DownloadJob]) throws
}

@MainActor
final class DownloadQueueStore: DownloadQueuePersisting {
    private let fileURL: URL?
    private var memoryJobs: [DownloadJob]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL?, initialJobs: [DownloadJob] = []) {
        self.fileURL = fileURL
        memoryJobs = initialJobs
        encoder.outputFormatting = [.sortedKeys]
    }

    func load() throws -> [DownloadJob] {
        guard let fileURL else { return memoryJobs }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode([DownloadJob].self, from: Data(contentsOf: fileURL))
    }

    func save(_ jobs: [DownloadJob]) throws {
        guard let fileURL else {
            memoryJobs = jobs
            return
        }
        try encoder.encode(jobs).write(to: fileURL, options: .atomic)
    }
}
```

`applicationSupport(fileManager:)` 必须创建 `Application Support/SimpleMusic` 后返回 `download-queue.json` store；若目录创建失败则抛错，让 `AppEnvironment` 在 Task 3 明确降级到内存 store。

- [ ] **Step 5: 跑聚焦 GREEN 并提交**

运行 Task 1 的同一 focused 命令，预期 3/3 passed、`** TEST SUCCEEDED **`；再运行：

```bash
git diff --check
git add SimpleMusic/Downloads/DownloadJob.swift \
  SimpleMusic/Downloads/DownloadQueueStore.swift \
  SimpleMusicTests/DownloadQueueTests.swift \
  SimpleMusic.xcodeproj/project.pbxproj
git commit -m 'feat: 添加下载任务账本'
```

提交前确认 staged diff 不含任何 `xcuserdata`、图片或 LaunchScreen 文件。

---

### Task 2: 实现最多三并发的 FIFO 队列

**Files:**
- Create: `SimpleMusic/Downloads/DownloadQueue.swift`
- Modify: `SimpleMusicTests/DownloadQueueTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `DownloadJob`、`DownloadQueuePersisting`，现有 `SettingsStore`、`DownloadError`、`MusicTrack`。
- Produces:
  - `@MainActor final class DownloadQueue`
  - `DownloadQueue.DownloadOperation`
  - `DownloadQueue.RecoveryOperation`
  - `DownloadQueue.jobsPublisher: AnyPublisher<[DownloadJob], Never>`
  - `DownloadQueue.jobs: [DownloadJob]`
  - `enqueue(_:) throws -> UUID`
  - `cancel(id:)`、`retry(id:)`、`remove(id:)`、`play(id:)`

- [ ] **Step 1: 写 3 并发、FIFO 和显示顺序失败测试**

使用可控 operation 记录 started URL，并为每项保存 progress、reservation 和 continuation：

```swift
func testQueueStartsThreeAndWaitsFourthUntilFirstFinishes() throws {
    let operation = ControlledQueueDownloadOperation()
    let queue = makeQueue(operation: operation)
    let urls = (1...4).map { URL(string: "https://example.com/\($0).m4a")! }

    let ids = try urls.map(queue.enqueue)
    waitUntil { operation.startedURLs.count == 3 }

    XCTAssertEqual(operation.startedURLs, Array(urls.prefix(3)))
    XCTAssertEqual(queue.jobs.first?.id, ids.last) // UI 快照最新任务在前
    XCTAssertEqual(queue.jobs.first(where: { $0.id == ids[3] })?.state, .queued)

    operation.succeed(url: urls[0], track: track(id: "one"))
    waitUntil { operation.startedURLs == urls }
    XCTAssertEqual(queue.jobs.first(where: { $0.id == ids[3] })?.state, .downloading)
}
```

再添加 `testFailureAndCancellationEachReleaseExactlyOneSlot`，分别让活动任务失败和取消，断言每次只启动一个新的 FIFO waiter，活动数从不超过 3。

- [ ] **Step 2: 运行并确认可信 RED**

```bash
set -o pipefail
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO \
  -only-testing:SimpleMusicTests/DownloadQueueTests test CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee /tmp/download-queue-task2-scheduler-red.log
```

预期：exit 65，只因 `DownloadQueue` 尚不存在或尚未启动 3 个任务而失败。

- [ ] **Step 3: 实现最小队列骨架和调度器**

接口和所有权固定为：

```swift
import Combine
import Foundation

@MainActor
final class DownloadQueue {
    typealias DownloadOperation = @MainActor @Sendable (
        URL,
        @escaping @MainActor @Sendable (Double) -> Void,
        @escaping @MainActor @Sendable (String) throws -> Void
    ) async throws -> MusicTrack

    enum RecoveryDisposition: Equatable { case indexed, cleaned }
    typealias RecoveryOperation = @MainActor @Sendable (String) async throws -> RecoveryDisposition

    private(set) var jobs: [DownloadJob]
    var jobsPublisher: AnyPublisher<[DownloadJob], Never> { subject.eraseToAnyPublisher() }

    private let subject: CurrentValueSubject<[DownloadJob], Never>
    private let store: any DownloadQueuePersisting
    private let operation: DownloadOperation
    private let settingsStore: SettingsStore
    private let recovery: RecoveryOperation
    private let onReload: @MainActor () -> Void
    private let onPlay: @MainActor (MusicTrack) -> Void
    private let maximumActiveCount: Int
    private var activeTasks = [UUID: Task<Void, Never>]()
    private var attemptAutoPlay = [UUID: Bool]()
    private var successfulTracks = [UUID: MusicTrack]()
    private var consumedPlayIDs = Set<UUID>()

    init(
        store: any DownloadQueuePersisting,
        operation: @escaping DownloadOperation,
        settingsStore: SettingsStore,
        recovery: @escaping RecoveryOperation,
        onReload: @escaping @MainActor () -> Void,
        onPlay: @escaping @MainActor (MusicTrack) -> Void,
        maximumActiveCount: Int = 3,
        now: @escaping @MainActor () -> Date = Date.init,
        log: @escaping @MainActor (String) -> Void = { NSLog("%@", $0) }
    )
}
```

构造器从 store 加载；损坏时调用注入的 `log` 并使用空数组，不覆盖损坏文件。`enqueue` 先用现有 `AudioDownloadValidator.validate(url:)` 校验，插入 `createdAt` 更新的 job，强制持久化后调用 `scheduleIfNeeded()`。

`scheduleIfNeeded()` 每次按 `createdAt` 正序选择最早的 `.queued`，直到 `activeTasks.count == maximumActiveCount`。UI 的 `jobs`/publisher 始终按 `createdAt` 倒序发布。

- [ ] **Step 4: 写进度隔离、取消迟到回调和重试失败测试**

```swift
func testCancelAndRetryIgnoreOldAttemptCallbacks() throws {
    let operation = ControlledQueueDownloadOperation()
    let queue = makeQueue(operation: operation)
    let url = URL(string: "https://example.com/a.m4a")!
    let id = try queue.enqueue(url)
    waitUntil { operation.attemptCount(url: url) == 1 }

    operation.report(url: url, attempt: 0, progress: 0.4)
    XCTAssertEqual(job(id, in: queue).progress, 0.4)
    queue.cancel(id: id)
    waitUntil { job(id, in: queue).state == .cancelled }

    queue.retry(id: id)
    waitUntil { operation.attemptCount(url: url) == 2 }
    XCTAssertEqual(job(id, in: queue).progress, 0)

    operation.report(url: url, attempt: 0, progress: 0.9)
    operation.succeed(url: url, attempt: 0, track: track(id: "old"))
    XCTAssertEqual(job(id, in: queue).state, .downloading)
    XCTAssertEqual(job(id, in: queue).progress, 0)
}
```

再添加：

- `testProgressForOneJobDoesNotChangeOtherJobs`
- `testRemovingActiveJobCancelsThenRemovesAfterTerminalCallback`
- `testProgressPersistsOnlyAtFivePercentBucketsButPublishesEveryValue`
- `testUnsupportedURLBecomesEnqueueErrorWithoutCreatingJob`

- [ ] **Step 5: 实现 generation、终态封口和持久化节流**

每次尝试先递增 `job.attempt`，Task 捕获该值；progress、reservation、success、failure 和 cancellation 回调都必须执行：

```swift
guard currentJob.id == id, currentJob.attempt == attempt else { return }
```

取消先递增 attempt、移除 active handle，再调用 `task.cancel()` 并把状态写为 `.cancelled`。下载 Task 的 `defer` 只在 handle 仍属于同 attempt 时释放槽位和再次调度。

publisher 接收每个合法进度；JSON 只在跨越新的 5% bucket、reservation 或状态变化时保存。持久化数组过滤 `.success`，所以成功记录只存在当前进程内存中。

失败映射只保留稳定类别，不把 `Error.localizedDescription` 写入账本：

```swift
private static func failureReason(for error: Error) -> DownloadJob.FailureReason {
    guard let downloadError = error as? DownloadError else { return .generic }
    switch downloadError {
    case .unsupportedURL:
        return .unsupportedURL
    case .unsupportedResponse:
        return .invalidPayload
    }
}
```

成功路径先校验 generation，保存 `successfulTracks[id]`、封口状态、调用一次 `onReload()`；符合提交时 eligibility 的尝试再调用一次 `onPlay(track)` 并把 ID 放入 `consumedPlayIDs`。`play(id:)` 只接受 `.success`、存在 runtime track 且未消费的 ID。

- [ ] **Step 6: 写自动播放和手动播放一次性测试**

```swift
func testOnlySingleEligibleAttemptAutoPlaysAndManualPlayConsumesOnce() throws {
    let operation = ControlledQueueDownloadOperation()
    var playedTracks = [MusicTrack]()
    let settings = makeSettings(autoPlay: true)
    let queue = makeQueue(
        operation: operation,
        settings: settings,
        onPlay: { playedTracks.append($0) }
    )

    let firstURL = URL(string: "https://example.com/one.m4a")!
    let secondURL = URL(string: "https://example.com/two.m4a")!
    let first = try queue.enqueue(firstURL)
    let second = try queue.enqueue(secondURL)
    operation.succeed(url: firstURL, attempt: 0, track: track(id: "one"))
    operation.succeed(url: secondURL, attempt: 0, track: track(id: "two"))
    waitUntil { queue.jobs.filter { $0.state == .success }.count == 2 }

    XCTAssertEqual(playedTracks.map(\.id), ["one"])
    queue.play(id: second)
    queue.play(id: second)
    XCTAssertEqual(playedTracks.map(\.id), ["one", "two"])
}
```

补充 `testRetryRecomputesAutoPlayEligibility`，证明 auto-play eligibility 不跨 attempt 或进程持久化。

测试文件使用以下可控 operation；每个 URL 的 invocation 数组下标就是 attempt 下标，所有测试在退出前必须 `succeed`、`fail` 或取消并等待每个 continuation 完成：

```swift
@MainActor
private final class ControlledQueueDownloadOperation {
    private final class Invocation {
        let url: URL
        let progress: @MainActor @Sendable (Double) -> Void
        let reservation: @MainActor @Sendable (String) throws -> Void
        var continuation: CheckedContinuation<MusicTrack, Error>?

        init(
            url: URL,
            progress: @escaping @MainActor @Sendable (Double) -> Void,
            reservation: @escaping @MainActor @Sendable (String) throws -> Void,
            continuation: CheckedContinuation<MusicTrack, Error>
        ) {
            self.url = url
            self.progress = progress
            self.reservation = reservation
            self.continuation = continuation
        }
    }

    private(set) var invocations = [Invocation]()
    private(set) var cancellationCount = 0
    var startedURLs: [URL] { invocations.map(\.url) }

    func perform(
        url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
        reservation: @escaping @MainActor @Sendable (String) throws -> Void
    ) async throws -> MusicTrack {
        let index = invocations.count
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                invocations.append(Invocation(
                    url: url,
                    progress: progress,
                    reservation: reservation,
                    continuation: continuation
                ))
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, invocations.indices.contains(index),
                      let continuation = invocations[index].continuation else { return }
                invocations[index].continuation = nil
                cancellationCount += 1
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func attemptCount(url: URL) -> Int { invocations.filter { $0.url == url }.count }

    func report(url: URL, attempt: Int, progress: Double) {
        invocation(url: url, attempt: attempt).progress(progress)
    }

    func reserve(url: URL, attempt: Int, fileName: String) throws {
        try invocation(url: url, attempt: attempt).reservation(fileName)
    }

    func succeed(url: URL, attempt: Int = 0, track: MusicTrack) {
        let invocation = invocation(url: url, attempt: attempt)
        let continuation = invocation.continuation
        invocation.continuation = nil
        continuation?.resume(returning: track)
    }

    func fail(url: URL, attempt: Int = 0, error: Error) {
        let invocation = invocation(url: url, attempt: attempt)
        let continuation = invocation.continuation
        invocation.continuation = nil
        continuation?.resume(throwing: error)
    }

    private func invocation(url: URL, attempt: Int) -> Invocation {
        invocations.filter { $0.url == url }[attempt]
    }
}
```

- [ ] **Step 7: 跑聚焦 GREEN 和现有下载并发回归后提交**

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO \
  -only-testing:SimpleMusicTests/DownloadQueueTests \
  -only-testing:SimpleMusicTests/DownloadManagerConcurrencyTests \
  test CODE_SIGNING_ALLOWED=NO
git diff --check
git add SimpleMusic/Downloads/DownloadQueue.swift SimpleMusicTests/DownloadQueueTests.swift
git commit -m 'feat: 实现三并发下载队列'
```

预期：两个 focused suite 全部通过；提交只包含 Task 2 两个文件。

---

### Task 3: 接入 reservation 恢复和应用级队列所有权

**Files:**
- Create: `SimpleMusic/Downloads/DownloadRecoveryService.swift`
- Modify: `SimpleMusic/Downloads/DownloadManager.swift`
- Modify: `SimpleMusic/Persistence/LocalMusicStore.swift`
- Modify: `SimpleMusic/Downloads/DownloadQueue.swift`
- Modify: `SimpleMusic/App/AppEnvironment.swift`
- Modify: `SimpleMusicTests/DownloadManagerConcurrencyTests.swift`
- Modify: `SimpleMusicTests/DownloadQueueTests.swift`
- Modify: `SimpleMusicTests/LocalMusicStoreTests.swift`

**Interfaces:**
- Consumes: Task 2 `DownloadQueue.DownloadOperation`/`RecoveryOperation`，现有 `DownloadFileStore.removeFile(named:)` 和 Core Data 索引。
- Produces:
  - `DownloadManager.ReservationObserver`
  - `DownloadManager.download(from:progress:onReservation:)`
  - `LocalMusicStore.contains(fileName:) async throws -> Bool`
  - `DownloadRecoveryService.reconcile(fileName:) async throws -> DownloadQueue.RecoveryDisposition`
  - `DownloadRecoveryService.cleanupRetainedTemporaryFiles() throws`
  - `AppEnvironment.downloadQueue: DownloadQueue?`

- [ ] **Step 1: 写 reservation 必须先持久化、回调失败必须回滚的 RED**

在现有 `DownloadManagerConcurrencyTests` 使用事件数组记录顺序：

```swift
func testReservationObserverRunsBeforeCommitAndReceivesControlledLeafName() async throws {
    var events = [String]()
    let manager = try makeManager(
        onCommit: { events.append("commit") }
    )

    _ = try await manager.download(
        from: audioURL("ordered.m4a"),
        progress: { _ in },
        onReservation: { fileName in events.append("reserve:\(fileName)") }
    )

    XCTAssertEqual(events.prefix(2), ["reserve:ordered.m4a", "commit"])
}

func testReservationPersistenceFailureDiscardsReservationAndDoesNotInsertIndex() async throws {
    let harness = try makeDownloadHarness()

    do {
        _ = try await harness.manager.download(
            from: audioURL("fail.m4a"),
            progress: { _ in },
            onReservation: { _ in throw QueueStoreTestError.writeFailed }
        )
        XCTFail("reservation 账本写入失败必须中止下载事务")
    } catch QueueStoreTestError.writeFailed {
        // 预期错误。
    }

    XCTAssertEqual(try harness.musicStore.fetchTracks(), [])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.downloadRoot.path), [])
}

private enum QueueStoreTestError: Error {
    case writeFailed
}
```

先运行该测试类，预期编译因 `extra argument 'onReservation'` 可信失败。

- [ ] **Step 2: 最小扩展 DownloadManager 阶段回调**

保持所有旧调用兼容：

```swift
typealias ReservationObserver = @MainActor @Sendable (String) throws -> Void

func download(
    from url: URL,
    progress: @escaping @MainActor @Sendable (Double) -> Void,
    onReservation: @escaping ReservationObserver = { _ in }
) async throws -> MusicTrack
```

在 `reserveDestination` 返回后、`commit` 之前执行：

```swift
try onReservation(newReservation.destinationURL.lastPathComponent)
```

回调抛错继续进入现有 rollback，恰好消费 reservation；不得把回调放到 commit 或 Core Data insert 之后。

- [ ] **Step 3: 写索引查询与恢复服务 RED**

在 `LocalMusicStoreTests` 添加按文件名 true/false 测试；在 `DownloadQueueTests` 添加真实 recovery service 测试：

```swift
func testRecoveryKeepsIndexedFileAndCleansOnlyUnindexedControlledFile() async throws {
    let indexed = try makeStoredTrack(fileName: "indexed.m4a")
    try writeAudio(named: "indexed.m4a")
    try writeAudio(named: "orphan.m4a")
    let service = DownloadRecoveryService(fileStore: fileStore, musicStore: musicStore)

    XCTAssertEqual(try await service.reconcile(fileName: "indexed.m4a"), .indexed)
    XCTAssertEqual(try await service.reconcile(fileName: "orphan.m4a"), .cleaned)
    XCTAssertTrue(FileManager.default.fileExists(atPath: indexedFileURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphanFileURL.path))
    XCTAssertEqual(indexed.id, try XCTUnwrap(try musicStore.fetchTracks().first).id)
}

func testRecoveryRejectsTraversalAndDoesNotDeleteExternalFile() async throws {
    let outside = try writeExternalFile()
    do {
        _ = try await service.reconcile(fileName: "../outside.m4a")
        XCTFail("目录穿越必须被拒绝")
    } catch DownloadFileStoreError.invalidFileName {
        // 预期错误。
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
}

func testTemporaryCleanupRemovesOnlyOwnedTransferFiles() throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    let owned = temporaryDirectory.appendingPathComponent("SimpleMusicDownload-owned")
    let unrelated = temporaryDirectory.appendingPathComponent("other-app.tmp")
    let similarlyNamedDirectory = temporaryDirectory.appendingPathComponent(
        "SimpleMusicDownload-directory",
        isDirectory: true
    )
    try Data("partial".utf8).write(to: owned)
    try Data("keep".utf8).write(to: unrelated)
    try FileManager.default.createDirectory(at: similarlyNamedDirectory, withIntermediateDirectories: true)
    let service = DownloadRecoveryService(
        fileStore: fileStore,
        musicStore: musicStore,
        temporaryDirectory: temporaryDirectory
    )

    try service.cleanupRetainedTemporaryFiles()

    XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: similarlyNamedDirectory.path))
}
```

预期 RED：缺少 `contains(fileName:)` 和 `DownloadRecoveryService`。

- [ ] **Step 4: 实现索引优先恢复服务**

`LocalMusicStore` 使用现有 background context 入口实现：

```swift
func contains(fileName: String) async throws -> Bool {
    try await fetchTracksAsync().contains { track in
        guard case let .downloaded(indexedName) = track.source else { return false }
        return indexedName == fileName
    }
}
```

`DownloadRecoveryService.swift`：

```swift
struct DownloadRecoveryService {
    let fileStore: DownloadFileStore
    let musicStore: LocalMusicStore
    var temporaryDirectory = FileManager.default.temporaryDirectory

    func reconcile(fileName: String) async throws -> DownloadQueue.RecoveryDisposition {
        if try await musicStore.contains(fileName: fileName) { return .indexed }
        do {
            try fileStore.removeFile(named: fileName)
        } catch DownloadFileStoreError.fileNotFound {
            // 文件已不存在等价于清理完成；其他安全或 I/O 错误必须上抛。
        }
        return .cleaned
    }

    func cleanupRetainedTemporaryFiles() throws {
        for url in try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) where url.lastPathComponent.hasPrefix("SimpleMusicDownload-") {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true || values.isSymbolicLink == true else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}
```

- [ ] **Step 5: 写进程终止恢复 RED**

预置 JSON 中一个 `.queued`、一个 `.downloading`、一个 `.failure`；其中下载中任务带 `reservedFileName`：

```swift
func testLaunchMarksUnfinishedInterruptedWithoutStartingNetwork() throws {
    let store = SpyQueueStore(initialJobs: [queuedJob, downloadingJob, failedJob])
    let operation = ControlledQueueDownloadOperation()
    let queue = makeQueue(store: store, operation: operation)

    XCTAssertEqual(job(queuedJob.id, in: queue).state, .interrupted)
    XCTAssertEqual(job(downloadingJob.id, in: queue).state, .interrupted)
    XCTAssertEqual(job(downloadingJob.id, in: queue).progress, 0)
    XCTAssertEqual(job(failedJob.id, in: queue).state, .failure)
    XCTAssertEqual(operation.startedURLs, [])
}

func testRecoveryRemovesIndexedRecordButKeepsInterruptedCleanedJob() {
    let recovery = ControlledRecovery()
    recovery.results["indexed.m4a"] = .success(.indexed)
    recovery.results["orphan.m4a"] = .success(.cleaned)
    let queue = makeQueue(store: persistedStore, recovery: recovery.perform)

    waitUntil { recovery.fileNames.count == 2 }
    XCTAssertNil(queue.jobs.first { $0.reservedFileName == "indexed.m4a" })
    XCTAssertEqual(job(orphanID, in: queue).state, .interrupted)
    XCTAssertNil(job(orphanID, in: queue).reservedFileName)
}
```

再添加 `testRecoveryErrorKeepsInterruptedRecordAndRetryReconcilesBeforeNetwork`，证明未知 I/O 错误不丢记录、不启动请求，用户重试时先重新清理。

恢复测试使用以下两个明确 seam，不访问真实 Application Support：

```swift
@MainActor
private final class SpyQueueStore: DownloadQueuePersisting {
    var loadedJobs: [DownloadJob]
    private(set) var saves = [[DownloadJob]]()

    init(initialJobs: [DownloadJob]) {
        loadedJobs = initialJobs
    }

    func load() throws -> [DownloadJob] { loadedJobs }

    func save(_ jobs: [DownloadJob]) throws {
        loadedJobs = jobs
        saves.append(jobs)
    }
}

@MainActor
private final class ControlledRecovery {
    var results = [String: Result<DownloadQueue.RecoveryDisposition, Error>]()
    private(set) var fileNames = [String]()

    func perform(_ fileName: String) async throws -> DownloadQueue.RecoveryDisposition {
        fileNames.append(fileName)
        return try XCTUnwrap(results[fileName]).get()
    }
}
```

- [ ] **Step 6: 实现启动 normalization 和异步 recovery**

`DownloadQueue.init` 同步加载后立即把 `.queued/.downloading` 改为 `.interrupted`、进度归零并发布；然后启动单个 recovery Task。对每个 `reservedFileName`：

- `.indexed`：从队列和账本移除，不删除文件。
- `.cleaned`：保留 `.interrupted`，清空 `reservedFileName` 并持久化。
- throw：保留 `.interrupted` 和原文件名，记 `.recovery` 原因；不启动网络。

`retry(id:)` 遇到未清空 reservation 时先异步再次调用 recovery，只有 `.cleaned` 才把新 attempt 排入 `.queued`；`.indexed` 直接移除旧任务。

- [ ] **Step 7: 在 AppEnvironment 创建唯一队列**

增加 lazy property，文件 store 创建失败时只降级为内存账本并记录日志，不影响下载能力：

```swift
lazy var downloadQueue: DownloadQueue? = {
    guard let downloadManager, let downloadFileStore else { return nil }
    let store: DownloadQueueStore
    do {
        store = try .applicationSupport()
    } catch {
        NSLog("下载队列账本不可用，改用内存状态：%@", String(describing: error))
        store = DownloadQueueStore(fileURL: nil)
    }
    let recovery = DownloadRecoveryService(
        fileStore: downloadFileStore,
        musicStore: localMusicStore
    )
    do {
        try recovery.cleanupRetainedTemporaryFiles()
    } catch {
        NSLog("下载临时文件清理失败：%@", String(describing: error))
    }
    return DownloadQueue(
        store: store,
        operation: { url, progress, onReservation in
            try await downloadManager.download(
                from: url,
                progress: progress,
                onReservation: onReservation
            )
        },
        settingsStore: settingsStore,
        recovery: recovery.reconcile(fileName:),
        onReload: { [weak libraryViewModel] in
            Task { await libraryViewModel?.requestReload() }
        },
        onPlay: { [playbackCoordinator] track in
            try? playbackCoordinator.play(queue: [track], startAt: 0)
        }
    )
}()
```

不要在 `AppEnvironment.init` 强制访问 lazy queue，避免下载存储降级影响系统音乐启动。

- [ ] **Step 8: 跑聚焦回归并提交**

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO \
  -only-testing:SimpleMusicTests/DownloadQueueTests \
  -only-testing:SimpleMusicTests/DownloadManagerConcurrencyTests \
  -only-testing:SimpleMusicTests/LocalMusicStoreTests \
  -only-testing:SimpleMusicTests/AppCoordinatorTests \
  test CODE_SIGNING_ALLOWED=NO
git diff --check
git add SimpleMusic/Downloads/DownloadRecoveryService.swift \
  SimpleMusic/Downloads/DownloadManager.swift \
  SimpleMusic/Downloads/DownloadQueue.swift \
  SimpleMusic/Persistence/LocalMusicStore.swift \
  SimpleMusic/App/AppEnvironment.swift \
  SimpleMusicTests/DownloadManagerConcurrencyTests.swift \
  SimpleMusicTests/DownloadQueueTests.swift \
  SimpleMusicTests/LocalMusicStoreTests.swift
git commit -m 'feat: 接入下载事务恢复'
```

预期：四个 focused suite 全绿；旧 `DownloadManager.download(from:progress:)` 调用全部继续编译并通过。

---

### Task 4: 重构下载任务列表、三语言文案与根入口

**Files:**
- Create: `SimpleMusic/UI/Download/DownloadJobCell.swift`
- Modify: `SimpleMusic/UI/Download/DownloadSheetViewController.swift`
- Modify: `SimpleMusic/App/AppCoordinator.swift`
- Modify: `SimpleMusic/en.lproj/Localizable.strings`
- Modify: `SimpleMusic/zh-Hans.lproj/Localizable.strings`
- Modify: `SimpleMusic/zh-Hant.lproj/Localizable.strings`
- Modify: `SimpleMusicTests/DownloadAndSettingsFlowTests.swift`
- Modify: `SimpleMusicTests/AppCoordinatorTests.swift`
- Modify: `SimpleMusicTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: Task 3 的 `AppEnvironment.downloadQueue` 和 Task 2 的队列 publisher/actions。
- Produces:
  - `DownloadSheetViewController.init(downloadQueue:)`
  - `DownloadSheetViewController.downloadQueue`
  - `DownloadJobCell.render(job:)`
  - 行级 accessibility identifiers：`download.job.<UUID>.*`

- [ ] **Step 1: 写关闭页面不取消、重开复用和多任务列表 RED**

替换旧单状态页面测试，不再断言 `DownloadViewState`：

```swift
func testClosingAndReleasingSheetDoesNotCancelActiveQueueJob() throws {
    let operation = ControlledQueueDownloadOperation()
    let queue = makeQueue(operation: operation)
    var controller: DownloadSheetViewController? = DownloadSheetViewController(downloadQueue: queue)
    controller?.loadViewIfNeeded()
    try submit("https://example.com/a.m4a", in: try XCTUnwrap(controller))
    waitUntil { operation.startedURLs.count == 1 }

    controller?.presentationControllerDidDismiss(UIPresentationController(
        presentedViewController: controller!, presenting: nil
    ))
    controller = nil

    XCTAssertEqual(operation.cancellationCount, 0)
    XCTAssertEqual(queue.jobs.first?.state, .downloading)
}

func testReopenedSheetShowsSameJobsAndLatestProgress() throws {
    let operation = ControlledQueueDownloadOperation()
    let queue = makeQueue(operation: operation)
    let first = DownloadSheetViewController(downloadQueue: queue)
    first.loadViewIfNeeded()
    let sourceURL = URL(string: "https://example.com/a.m4a")!
    try submit(sourceURL.absoluteString, in: first)
    let id = try XCTUnwrap(queue.jobs.first?.id)
    operation.report(url: sourceURL, attempt: 0, progress: 0.37)

    let reopened = DownloadSheetViewController(downloadQueue: queue)
    reopened.loadViewIfNeeded()
    layout(reopened, size: CGSize(width: 390, height: 844))

    XCTAssertEqual(progressValue("download.job.\(id).progress", in: reopened), 0.37, accuracy: 0.001)
    XCTAssertTrue(labelTexts(in: reopened).contains(L10n.format("download.queue.progress", 37)))
}
```

增加 `testSubmittingFourURLsRendersFourRowsWithFourthWaiting`，预期旧控制器只能创建一个任务而 RED。

- [ ] **Step 2: 写逐项取消、重试、删除和播放 RED**

```swift
func testRowActionsOnlyAffectMatchingJobID() throws {
    let harness = makeQueueSheetHarness(maximumActiveCount: 1)
    let first = try harness.queue.enqueue(url("one.m4a"))
    let second = try harness.queue.enqueue(url("two.m4a"))
    harness.controller.loadViewIfNeeded()

    try tap("download.job.\(second).cancel", in: harness.controller)
    XCTAssertEqual(job(second, in: harness.queue).state, .cancelled)
    XCTAssertEqual(job(first, in: harness.queue).state, .downloading)

    try tap("download.job.\(second).retry", in: harness.controller)
    XCTAssertEqual(job(second, in: harness.queue).state, .queued)
}
```

分别补成功行 `play` 只执行一次、终态 `remove` 只移除对应记录、非法 URL 只显示输入错误且不增加 job 的测试。

同时先写任务行无障碍测试；它读取现有 accessibility identifier，不用截图或像素级布局断言：

```swift
func testDownloadingRowExposesLocalizedProgressAndMinimumActionTarget() throws {
    let harness = makeQueueSheetHarness()
    let sourceURL = url("voiceover.m4a")
    let id = try harness.queue.enqueue(sourceURL)
    waitUntil { harness.operation.attemptCount(url: sourceURL) == 1 }
    harness.operation.report(url: sourceURL, attempt: 0, progress: 0.62)
    harness.controller.loadViewIfNeeded()
    layout(harness.controller, size: CGSize(width: 390, height: 844))

    let progress = try XCTUnwrap(
        view("download.job.\(id).progress", in: harness.controller.view)
    )
    let cancel = try XCTUnwrap(
        view("download.job.\(id).cancel", in: harness.controller.view) as? UIButton
    )
    XCTAssertEqual(
        progress.accessibilityValue,
        L10n.format("download.queue.accessibility.progress", 62)
    )
    XCTAssertTrue(cancel.titleLabel?.adjustsFontForContentSizeCategory == true)
    XCTAssertTrue(hasMinimumHeight(44, view: cancel))
}
```

- [ ] **Step 3: 实现可滚动列表控制器与任务 cell**

`DownloadSheetViewController` 只保留：

```swift
@MainActor
final class DownloadSheetViewController: UIViewController, UITextFieldDelegate, UIAdaptivePresentationControllerDelegate {
    let downloadQueue: DownloadQueue
    private var jobs = [DownloadJob]()
    private var cancellables = Set<AnyCancellable>()
    private let urlField = UITextField()
    private let inputErrorLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)

    init(downloadQueue: DownloadQueue) {
        self.downloadQueue = downloadQueue
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }
}
```

布局为顶部输入 stack + 下方 table；URL 成功入队后清空输入框并保留页面。close 和 `presentationControllerDidDismiss` 不调用 `downloadQueue.cancel`。`deinit` 只让 Combine subscription 释放。

`DownloadJobCell` 使用 SnapKit、Dynamic Type 和至少 44pt 操作按钮。根据状态显示：

- queued：等待中，无进度变化，可取消。
- downloading：进度条、百分比、取消。
- success：完成歌曲名、立即播放、删除记录。
- failure：错误、重试、删除记录。
- cancelled/interrupted：状态、重试、删除记录。

cell 的 closure 每次 render 前重置，使用 job ID 回调，禁止捕获 indexPath 后因列表变化操作错任务。

- [ ] **Step 4: 增加三语言队列文案**

三套资源必须加入完全相同的 key：

```text
download.queue.add
download.queue.empty
download.queue.waiting
download.queue.interrupted
download.queue.cancelled
download.queue.retry
download.queue.remove
download.queue.progress
download.queue.accessibility.progress
download.queue.error.recovery
```

代表值：

```text
en:      "download.queue.waiting" = "Waiting";
zh-Hans: "download.queue.waiting" = "等待中";
zh-Hant: "download.queue.waiting" = "等待中";

en:      "download.queue.interrupted" = "Interrupted. Retry to start again.";
zh-Hans: "download.queue.interrupted" = "已中断，重试后将重新下载。";
zh-Hant: "download.queue.interrupted" = "已中斷，重試後將重新下載。";

en:      "download.queue.progress" = "%1$d%% downloaded";
zh-Hans: "download.queue.progress" = "已下载 %1$d%%";
zh-Hant: "download.queue.progress" = "已下載 %1$d%%";
```

错误原因由 cell 根据 `DownloadJob.FailureReason` 调用 `L10n.text`，JSON 不保存翻译结果。`LocalizationTests` 继续验证三套 key 和占位符完全一致，并增加上述 progress key 的三语格式测试。

- [ ] **Step 5: 把根入口改为共享队列并取得 RED/GREEN**

在 `AppCoordinatorTests` 先增加：

```swift
func testPhoneAndPadDownloadFactoriesUseEnvironmentSharedQueue() throws {
    let environment = makeEnvironmentWithDownloadStorage()
    let dependencies = AppRootDependencies(environment: environment)

    let first = try XCTUnwrap(dependencies.makeDownloadViewController() as? DownloadSheetViewController)
    let second = try XCTUnwrap(dependencies.makeDownloadViewController() as? DownloadSheetViewController)

    XCTAssertTrue(first.downloadQueue === environment.downloadQueue)
    XCTAssertTrue(second.downloadQueue === environment.downloadQueue)
    XCTAssertTrue(first.downloadQueue === second.downloadQueue)
}
```

预期旧 factory 创建单任务 controller 而失败。最小修改 `AppRootDependencies.init(environment:)`：

```swift
makeDownloadViewController = {
    guard let downloadQueue = environment.downloadQueue else {
        return DownloadUnavailableViewController(
            message: environment.downloadStorageWarning
                ?? L10n.text("storage.download.unavailable_short")
        )
    }
    return DownloadSheetViewController(downloadQueue: downloadQueue)
}
```

`AppCoordinator.wireLibraryActions` 的 iPhone page sheet 与 iPad root 路由保持现状，只更换内容控制器。

- [ ] **Step 6: 跑 UI、根接线、本地化和下载回归后提交**

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO \
  -only-testing:SimpleMusicTests/DownloadAndSettingsFlowTests \
  -only-testing:SimpleMusicTests/AppCoordinatorTests \
  -only-testing:SimpleMusicTests/LocalizationTests \
  -only-testing:SimpleMusicTests/DownloadQueueTests \
  test CODE_SIGNING_ALLOWED=NO
git diff --check
git add SimpleMusic/UI/Download/DownloadJobCell.swift \
  SimpleMusic/UI/Download/DownloadSheetViewController.swift \
  SimpleMusic/App/AppCoordinator.swift \
  SimpleMusic/en.lproj/Localizable.strings \
  SimpleMusic/zh-Hans.lproj/Localizable.strings \
  SimpleMusic/zh-Hant.lproj/Localizable.strings \
  SimpleMusicTests/DownloadAndSettingsFlowTests.swift \
  SimpleMusicTests/AppCoordinatorTests.swift \
  SimpleMusicTests/LocalizationTests.swift
git commit -m 'feat: 重构下载任务列表'
```

预期：四个 suite 全绿；生产 Swift 汉字 literal 审计仍为 0 omission。

---

### Task 5: 全量验证、边界审计与交付报告

**Files:**
- Create: `docs/testing/2026-08-21-download-queue-verification.md`
- Modify only if a verified defect exists: Task 1–4 owned production/test files

**Interfaces:**
- Consumes: Task 1–4 完成的下载队列、UI 和测试。
- Produces: 可复核的 focused/full/build/产物证据和最终中文验证提交。

- [ ] **Step 1: 运行三组 focused 行为验证**

```bash
set -o pipefail
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO \
  -only-testing:SimpleMusicTests/DownloadQueueTests \
  -only-testing:SimpleMusicTests/DownloadManagerConcurrencyTests \
  -only-testing:SimpleMusicTests/DownloadFileStoreTests \
  -only-testing:SimpleMusicTests/LocalMusicStoreTests \
  test CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee /tmp/download-queue-domain-final.log

xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO \
  -only-testing:SimpleMusicTests/DownloadAndSettingsFlowTests \
  -only-testing:SimpleMusicTests/AppCoordinatorTests \
  test CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee /tmp/download-queue-ui-final.log

xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO \
  -only-testing:SimpleMusicTests/LocalizationTests \
  test CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee /tmp/download-queue-localization-final.log
```

预期：三条命令 exit 0、`** TEST SUCCEEDED **`；不得只依据日志中的单个 testcase 断言整体通过。

- [ ] **Step 2: 运行全量测试**

```bash
set -o pipefail
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO test CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee /tmp/download-queue-full-final.log
```

预期：exit 0、所有 XCTest passed、0 failed、0 skipped。用生成的 `.xcresult` 机器汇总计数，不从 `rg` 行数猜测总数。

- [ ] **Step 3: 构建模拟器与设备目标**

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee /tmp/download-queue-simulator-build.log

xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee /tmp/download-queue-device-build.log
```

预期：两者 exit 0、`** BUILD SUCCEEDED **`。记录环境型 Metal/AppIntents warning；若出现本次 Swift warning、方向 validation 或资源缺失，先修复并重跑对应命令。

- [ ] **Step 4: 做静态所有权和安全审计**

```bash
rg -n 'downloadTask|cancelActiveDownload|presentationControllerDidDismiss|deinit' \
  SimpleMusic/UI/Download SimpleMusic/Downloads
rg -n 'maximumActiveCount|limit: 3|reservedFileName|interrupted|removeFile\(named:' \
  SimpleMusic/Downloads SimpleMusic/App
rg -n 'download\.queue\.' SimpleMusic/{en,zh-Hans,zh-Hant}.lproj/Localizable.strings
git diff --check
git status --short
```

必须确认：

- 页面中没有 owning/cancelling transfer Task。
- `DownloadQueue` 是唯一调度所有者，限制为 3；Manager 仍保留 permit 安全网。
- recovery 先查索引，且只把受控叶子名交给 `DownloadFileStore`。
- 三语言 key 集合一致，没有直接硬编码的用户可见新文案。
- status 中用户原有脏文件保持未暂存、内容未被改写。

- [ ] **Step 5: 写验证报告并提交**

`docs/testing/2026-08-21-download-queue-verification.md` 必须记录：

- 最终 commit 范围。
- focused/full 的命令、exit code、xcresult 路径和机器汇总计数。
- simulator/device build 结果和 warning 分类。
- 3 并发、FIFO、关闭页面继续、重开进度、逐项取消、自动播放、终止恢复、安全清理的对应 testcase 名。
- 明确边界：普通 session 在系统后台执行时间结束后可暂停；进程终止后不续传，任务仅恢复成 interrupted。
- 真机弱网、系统后台冻结时机和真实大文件传输标为发布前设备集成检查，不冒充 XCTest 已覆盖。

提交：

```bash
git add docs/testing/2026-08-21-download-queue-verification.md
git diff --cached --check
git commit -m 'test: 记录下载队列验证结果'
git status --short
```

最终 status 只允许保留开始执行前已记录的用户文件；不得把它们加入任何 commit。

---

## Spec Coverage Map

| 设计要求 | 实施任务 |
| --- | --- |
| 应用级唯一队列与页面关闭继续 | Task 3、Task 4 |
| 最多 3 并发、FIFO、独立进度 | Task 2 |
| 逐项取消、重试、删除、立即播放 | Task 2、Task 4 |
| JSON 账本和损坏降级 | Task 1、Task 3 |
| 进程终止后 interrupted、从 0 重试 | Task 3 |
| reservation 索引优先恢复与安全清理 | Task 3 |
| 单任务自动播放、多任务不抢占 | Task 2 |
| iPhone/iPad 共用队列和列表 | Task 4 |
| 三语言、Dynamic Type、VoiceOver、44pt | Task 4 |
| 全量测试、sim/device build、交付边界 | Task 5 |

## 执行注意事项

- 每个 Task 开始前先读取本计划、设计规格和该任务涉及的现有文件，不能依赖前一执行者的口头上下文。
- 每次 RED 必须让测试实际执行或明确编译失败于缺失的生产接口；测试 helper 自身错误不算 RED。
- 若 CoreSimulator 报连接、clone 或设备状态错误，先使用 `superpowers:systematic-debugging` 区分环境故障和产品失败；不要通过重复并发启动 `xcodebuild` 掩盖问题。
- 每个 Task 完成后做一次需求符合性审查和代码质量审查，再开始下一 Task。
- 任何需要删除下载根内真实文件的测试都使用唯一临时目录；绝不把项目目录、用户主目录或未解析的 glob 作为清理目标。
