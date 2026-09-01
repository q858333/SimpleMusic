# DiskTone 播放列表 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有资料库中提供可持久化的播放列表；用户可以新建列表、把系统或本地歌曲加入，并使用现有播放器播放。

**Architecture:** Core Data 播放列表只保存歌曲 ID 和顺序。`PlaylistStore` 负责事务与去重，`PlaylistViewModel` 基于 `LibraryViewModel.tracks` 解析可展示歌曲。资料库和搜索统一通过该 view model 触发加入操作，不修改 `PlaybackCoordinator`、下载队列或系统媒体后端。

**Tech Stack:** Swift、UIKit、SnapKit、Combine、Core Data、XCTest，iOS 15.0。

**Spec:** `docs/superpowers/specs/2026-09-01-playlists-design.md`

## Global Constraints

- 不新增 Tab，也不改播放、下载、远程控制或系统媒体架构。
- 系统歌曲与本地下载歌曲都可加入；不复制 `MusicTrack` 元数据。
- 删除播放列表绝不删除歌曲、下载文件或系统媒体。
- 所有新文字使用 `L10n`，提供简体中文、繁体中文和英文。
- 每个生产行为先写 XCTest 并确认 RED，再最小实现至 GREEN。

---

### Task 1: Core Data 播放列表模型与持久化仓库

**Files:**
- Create: `SimpleMusic/Persistence/PlaylistStore.swift`
- Create: `SimpleMusicTests/PlaylistStoreTests.swift`
- Modify: `SimpleMusic/SimpleMusic.xcdatamodeld/`（新增 V3 并设为当前模型）
- Modify: `SimpleMusic.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `Playlist(id:name:createdAt:updatedAt:trackIDs:)`。
- Produces: `PlaylistStore.fetchPlaylists()`, `create(name:)`, `rename(id:name:)`, `delete(id:)`, `add(trackID:to:)`, `tracks(in:)`, `removeMissingTrackIDs(_:)`。

- [ ] **Step 1: 写失败测试**

```swift
func testAddingSameTrackTwiceKeepsOneOrderedItem() throws {
    let store = try PlaylistStore.inMemory()
    let playlist = try store.create(name: "晨间")
    try store.add(trackID: "track-1", to: playlist.id)
    try store.add(trackID: "track-1", to: playlist.id)
    XCTAssertEqual(try store.tracks(in: playlist.id), ["track-1"])
}
```

另加空白/重名、新建、重命名、删除不删歌曲、追加顺序和失效 ID 清理测试。

- [ ] **Step 2: 验证 RED**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SimpleMusicTests/PlaylistStoreTests test CODE_SIGNING_ALLOWED=NO`

Expected: `PlaylistStore` 和 V3 实体尚不存在而失败。

- [ ] **Step 3: 最小实现**

新增 `PlaylistEntity(id,name,createdAt,updatedAt)` 与 `PlaylistItemEntity(id,trackID,addedAt,position)` 的一对多关系。仓库使用当前 Core Data context 的 `NSEntityDescription`，保存失败时 rollback；按 `position` 读取，拒绝空白或重名，重复 ID 不插入第二条。

- [ ] **Step 4: 验证 GREEN**

重跑 Step 2 命令，所有 `PlaylistStoreTests` 通过。

- [ ] **Step 5: 提交**

```bash
git add SimpleMusic/Persistence/PlaylistStore.swift SimpleMusicTests/PlaylistStoreTests.swift SimpleMusic/SimpleMusic.xcdatamodeld SimpleMusic.xcodeproj/project.pbxproj
git commit -m "feat: 添加播放列表持久化"
```

### Task 2: 解析统一歌曲与播放列表状态

**Files:**
- Create: `SimpleMusic/UI/Library/PlaylistViewModel.swift`
- Create: `SimpleMusicTests/PlaylistViewModelTests.swift`
- Modify: `SimpleMusic/App/AppEnvironment.swift`

**Interfaces:**
- Consumes: `PlaylistStore`、`LibraryViewModel.$tracks`。
- Produces: `PlaylistViewModel.playlists`, `tracks(for:)`, `createPlaylist(named:)`, `renamePlaylist`, `deletePlaylist`, `add(_:to:)`。
- Produces: `AppEnvironment.playlistStore` 与唯一共享 `playlistViewModel`。

- [ ] **Step 1: 写失败测试**

```swift
@MainActor
func testPlaylistTracksResolveAgainstLatestLibraryTracks() throws {
    let library = makeLibraryViewModel(tracks: [track(id: "a")])
    let playlists = try PlaylistViewModel(store: .inMemory(), library: library)
    let playlist = try playlists.createPlaylist(named: "收藏")
    try playlists.add(track(id: "a"), to: playlist.id)
    library.replaceTracksForTesting([])
    XCTAssertTrue(playlists.tracks(for: playlist.id).isEmpty)
}
```

另加资料库刷新后清理缺失歌曲 ID 的测试。

- [ ] **Step 2: 验证 RED**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SimpleMusicTests/PlaylistViewModelTests test CODE_SIGNING_ALLOWED=NO`

Expected: `PlaylistViewModel` 缺失。

- [ ] **Step 3: 最小实现**

用共享资料库歌曲流解析 ID。缺失的 ID 仅从列表项中清理，绝不影响原歌曲；AppEnvironment 将 store 建在与下载索引相同的持久化容器中。

- [ ] **Step 4: 验证 GREEN**

重跑 Step 2 命令，全部 view-model 测试通过。

- [ ] **Step 5: 提交**

```bash
git add SimpleMusic/UI/Library/PlaylistViewModel.swift SimpleMusicTests/PlaylistViewModelTests.swift SimpleMusic/App/AppEnvironment.swift
git commit -m "feat: 解析播放列表歌曲"
```

### Task 3: 资料库入口和播放列表页面

**Files:**
- Create: `SimpleMusic/UI/Library/PlaylistListViewController.swift`
- Create: `SimpleMusic/UI/Library/PlaylistTracksViewController.swift`
- Modify: `SimpleMusic/UI/Library/LibraryViewController.swift`
- Modify: `SimpleMusic/UI/Main/MainTabBarController.swift`
- Modify: `SimpleMusic/UI/Main/PadRootViewController.swift`
- Modify: `SimpleMusic/App/AppCoordinator.swift`
- Test: `SimpleMusicTests/LibraryViewModelTests.swift`

**Interfaces:**
- Consumes: 共享 `PlaylistViewModel` 与既有 `onSelectTrack: ([MusicTrack], Int) -> Void`。
- Produces: `PlaylistListViewController`、`PlaylistTracksViewController`。

- [ ] **Step 1: 写失败 UIKit 测试**

```swift
@MainActor
func testLibraryPlaylistCategoryPushesPlaylistListUsingSharedViewModel() throws {
    let library = makeLibraryController()
    library.loadViewIfNeeded()
    selectCategory(named: L10n.text("playlist.title"), in: library)
    XCTAssertTrue(library.navigationController?.topViewController is PlaylistListViewController)
}
```

另加新建、数量、进入列表、空状态和全部播放/随机播放透传现有 closure 的测试。

- [ ] **Step 2: 验证 RED**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SimpleMusicTests/LibraryViewModelTests test CODE_SIGNING_ALLOWED=NO`

Expected: 分类与控制器缺失。

- [ ] **Step 3: 最小实现**

资料库增加第五个分类卡。列表页通过 alert text field 创建/重命名、以行操作删除；歌曲页复用现有播放队列 closure，不创建第二个播放器。iPhone/iPad root 均注入同一环境的 view model。

- [ ] **Step 4: 验证 GREEN**

重跑 Step 2 命令，新增和已有资料库测试通过。

- [ ] **Step 5: 提交**

```bash
git add SimpleMusic/UI/Library/PlaylistListViewController.swift SimpleMusic/UI/Library/PlaylistTracksViewController.swift SimpleMusic/UI/Library/LibraryViewController.swift SimpleMusic/UI/Main/MainTabBarController.swift SimpleMusic/UI/Main/PadRootViewController.swift SimpleMusic/App/AppCoordinator.swift SimpleMusicTests/LibraryViewModelTests.swift
git commit -m "feat: 添加播放列表资料库入口"
```

### Task 4: 歌曲菜单加入播放列表与本地化

**Files:**
- Create: `SimpleMusic/UI/Library/PlaylistSelectionViewController.swift`
- Modify: `SimpleMusic/UI/Library/TrackCell.swift`
- Modify: `SimpleMusic/UI/Library/LibraryViewController.swift`
- Modify: `SimpleMusic/UI/Library/TrackListViewController.swift`
- Modify: `SimpleMusic/UI/Search/SearchViewController.swift`
- Modify: `SimpleMusic/zh-Hans.lproj/Localizable.strings`
- Modify: `SimpleMusic/zh-Hant.lproj/Localizable.strings`
- Modify: `SimpleMusic/en.lproj/Localizable.strings`
- Test: `SimpleMusicTests/LibraryViewModelTests.swift`
- Test: `SimpleMusicTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: `PlaylistViewModel.add(_:to:)`、既有本地删除提示。
- Produces: 一个供资料库、分类列表和搜索复用的选择界面。

- [ ] **Step 1: 写失败交互/本地化测试**

```swift
@MainActor
func testSystemTrackMoreActionPresentsPlaylistSelectionAndAddsTrack() throws {
    let controller = makeSearchController(with: [systemTrack(id: "system-1")])
    tapMore(on: controller, at: 0)
    let selection = try XCTUnwrap(controller.presentedViewController as? PlaylistSelectionViewController)
    selection.select(playlistID: "favorites")
    XCTAssertEqual(try playlistStore.tracks(in: "favorites"), ["system-1"])
}
```

另加本地歌曲同时保留“删除本地歌曲”的测试，以及三语言 key 完整性测试。

- [ ] **Step 2: 验证 RED**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SimpleMusicTests/LibraryViewModelTests -only-testing:SimpleMusicTests/LocalizationTests test CODE_SIGNING_ALLOWED=NO`

Expected: 选择控制器、菜单行为和本地化 key 缺失。

- [ ] **Step 3: 最小实现**

歌曲更多菜单同时支持两个来源：本地歌曲显示加入和既有删除，系统歌曲只显示加入。选择界面列出现有播放列表；列表为空时可直接新建并加入。所有文案使用 `L10n`。

- [ ] **Step 4: 验证 GREEN**

重跑 Step 2 命令，删除行为和本地化测试都通过。

- [ ] **Step 5: 提交**

```bash
git add SimpleMusic/UI/Library/PlaylistSelectionViewController.swift SimpleMusic/UI/Library/TrackCell.swift SimpleMusic/UI/Library/LibraryViewController.swift SimpleMusic/UI/Library/TrackListViewController.swift SimpleMusic/UI/Search/SearchViewController.swift SimpleMusic/zh-Hans.lproj/Localizable.strings SimpleMusic/zh-Hant.lproj/Localizable.strings SimpleMusic/en.lproj/Localizable.strings SimpleMusicTests/LibraryViewModelTests.swift SimpleMusicTests/LocalizationTests.swift
git commit -m "feat: 支持歌曲加入播放列表"
```

### Task 5: 集成验证

**Files:**
- Create: `docs/testing/2026-09-01-playlists-verification.md`

- [ ] **Step 1: 运行播放列表聚焦测试**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SimpleMusicTests/PlaylistStoreTests -only-testing:SimpleMusicTests/PlaylistViewModelTests -only-testing:SimpleMusicTests/LibraryViewModelTests -only-testing:SimpleMusicTests/LocalizationTests test CODE_SIGNING_ALLOWED=NO`

Expected: exit 0，所有 selected tests 通过。

- [ ] **Step 2: 运行完整 XCTest**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO`

Expected: exit 0，failed/skipped 都为 0。

- [ ] **Step 3: 构建模拟器与设备产物**

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Run: `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`

Expected: 两条命令均为 `BUILD SUCCEEDED`。

- [ ] **Step 4: 记录证据并提交**

在验证文档记录测试数、构建结果与环境 warning；执行 `git diff --check` 后：

```bash
git add docs/testing/2026-09-01-playlists-verification.md
git commit -m "test: 记录播放列表验证结果"
```
