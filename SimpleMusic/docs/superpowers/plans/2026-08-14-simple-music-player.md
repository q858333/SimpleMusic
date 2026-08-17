# SimpleMusic 本地音乐播放器 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建可在 iPhone/iPad 竖屏运行的“听见”本地音乐播放器，统一浏览和播放系统音乐与 URL 下载音频，并支持后台、锁屏和耳机控制。

**Architecture:** UIKit 纯代码界面由 AppCoordinator 组织，SnapKit 负责布局。MusicLibraryService、DownloadManager、LocalMusicStore 与 PlaybackCoordinator 分离；PlaybackCoordinator 在 MPMusicPlayerController 和 AVPlayer 后端之间切换，并把统一状态交给界面与 NowPlayingService。

**Tech Stack:** Swift 5、UIKit、CocoaPods、SnapKit、MediaPlayer、AVFoundation、URLSession、Core Data、Combine、XCTest，最低 iOS 15.0。

## Global Constraints

- iPhone 和 iPad 全应用只支持 `UIInterfaceOrientationPortrait`。
- 工程层、Target 层和 Podfile 的最低版本统一为 iOS 15.0。
- CocoaPods 首版仅引入 SnapKit；不恢复旧模板 Pod。
- 正式界面使用纯代码；只保留 LaunchScreen storyboard。
- 仅下载 HTTP/HTTPS 的 MP3、M4A、WAV 直链，不解析网页或音乐平台。
- DownloadManager 最多同时执行 3 个下载任务，超出任务排队等待。
- 新增生产代码为职责、API 边界和非显然状态转换添加简洁中文注释，避免逐行解释。
- 不实现账号、云同步、后台断点下载、歌词、均衡器或在线曲库。
- 命令均从 `/Users/db/Documents/git/my/music/SimpleMusic/SimpleMusic` 执行。
- 用户已有的 Swift 迁移与 CocoaPods 删除记录属于基线；每次提交只暂存任务列出的文件，禁止重置或恢复其它变更。

---

## 文件结构

```text
SimpleMusic/
  App/
    AppCoordinator.swift              # 根导航与依赖装配
    AppEnvironment.swift              # 服务对象生命周期
  Domain/
    MusicTrack.swift                  # 统一歌曲模型
    PlaybackSnapshot.swift            # UI 可观察播放状态
  Library/
    MusicLibraryService.swift         # MPMediaLibrary/MPMediaQuery
  Downloads/
    AudioDownloadValidator.swift      # URL、扩展名、MIME 校验
    DownloadFileStore.swift            # 私有目录与唯一文件名
    DownloadManager.swift              # URLSession 下载流程
  Persistence/
    DownloadedTrackEntity.swift        # Core Data typed entity
    LocalMusicStore.swift              # 下载索引 CRUD
    SettingsStore.swift                # UserDefaults 设置
  Playback/
    PlaybackBackend.swift              # 播放后端协议
    LocalPlaybackBackend.swift         # AVPlayer 后端
    SystemPlaybackBackend.swift        # MPMusicPlayerController 后端
    PlaybackCoordinator.swift          # 队列与后端切换
    NowPlayingService.swift            # 锁屏与远程命令
  UI/
    DesignSystem/Theme.swift
    Permission/PermissionViewController.swift
    Main/MainTabBarController.swift
    Main/PadRootViewController.swift
    Library/LibraryViewController.swift
    Library/LibraryViewModel.swift
    Library/TrackCell.swift
    Search/SearchViewController.swift
    Player/MiniPlayerView.swift
    Player/PlayerViewController.swift
    Player/NowPlayingPanelController.swift
    Download/DownloadSheetViewController.swift
    Settings/SettingsViewController.swift
    Settings/AboutViewController.swift
SimpleMusicTests/
  MusicTrackTests.swift
  AudioDownloadValidatorTests.swift
  DownloadFileStoreTests.swift
  LocalMusicStoreTests.swift
  SettingsStoreTests.swift
  PlaybackCoordinatorTests.swift
```

---

### Task 1: 固化 Swift、CocoaPods、iOS 15 与测试基线

**Files:**
- Modify: `Podfile`
- Modify: `SimpleMusic.xcodeproj/project.pbxproj`
- Modify: `SimpleMusic/Info.plist`
- Modify: `SimpleMusic/SceneDelegate.swift`
- Create: `SimpleMusic/App/AppEnvironment.swift`
- Create: `SimpleMusicTests/MusicTrackTests.swift`
- Regenerate: `Podfile.lock`, `Pods/`, `SimpleMusic.xcworkspace/`

**Interfaces:**
- Produces: `AppEnvironment.shared`, `.xcworkspace` 构建入口，以及可运行的 `SimpleMusicTests` target。

- [ ] **Step 1: 写入最小失败测试并创建测试 Target**

```swift
import XCTest
@testable import SimpleMusic

final class MusicTrackTests: XCTestCase {
    func testUnknownArtistCopyRequiresMusicTrackType() {
        XCTAssertEqual(MusicTrack.unknownArtist, "未知艺人")
    }
}
```

在 `project.pbxproj` 中新增 `SimpleMusicTests` unit-test target、Sources phase、与 App target dependency，并将最低版本设置为 15.0。

- [ ] **Step 2: 验证测试因缺少类型而失败**

Run: `xcodebuild -project SimpleMusic.xcodeproj -scheme SimpleMusic -destination 'generic/platform=iOS Simulator' build-for-testing CODE_SIGNING_ALLOWED=NO`

Expected: FAIL，错误包含 `Cannot find 'MusicTrack' in scope`。

- [ ] **Step 3: 精简 Podfile 并安装 SnapKit**

```ruby
platform :ios, '15.0'
use_frameworks! :linkage => :static

target 'SimpleMusic' do
  pod 'SnapKit', '~> 5.7'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    end
  end
end
```

Run: `pod install`

Expected: `Pod installation complete!`，生成 `SimpleMusic.xcworkspace`。

- [ ] **Step 4: 统一工程配置**

将 Project、App Target 和 Tests Target 的 `IPHONEOS_DEPLOYMENT_TARGET` 设置为 `15.0`；iPhone/iPad 方向均只保留 Portrait；加入 `audio` 后台模式和 `NSAppleMusicUsageDescription = “用于读取并播放你设备上的音乐。”`。SceneDelegate 暂时继续加载现有 ViewController，后续 Task 8 切换到 AppCoordinator。

- [ ] **Step 5: 增加最小依赖容器**

```swift
import Foundation

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()
    private init() {}
}
```

- [ ] **Step 6: 验证 workspace 与 Pod 集成**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'generic/platform=iOS Simulator' build-for-testing CODE_SIGNING_ALLOWED=NO`

Expected: 唯一预期失败仍为 `MusicTrack` 未定义；不能出现 SnapKit、Pods xcconfig 或 deployment target 错误。

- [ ] **Step 7: 提交基线**

```bash
git add Podfile Podfile.lock Pods SimpleMusic.xcworkspace SimpleMusic.xcodeproj/project.pbxproj SimpleMusic/Info.plist SimpleMusic/SceneDelegate.swift SimpleMusic/App/AppEnvironment.swift SimpleMusicTests/MusicTrackTests.swift
git commit -m "build: configure Swift CocoaPods baseline"
```

---

### Task 2: 统一歌曲模型与设置持久化

**Files:**
- Create: `SimpleMusic/Domain/MusicTrack.swift`
- Create: `SimpleMusic/Domain/PlaybackSnapshot.swift`
- Create: `SimpleMusic/Persistence/SettingsStore.swift`
- Modify: `SimpleMusicTests/MusicTrackTests.swift`
- Create: `SimpleMusicTests/SettingsStoreTests.swift`

**Interfaces:**
- Produces: `MusicTrack`, `MusicSource`, `PlaybackSnapshot`, `PlaybackStatus`, `SettingsStore`。

- [ ] **Step 1: 写模型和设置失败测试**

```swift
func testDownloadedTrackKeepsStableIdentity() {
    let track = MusicTrack(id: "local-1", title: "歌", artist: "艺人", album: "专辑", duration: 61, artworkData: nil, source: .downloaded(fileName: "local-1.m4a"))
    XCTAssertEqual(track.id, "local-1")
    XCTAssertEqual(track.source, .downloaded(fileName: "local-1.m4a"))
}
```

```swift
func testSettingsPersistAcrossInstances() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    SettingsStore(defaults: defaults).allowsCellularDownloads = true
    XCTAssertTrue(SettingsStore(defaults: defaults).allowsCellularDownloads)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO`

Expected: FAIL，缺少 `MusicTrack`、`MusicSource` 和 `SettingsStore`。

- [ ] **Step 3: 实现领域类型**

```swift
enum MusicSource: Hashable, Codable {
    case system(persistentID: UInt64)
    case downloaded(fileName: String)
}

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

enum PlaybackStatus: Equatable { case idle, loading, playing, paused, failed(String) }

struct PlaybackSnapshot: Equatable {
    var status: PlaybackStatus = .idle
    var track: MusicTrack?
    var elapsed: TimeInterval = 0
    var duration: TimeInterval = 0
    var queueIndex: Int?
    var queueCount = 0
}
```

- [ ] **Step 4: 实现 SettingsStore**

```swift
struct SettingsStore {
    private enum Key { static let cellular = "allowsCellularDownloads"; static let autoPlay = "autoPlayAfterDownload" }
    let defaults: UserDefaults
    var allowsCellularDownloads: Bool {
        get { defaults.bool(forKey: Key.cellular) }
        nonmutating set { defaults.set(newValue, forKey: Key.cellular) }
    }
    var autoPlayAfterDownload: Bool {
        get { defaults.bool(forKey: Key.autoPlay) }
        nonmutating set { defaults.set(newValue, forKey: Key.autoPlay) }
    }
}
```

- [ ] **Step 5: 运行测试并提交**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO`

Expected: PASS。

```bash
git add SimpleMusic/Domain SimpleMusic/Persistence/SettingsStore.swift SimpleMusicTests/MusicTrackTests.swift SimpleMusicTests/SettingsStoreTests.swift
git commit -m "feat: add music domain and settings"
```

---

### Task 3: 音频直链校验与安全文件存储

**Files:**
- Create: `SimpleMusic/Downloads/AudioDownloadValidator.swift`
- Create: `SimpleMusic/Downloads/DownloadFileStore.swift`
- Create: `SimpleMusicTests/AudioDownloadValidatorTests.swift`
- Create: `SimpleMusicTests/DownloadFileStoreTests.swift`

**Interfaces:**
- Produces: `AudioDownloadValidator.validate(url:)`, `validate(response:sourceURL:)`, `DownloadFileStore.destinationURL(suggestedName:)`。

- [ ] **Step 1: 写失败测试**

```swift
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
```

```swift
func testDuplicateNamesProduceDifferentDestinations() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try DownloadFileStore(rootURL: root)
    let first = store.destinationURL(suggestedName: "song.mp3")
    try Data().write(to: first)
    XCTAssertNotEqual(first, store.destinationURL(suggestedName: "song.mp3"))
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO`

Expected: FAIL，缺少两个实现类型。

- [ ] **Step 3: 实现明确白名单**

```swift
struct AudioDownloadValidator {
    static let extensions = Set(["mp3", "m4a", "wav"])
    static let mimeTypes = Set(["audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/wav", "audio/x-wav"])
    func validate(url: URL) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              Self.extensions.contains(url.pathExtension.lowercased()) else { throw DownloadError.unsupportedURL }
    }
    func validate(response: URLResponse, sourceURL: URL) throws {
        try validate(url: sourceURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let mime = http.mimeType?.lowercased(), Self.mimeTypes.contains(mime) else { throw DownloadError.unsupportedResponse }
    }
}
```

`DownloadFileStore` 创建根目录、清理路径字符，并在冲突时追加短 UUID；绝不覆盖现有文件。

- [ ] **Step 4: 运行测试并提交**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO`

Expected: PASS。

```bash
git add SimpleMusic/Downloads/AudioDownloadValidator.swift SimpleMusic/Downloads/DownloadFileStore.swift SimpleMusicTests/AudioDownloadValidatorTests.swift SimpleMusicTests/DownloadFileStoreTests.swift
git commit -m "feat: validate and store audio downloads"
```

---

### Task 4: Core Data 下载索引与下载流程

**Files:**
- Modify: `SimpleMusic/SimpleMusic.xcdatamodeld/SimpleMusic.xcdatamodel/contents`
- Create: `SimpleMusic/Persistence/DownloadedTrackEntity.swift`
- Create: `SimpleMusic/Persistence/LocalMusicStore.swift`
- Create: `SimpleMusic/Downloads/DownloadManager.swift`
- Create: `SimpleMusicTests/LocalMusicStoreTests.swift`
- Create: `SimpleMusicTests/DownloadManagerConcurrencyTests.swift`
- Modify: `SimpleMusic/App/AppEnvironment.swift`

**Interfaces:**
- Produces: `LocalMusicStore.fetchTracks() throws -> [MusicTrack]`、`insert(_ metadata: DownloadedTrackMetadata) throws -> MusicTrack`、`delete(id: String) throws`；`DownloadManager.download(from:progress:) async throws -> MusicTrack`。

- [ ] **Step 1: 写内存 Core Data 失败测试**

```swift
func testInsertFetchAndDeleteDownloadedTrack() throws {
    let store = try LocalMusicStore.inMemory()
    let metadata = DownloadedTrackMetadata(id: "one", fileName: "one.mp3", title: "One", artist: "A", album: "B", duration: 12)
    _ = try store.insert(metadata)
    XCTAssertEqual(try store.fetchTracks().map(\.id), ["one"])
    try store.delete(id: "one")
    XCTAssertTrue(try store.fetchTracks().isEmpty)
}
```

使用可控的 `AudioDownloadClient` fake 同时提交 4 个下载，断言开始执行的任务始终不超过 3；释放一个任务后第 4 个才开始。另测取消等待中的第 4 个任务不会占用名额。

- [ ] **Step 2: 运行并确认失败**

Expected: FAIL，缺少 `DownloadedTrackMetadata` 与 `LocalMusicStore`。

- [ ] **Step 3: 增加 Core Data schema 与 typed entity**

实体名 `DownloadedTrackEntity`，字段为 `id:String`、`fileName:String`、`title:String`、`artist:String`、`album:String`、`duration:Double`、`createdAt:Date`、`lastPlayedAt:Date?`；`id` 设置唯一约束，Codegen 为 Manual/None。

- [ ] **Step 4: 实现事务边界**

`LocalMusicStore.insert(_:)` 在 context performAndWait 中写入并保存；`delete(id:)` 只删除索引，由 DownloadManager 在索引成功写入前保管文件，任一阶段失败都移除新文件。

- [ ] **Step 5: 实现 DownloadManager**

```swift
@MainActor
func download(from url: URL, progress: @escaping (Double) -> Void) async throws -> MusicTrack
```

实现顺序固定为：URL 校验 → 创建遵守 `allowsCellularAccess` 的 URLSession → 下载临时文件 → 响应校验 → 移动到 DownloadFileStore → AVAsset 读取元数据 → Core Data 写入。失败时删除目标文件，成功后返回持久化后的 `MusicTrack`。

使用 actor 管理活动下载计数和 FIFO 等待队列，硬上限为 3；成功、失败和取消都必须在 defer 路径释放名额并唤醒下一项。

- [ ] **Step 6: 运行测试与构建并提交**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO`

Expected: PASS。

```bash
git add SimpleMusic/SimpleMusic.xcdatamodeld SimpleMusic/Persistence SimpleMusic/Downloads/DownloadManager.swift SimpleMusic/App/AppEnvironment.swift SimpleMusicTests/LocalMusicStoreTests.swift SimpleMusicTests/DownloadManagerConcurrencyTests.swift
git commit -m "feat: persist downloaded music"
```

---

### Task 5: 系统音乐资料库服务

**Files:**
- Create: `SimpleMusic/Library/MusicLibraryService.swift`
- Create: `SimpleMusicTests/MusicLibraryServiceMappingTests.swift`
- Modify: `SimpleMusic/App/AppEnvironment.swift`

**Interfaces:**
- Produces: `authorizationStatus: MPMediaLibraryAuthorizationStatus`、`requestAuthorization() async -> MPMediaLibraryAuthorizationStatus`、`fetchTracks() throws -> [MusicTrack]`、`mediaItem(for persistentID: UInt64) -> MPMediaItem?`。

- [ ] **Step 1: 写纯映射失败测试**

定义内部 `SystemTrackMetadata`，测试空 title/artist/album 使用文件名式标题和未知文案，persistentID 映射为 `system-<id>`。

```swift
let track = MusicLibraryService.makeTrack(from: .init(persistentID: 42, title: nil, artist: nil, album: nil, duration: 8, artworkData: nil))
XCTAssertEqual(track.id, "system-42")
XCTAssertEqual(track.artist, MusicTrack.unknownArtist)
```

- [ ] **Step 2: 实现权限与查询**

`requestAuthorization()` 用 checked continuation 包装 `MPMediaLibrary.requestAuthorization`；`fetchTracks()` 只在 `.authorized` 时读取 `MPMediaQuery.songs().items`，并在主线程发布结果。

- [ ] **Step 3: 运行测试、构建并提交**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO`

Expected: PASS；模拟器没有媒体库时返回空数组而不崩溃。

```bash
git add SimpleMusic/Library SimpleMusic/App/AppEnvironment.swift SimpleMusicTests/MusicLibraryServiceMappingTests.swift
git commit -m "feat: read system music library"
```

---

### Task 6: 统一播放队列与双后端

**Files:**
- Create: `SimpleMusic/Playback/PlaybackBackend.swift`
- Create: `SimpleMusic/Playback/LocalPlaybackBackend.swift`
- Create: `SimpleMusic/Playback/SystemPlaybackBackend.swift`
- Create: `SimpleMusic/Playback/PlaybackCoordinator.swift`
- Create: `SimpleMusicTests/PlaybackCoordinatorTests.swift`
- Modify: `SimpleMusic/App/AppEnvironment.swift`

**Interfaces:**
- Produces: `snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never>`、`play(queue: [MusicTrack], startAt index: Int) throws`、`togglePlay()`、`seek(to seconds: TimeInterval)`、`previous() throws`、`next() throws`。

- [ ] **Step 1: 定义可替换后端并写失败测试**

```swift
protocol PlaybackBackendDelegate: AnyObject {
    func playbackBackend(_ backend: PlaybackBackend, didUpdateElapsed elapsed: TimeInterval, duration: TimeInterval)
    func playbackBackendDidFinish(_ backend: PlaybackBackend)
    func playbackBackend(_ backend: PlaybackBackend, didFail error: Error)
}

protocol PlaybackBackend: AnyObject {
    var kind: PlaybackBackendKind { get }
    var delegate: PlaybackBackendDelegate? { get set }
    func load(_ track: MusicTrack) throws
    func play(); func pause(); func stop(); func seek(to seconds: TimeInterval)
}
```

```swift
func testCrossSourceNextStopsOldBackendAndLoadsNewBackend() throws {
    let local = SpyBackend(kind: .local)
    let system = SpyBackend(kind: .system)
    let sut = PlaybackCoordinator(localBackend: local, systemBackend: system)
    try sut.play(queue: [downloadedTrack, systemTrack], startAt: 0)
    try sut.next()
    XCTAssertEqual(local.stopCount, 1)
    XCTAssertEqual(system.loadedTrack, systemTrack)
}
```

同时测试 previous、队列末尾停止、随机队列保留全部 ID、空队列不播放。

- [ ] **Step 2: 实现协调器状态机**

用 `CurrentValueSubject<PlaybackSnapshot, Never>` 保存快照。`activate(index:)` 根据 `MusicSource` 选后端；后端改变时必须先 `stop()` 旧后端。所有索引变化只在协调器内部发生。

- [ ] **Step 3: 实现 AVPlayer 与 MPMusicPlayerController 后端**

LocalPlaybackBackend 通过 DownloadFileStore 解析文件 URL 并创建 AVPlayerItem；SystemPlaybackBackend 通过 persistentID 查找 MPMediaItem，使用单项 `MPMediaItemCollection` 设置队列。两者通过 `PlaybackBackendDelegate` 把周期时间、播放完成和错误更新回协调器，不各自维护 UI 状态。

- [ ] **Step 4: 运行测试并提交**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO`

Expected: PASS，跨来源测试证明不会双重播放。

```bash
git add SimpleMusic/Playback SimpleMusic/App/AppEnvironment.swift SimpleMusicTests/PlaybackCoordinatorTests.swift
git commit -m "feat: coordinate local and system playback"
```

---

### Task 7: 后台音频、锁屏信息与耳机控制

**Files:**
- Create: `SimpleMusic/Playback/NowPlayingService.swift`
- Create: `SimpleMusicTests/NowPlayingServiceTests.swift`
- Modify: `SimpleMusic/App/AppEnvironment.swift`

**Interfaces:**
- Consumes: `PlaybackCoordinator` 控制方法与 snapshot publisher。
- Produces: `NowPlayingService.start()`，注册一次并随播放状态更新。

- [ ] **Step 1: 写命令路由失败测试**

将 remote command 注册包装为 `RemoteCommandRegistering`，用 fake 验证 play/pause/next/previous/changePlaybackPosition 分别调用协调器对应闭包，且 `start()` 重复调用不会重复注册。

- [ ] **Step 2: 实现 NowPlayingService**

激活 `AVAudioSession` 的 `.playback` category；把 snapshot 映射到标题、艺人、专辑、封面、总时长、已播放时间和播放速率。所有 command target 在 deinit 或 stop 时移除。

- [ ] **Step 3: 运行测试、构建并提交**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO`

Expected: PASS。

```bash
git add SimpleMusic/Playback/NowPlayingService.swift SimpleMusic/App/AppEnvironment.swift SimpleMusicTests/NowPlayingServiceTests.swift
git commit -m "feat: add background and remote playback controls"
```

---

### Task 8: AppCoordinator、授权页与响应式根界面

**Files:**
- Create: `SimpleMusic/App/AppCoordinator.swift`
- Create: `SimpleMusic/UI/DesignSystem/Theme.swift`
- Create: `SimpleMusic/UI/Permission/PermissionViewController.swift`
- Create: `SimpleMusic/UI/Main/MainTabBarController.swift`
- Create: `SimpleMusic/UI/Main/PadRootViewController.swift`
- Modify: `SimpleMusic/SceneDelegate.swift`
- Modify: `SimpleMusic/Info.plist`
- Modify: `SimpleMusic.xcodeproj/project.pbxproj`
- Delete: `SimpleMusic/Base.lproj/Main.storyboard`

**Interfaces:**
- Consumes: `AppEnvironment` services。
- Produces: iPhone tab 根界面与 iPad 竖屏双栏根界面。

- [ ] **Step 1: 实现主题 token**

```swift
enum Theme {
    static let background = UIColor.systemGroupedBackground
    static let surface = UIColor.secondarySystemGroupedBackground
    static let accent = UIColor(red: 250/255, green: 45/255, blue: 72/255, alpha: 1)
    static let cardRadius: CGFloat = 16
}
```

- [ ] **Step 2: 实现授权页**

使用 SnapKit 排列 72 点图标、标题、说明、允许按钮、暂不按钮和直链提示；按钮最小高度 48 点，所有文案使用 Dynamic Type。允许按钮 await 权限结果，暂不按钮直接进入主界面。

- [ ] **Step 3: 实现设备根容器**

AppCoordinator 根据 `UIDevice.current.userInterfaceIdiom` 选择 MainTabBarController 或 PadRootViewController。PadRoot 固定 264 点侧栏和自适应内容区；Now Playing 面板预留右侧 child controller 容器。

- [ ] **Step 4: 切换 SceneDelegate 到纯代码入口**

```swift
guard let windowScene = scene as? UIWindowScene else { return }
let window = UIWindow(windowScene: windowScene)
let coordinator = AppCoordinator(window: window, environment: .shared)
self.window = window
self.coordinator = coordinator
coordinator.start()
```

移除 Main storyboard 配置与文件，只保留 LaunchScreen。

- [ ] **Step 5: 构建、竖屏检查并提交**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Expected: BUILD SUCCEEDED；Info.plist 仅包含 Portrait。

```bash
git add SimpleMusic/App SimpleMusic/UI/DesignSystem SimpleMusic/UI/Permission SimpleMusic/UI/Main SimpleMusic/SceneDelegate.swift SimpleMusic/Info.plist SimpleMusic.xcodeproj/project.pbxproj SimpleMusic/Base.lproj/Main.storyboard
git commit -m "feat: add adaptive portrait app shell"
```

---

### Task 9: 资料库、搜索与迷你播放器

**Files:**
- Create: `SimpleMusic/UI/Library/LibraryViewModel.swift`
- Create: `SimpleMusic/UI/Library/LibraryViewController.swift`
- Create: `SimpleMusic/UI/Library/TrackCell.swift`
- Create: `SimpleMusic/UI/Search/SearchViewController.swift`
- Create: `SimpleMusic/UI/Player/MiniPlayerView.swift`
- Create: `SimpleMusicTests/LibraryViewModelTests.swift`
- Modify: `SimpleMusic/UI/Main/MainTabBarController.swift`
- Modify: `SimpleMusic/UI/Main/PadRootViewController.swift`

**Interfaces:**
- Produces: `LibraryViewModel.reload() async`、`filter(query:)`、统一歌曲列表；页面通过 `onSelectTrack` 与 `onOpenPlayer` 回调导航。

- [ ] **Step 1: 写合并与搜索失败测试**

```swift
func testReloadMergesSystemAndDownloadedTracksWithoutDroppingSource() async {
    let sut = LibraryViewModel(library: StubLibrary([systemTrack]), localStore: StubLocalStore([downloadedTrack]))
    await sut.reload()
    XCTAssertEqual(Set(sut.tracks.map(\.id)), Set([systemTrack.id, downloadedTrack.id]))
}

func testSearchMatchesTitleArtistAndAlbumCaseInsensitively() {
    XCTAssertEqual(sut.filter(query: "CHEN").map(\.id), [matchingTrack.id])
}
```

- [ ] **Step 2: 实现 ViewModel 并通过测试**

系统和本地读取失败分别转成可展示的 section state；一个来源失败不清空另一个来源。搜索对 title、artist、album 做本地不区分大小写匹配。

- [ ] **Step 3: 实现资料库与歌曲列表**

用 compositional layout 构建最近播放横向区、四个分类入口和最近添加列表；TrackCell 展示 46 点封面、两行文本、下载标识和更多按钮。无权限时显示授权提示，无歌曲时显示真实空状态。

- [ ] **Step 4: 实现搜索和 MiniPlayerView**

搜索页订阅同一 ViewModel 数据；MiniPlayerView 订阅 snapshot publisher，显示当前歌曲、封面和播放/暂停。无当前歌曲时隐藏，不保留演示数据。

- [ ] **Step 5: 测试、构建并提交**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO`

Expected: PASS。

```bash
git add SimpleMusic/UI/Library SimpleMusic/UI/Search SimpleMusic/UI/Player/MiniPlayerView.swift SimpleMusic/UI/Main SimpleMusicTests/LibraryViewModelTests.swift
git commit -m "feat: build library search and mini player"
```

---

### Task 10: 全屏播放器与 iPad 右侧面板

**Files:**
- Create: `SimpleMusic/UI/Player/PlayerViewController.swift`
- Create: `SimpleMusic/UI/Player/NowPlayingPanelController.swift`
- Modify: `SimpleMusic/App/AppCoordinator.swift`
- Modify: `SimpleMusic/UI/Main/PadRootViewController.swift`

**Interfaces:**
- Consumes: `PlaybackCoordinator` snapshot 与控制方法。
- Produces: iPhone 全屏播放器、iPad 右侧滑入播放器。

- [ ] **Step 1: 实现共享播放器内容视图**

PlayerViewController 使用 SnapKit 排列封面、元数据、进度滑块、时间、上一首/播放/下一首、MPVolumeView、AirPlay route picker 与队列。进度拖动结束调用 `seek(to:)`，不在拖动过程中被定时更新抢回。

- [ ] **Step 2: 实现设备呈现差异**

iPhone 由 AppCoordinator present 全屏播放器；iPad 用 NowPlayingPanelController 作为 PadRoot child，从右侧以 324 点宽约束动画滑入，背景遮罩点击关闭。两者复用 PlayerViewController，不复制播放逻辑。

- [ ] **Step 3: 验证布局和状态**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Expected: BUILD SUCCEEDED；无当前歌曲时播放器显示“尚未播放”，控件禁用而不崩溃。

- [ ] **Step 4: 提交**

```bash
git add SimpleMusic/UI/Player SimpleMusic/UI/Main/PadRootViewController.swift SimpleMusic/App/AppCoordinator.swift
git commit -m "feat: add now playing interfaces"
```

---

### Task 11: 下载面板、设置与关于

**Files:**
- Create: `SimpleMusic/UI/Download/DownloadSheetViewController.swift`
- Create: `SimpleMusic/UI/Settings/SettingsViewController.swift`
- Create: `SimpleMusic/UI/Settings/AboutViewController.swift`
- Modify: `SimpleMusic/App/AppCoordinator.swift`
- Modify: `SimpleMusic/UI/Library/LibraryViewController.swift`

**Interfaces:**
- Consumes: `DownloadManager`、`SettingsStore`、`MusicLibraryService`。
- Produces: 输入/下载中/成功/失败四态下载流程与设置页面。

- [ ] **Step 1: 实现下载状态机**

```swift
enum DownloadViewState: Equatable {
    case input
    case downloading(progress: Double)
    case success(MusicTrack)
    case failure(message: String)
}
```

每次状态切换只显示对应视图；取消时 cancel task 并清除临时状态。成功后根据设置选择停留、立即播放或自动播放，并触发 LibraryViewModel.reload()。

- [ ] **Step 2: 实现设置与关于**

设置页显示真实权限状态；权限未授权时点击进入系统设置或触发首次请求。两个 switch 直接读写 SettingsStore。关于页固定展示支持 MP3/M4A/WAV、仅本机保存、不解析网页。

- [ ] **Step 3: 无障碍与键盘检查**

为下载 URL 输入框设置 URL keyboard、Return Key；所有图标按钮有 accessibilityLabel，switch 使用真实 UISwitch，按钮点击区不小于 44 点。

- [ ] **Step 4: 构建并提交**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Expected: BUILD SUCCEEDED。

```bash
git add SimpleMusic/UI/Download SimpleMusic/UI/Settings SimpleMusic/App/AppCoordinator.swift SimpleMusic/UI/Library/LibraryViewController.swift
git commit -m "feat: add download and settings flows"
```

---

### Task 12: 全量验证、视觉核对与真机清单

**Files:**
- Modify only when a failing check identifies a scoped defect.
- Create: `docs/testing/2026-08-14-simple-music-player-verification.md`

**Interfaces:**
- Produces: 可复核的模拟器结果和明确标注未完成的真机验证项。

- [ ] **Step 1: 运行全量测试与静态检查**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO`

Run: `git diff --check`

Expected: 全部测试 PASS；无空白错误。

- [ ] **Step 2: 编译 iPhone 与 iPad 通用目标**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -configuration Debug -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`

Expected: 两次 BUILD SUCCEEDED。

- [ ] **Step 3: 模拟器验收**

逐项记录：首次拒绝权限仍能进入、空资料库状态、有效/无效下载链接、本地播放、进度拖动、上一首/下一首、搜索、设置持久化、iPhone 竖屏、iPad 竖屏双栏、动态字体、VoiceOver 标签、减少动态效果。

- [ ] **Step 4: 真机验收**

逐项记录：系统音乐授权、系统歌曲播放、云端歌曲边界、系统与本地歌曲跨来源切换、后台播放、锁屏/控制中心元数据、耳机按键、AirPlay、蜂窝网络禁止下载。没有真机证据的项目必须标为“待真机验证”，不能写成已通过。

- [ ] **Step 5: 写验证报告并提交**

验证报告包含每条命令、退出码、设备/系统版本、通过项、失败项和待真机项。

```bash
git add docs/testing/2026-08-14-simple-music-player-verification.md
git commit -m "test: verify SimpleMusic player"
```
