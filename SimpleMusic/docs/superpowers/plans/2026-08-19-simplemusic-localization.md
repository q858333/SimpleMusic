# SimpleMusic 三语言本地化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 SimpleMusic 跟随系统语言显示英文、简体中文或台湾繁体中文，并在其他语言环境完整回退英文。

**Architecture:** 使用 `en`、`zh-Hans`、`zh-Hant` 三套 `Localizable.strings`、`Localizable.stringsdict` 与 `InfoPlist.strings`。生产代码通过单一 `L10n` 边界读取语义 key；普通界面、格式化文本和复数分别使用 `text`、`format`、`plural`，不引入应用内语言状态。

**Tech Stack:** Swift 5、UIKit、Foundation 本地化 API、XCTest、Xcode 26、iOS 15.0+、CocoaPods/SnapKit。

**Spec:** `docs/superpowers/specs/2026-08-19-simplemusic-localization-design.md`

**Working Directory:** 所有命令均从 `/Users/db/Documents/git/my/music/SimpleMusic/SimpleMusic` 执行；文档和文件路径也以该目录为基准。

## Global Constraints

- 系统语言选择由 iOS 和 `Bundle.main` 负责，不增加应用内语言切换入口。
- `en` 是 `developmentRegion` 和所有不受支持语言的默认回退。
- 仅支持 `en`、`zh-Hans`、`zh-Hant`；繁体采用台湾常用措辞。
- 所有用户可见文本、无障碍标签、动态格式、应用名称和音乐权限说明必须本地化。
- 代码注释、`NSLog`、测试说明、不会展示给用户的 `fatalError`/`preconditionFailure` 保持原样。
- 不改变播放、下载、资料库、权限、导航、iOS 15.0、竖屏或 CocoaPods/SnapKit 配置。
- 新增非直观格式化和回退代码时添加简洁中文注释；不为显而易见的赋值逐行加注释。
- 每个任务严格执行测试先行；若测试命令遇到 CoreSimulator `Invalid device state`，先按 systematic-debugging 确认环境，再使用明确可用设备和 `-parallel-testing-enabled NO` 重跑。

---

## File Structure

### 新建文件

- `SimpleMusic/Localization/L10n.swift`：唯一运行时本地化读取、格式化和复数边界。
- `SimpleMusic/en.lproj/Localizable.strings`：完整英文默认文案。
- `SimpleMusic/zh-Hans.lproj/Localizable.strings`：完整简体中文文案。
- `SimpleMusic/zh-Hant.lproj/Localizable.strings`：完整台湾繁体中文文案。
- `SimpleMusic/{en,zh-Hans,zh-Hant}.lproj/Localizable.stringsdict`：歌曲数量复数规则。
- `SimpleMusic/{en,zh-Hans,zh-Hant}.lproj/InfoPlist.strings`：应用名称和音乐权限说明。
- `SimpleMusicTests/LocalizationTests.swift`：资源完整性、格式参数、回退配置和代表性翻译测试。

### 修改文件

- `SimpleMusic.xcodeproj/project.pbxproj`：登记三种语言和 `LocalizationTests.swift` test target membership。
- `SimpleMusic/Info.plist`：把基础音乐权限说明改为英文。
- `SimpleMusic/Domain/MusicTrack.swift`、`SimpleMusic/Persistence/AppStorageRecovery.swift`、`SimpleMusic/App/AppCoordinator.swift`：领域展示兜底和存储降级文案。
- `SimpleMusic/UI/Permission/PermissionViewController.swift`、`SimpleMusic/UI/Main/MainTabBarController.swift`、`SimpleMusic/UI/Main/PadRootViewController.swift`：授权和根壳文案。
- `SimpleMusic/UI/Library/LibraryViewController.swift`、`LibraryViewModel.swift`、`LocalTrackDeletionPrompt.swift`、`TrackCell.swift`、`TrackListViewController.swift`、`SimpleMusic/UI/Search/SearchViewController.swift`：资料库和搜索文案。
- `SimpleMusic/UI/Player/MiniPlayerView.swift`、`NowPlayingPanelController.swift`、`PlayerViewController.swift`：播放器及无障碍文案。
- `SimpleMusic/UI/Download/DownloadSheetViewController.swift`、`DownloadUnavailableViewController.swift`：下载流程文案。
- `SimpleMusic/UI/Settings/SettingsViewController.swift`、`AboutViewController.swift`：设置和关于文案。
- `SimpleMusicTests/AppCoordinatorTests.swift`、`LibraryViewModelTests.swift`、`MusicTrackTests.swift`、`PlayerViewControllerTests.swift`、`DownloadAndSettingsFlowTests.swift`：把用户界面断言改为语言无关的本地化断言。

---

### Task 1: 建立本地化运行时、三套资源与契约测试

**Files:**
- Create: `SimpleMusic/SimpleMusic/Localization/L10n.swift`
- Create: `SimpleMusic/SimpleMusic/en.lproj/Localizable.strings`
- Create: `SimpleMusic/SimpleMusic/zh-Hans.lproj/Localizable.strings`
- Create: `SimpleMusic/SimpleMusic/zh-Hant.lproj/Localizable.strings`
- Create: `SimpleMusic/SimpleMusic/en.lproj/Localizable.stringsdict`
- Create: `SimpleMusic/SimpleMusic/zh-Hans.lproj/Localizable.stringsdict`
- Create: `SimpleMusic/SimpleMusic/zh-Hant.lproj/Localizable.stringsdict`
- Create: `SimpleMusic/SimpleMusic/en.lproj/InfoPlist.strings`
- Create: `SimpleMusic/SimpleMusic/zh-Hans.lproj/InfoPlist.strings`
- Create: `SimpleMusic/SimpleMusic/zh-Hant.lproj/InfoPlist.strings`
- Create: `SimpleMusic/SimpleMusicTests/LocalizationTests.swift`
- Modify: `SimpleMusic/SimpleMusic/Info.plist:5-7`
- Modify: `SimpleMusic/SimpleMusic.xcodeproj/project.pbxproj:1-150,220-227,500-590`

**Interfaces:**
- Consumes: Foundation `Bundle`, `Locale`, `NSLocalizedString` and app-hosted XCTest resources.
- Produces:
  - `L10n.text(_ key: String, bundle: Bundle = .main) -> String`
  - `L10n.format(_ key: String, _ arguments: CVarArg...) -> String`
  - `L10n.formatted(_ key: String, bundle: Bundle, arguments: [CVarArg]) -> String`
  - `L10n.plural(_ key: String, count: Int, bundle: Bundle = .main) -> String`

- [ ] **Step 1: 新增会因本地化设施缺失而失败的测试**

创建 `LocalizationTests.swift`，先覆盖运行时 API、三语言代表值、key 对齐、工程语言和 InfoPlist：

```swift
import XCTest
@testable import SimpleMusic

final class LocalizationTests: XCTestCase {
    func testSupportedBundlesResolveRepresentativeCopy() throws {
        XCTAssertEqual(L10n.text("app.name", bundle: try languageBundle("en")), "DiskTone")
        XCTAssertEqual(L10n.text("app.name", bundle: try languageBundle("zh-Hans")), "听见")
        XCTAssertEqual(L10n.text("app.name", bundle: try languageBundle("zh-Hant")), "聽見")
        XCTAssertEqual(L10n.text("common.settings", bundle: try languageBundle("zh-Hant")), "設定")
    }

    func testLocalizableStringKeysMatchAcrossLanguages() throws {
        let english = try stringsDictionary(language: "en", name: "Localizable")
        XCTAssertEqual(Set(english.keys), Set(try stringsDictionary(language: "zh-Hans", name: "Localizable").keys))
        XCTAssertEqual(Set(english.keys), Set(try stringsDictionary(language: "zh-Hant", name: "Localizable").keys))
    }

    func testInfoPlistLocalizationsContainBrandAndPermissionCopy() throws {
        XCTAssertEqual(try stringsDictionary(language: "en", name: "InfoPlist")["CFBundleDisplayName"], "DiskTone")
        XCTAssertEqual(try stringsDictionary(language: "zh-Hans", name: "InfoPlist")["CFBundleDisplayName"], "听见")
        XCTAssertEqual(try stringsDictionary(language: "zh-Hant", name: "InfoPlist")["CFBundleDisplayName"], "聽見")
        for language in ["en", "zh-Hans", "zh-Hant"] {
            XCTAssertFalse(try XCTUnwrap(stringsDictionary(language: language, name: "InfoPlist")["NSAppleMusicUsageDescription"]).isEmpty)
        }
    }

    func testProjectUsesEnglishFallbackAndRegistersSupportedRegions() throws {
        let project = try String(contentsOf: projectRoot.appendingPathComponent("SimpleMusic.xcodeproj/project.pbxproj"))
        XCTAssertTrue(project.contains("developmentRegion = en;"))
        XCTAssertTrue(project.contains("zh-Hans,"))
        XCTAssertTrue(project.contains("zh-Hant,"))
    }
}
```

测试 helper 必须从 `#filePath` 定位 `SimpleMusic` 工程根，使用 `PropertyListSerialization` 解析 `.strings`，并分别从 App bundle 的 `resourceURL/en.lproj`、`resourceURL/zh-Hans.lproj`、`resourceURL/zh-Hant.lproj` 创建语言 bundle；不要在生产代码添加测试专用清理或切换接口。

- [ ] **Step 2: 把测试文件加入 test target 并取得可信 RED**

在 `project.pbxproj` 添加 `LocalizationTests.swift` 的 `PBXFileReference`、`PBXBuildFile`、Tests group child 和 Tests Sources entry。使用唯一 ID，例如：

```text
A3C000000000000000000001 /* LocalizationTests.swift in Sources */
A3C000000000000000000002 /* LocalizationTests.swift */
```

运行：

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' \
  -parallel-testing-enabled NO -testLanguage en \
  -only-testing:SimpleMusicTests/LocalizationTests test CODE_SIGNING_ALLOWED=NO
```

预期：exit 65，编译明确失败于 `cannot find 'L10n' in scope`；修正任何测试自身语法错误后再记录 RED。

- [ ] **Step 3: 实现最小 `L10n` 边界**

```swift
import Foundation

enum L10n {
    static func text(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        formatted(key, bundle: .main, arguments: arguments)
    }

    static func formatted(
        _ key: String,
        bundle: Bundle,
        arguments: [CVarArg]
    ) -> String {
        String(
            format: text(key, bundle: bundle),
            locale: Locale.current,
            arguments: arguments
        )
    }

    static func plural(
        _ key: String,
        count: Int,
        bundle: Bundle = .main
    ) -> String {
        // stringsdict 由 Foundation 按 count 选择英文单复数；简繁中文共享同一数量格式。
        String.localizedStringWithFormat(text(key, bundle: bundle), count)
    }
}
```

- [ ] **Step 4: 创建完整翻译资源与英文 Info.plist 基值**

按本计划“附录 A”逐项创建三套 `Localizable.strings` 和三套 `InfoPlist.strings`，按“附录 B”创建三套 `Localizable.stringsdict`。把 `Info.plist` 的基础说明改成：

```xml
<key>NSAppleMusicUsageDescription</key>
<string>DiskTone uses your music library to browse and play music on this device.</string>
```

在 `knownRegions` 中加入：

```text
en,
"zh-Hans",
"zh-Hant",
Base,
```

App target 使用文件系统同步根组，新资源目录自动进入 target；不要为资源手工创建重复 PBX file reference。

- [ ] **Step 5: 补齐参数与复数资源契约测试**

在 `LocalizationTests` 增加：

```swift
func testFormattedCopyKeepsParametersAcrossLanguages() throws {
    for language in ["en", "zh-Hans", "zh-Hant"] {
        let bundle = try languageBundle(language)
        let queue = L10n.formatted("player.queue.position", bundle: bundle, arguments: [2, 4])
        XCTAssertTrue(queue.contains("2"))
        XCTAssertTrue(queue.contains("4"))
        XCTAssertFalse(queue.contains("player.queue.position"))
    }
}

func testTrackCountUsesEnglishPluralAndChineseCountFormat() throws {
    XCTAssertEqual(L10n.plural("tracks.count", count: 1, bundle: try languageBundle("en")), "1 song")
    XCTAssertEqual(L10n.plural("tracks.count", count: 2, bundle: try languageBundle("en")), "2 songs")
    XCTAssertEqual(L10n.plural("tracks.count", count: 2, bundle: try languageBundle("zh-Hans")), "2 首")
    XCTAssertEqual(L10n.plural("tracks.count", count: 2, bundle: try languageBundle("zh-Hant")), "2 首")
}
```

解析三套普通字符串中的 `%@`、`%d`、带位置参数的 `%1$@`/`%1$d`，规范化后断言同 key 的参数索引和类型一致。解析三套 stringsdict，断言顶层 key 均为 `tracks.count`。

- [ ] **Step 6: 运行 Task 1 GREEN**

运行 Step 2 的 focused 命令。

预期：`LocalizationTests` 全部通过，`** TEST SUCCEEDED **`。

- [ ] **Step 7: 提交 Task 1**

```bash
git add SimpleMusic/Localization SimpleMusic/en.lproj SimpleMusic/zh-Hans.lproj \
  SimpleMusic/zh-Hant.lproj SimpleMusic/Info.plist SimpleMusicTests/LocalizationTests.swift \
  SimpleMusic.xcodeproj/project.pbxproj
git commit -m "feat: 建立三语言本地化资源"
```

---

### Task 2: 本地化领域展示兜底和存储降级提示

**Files:**
- Modify: `SimpleMusic/SimpleMusic/Domain/MusicTrack.swift:10-14`
- Modify: `SimpleMusic/SimpleMusic/Persistence/AppStorageRecovery.swift:42-100`
- Modify: `SimpleMusic/SimpleMusic/App/AppCoordinator.swift:58-68`
- Modify: `SimpleMusic/SimpleMusicTests/MusicTrackTests.swift:1-15`
- Modify: `SimpleMusic/SimpleMusicTests/AppCoordinatorTests.swift:70-100`
- Modify: `SimpleMusic/SimpleMusicTests/LocalMusicStoreTests.swift`（持久化降级 warning 断言）

**Interfaces:**
- Consumes: Task 1 的 `L10n.text`、`L10n.format` 和资源 key。
- Produces: 本地化的未知艺人/专辑、持久化回退、下载存储不可用文案。

- [ ] **Step 1: 写语言无关的失败测试**

把用户可见断言改为本地化期望，并新增 warning 格式测试：

```swift
XCTAssertEqual(MusicTrack.unknownArtist, L10n.text("track.unknown_artist"))
XCTAssertEqual(MusicTrack.unknownAlbum, L10n.text("track.unknown_album"))
XCTAssertEqual(controller.title, L10n.text("download.unavailable.title"))
XCTAssertTrue(copy.contains(L10n.text("storage.download.unavailable_short")))
```

对 `PersistentStoreFactory` 注入固定错误 `TestError.failed`，断言 warning 包含 `L10n.text("storage.persistence.unavailable")` 且保留错误 detail；对 `DownloadStorageFactory` 断言 warning 等于 `L10n.text("storage.download.unavailable")`。

- [ ] **Step 2: 运行 focused RED**

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' \
  -parallel-testing-enabled NO -testLanguage en \
  -only-testing:SimpleMusicTests/MusicTrackTests \
  -only-testing:SimpleMusicTests/AppCoordinatorTests \
  -only-testing:SimpleMusicTests/LocalMusicStoreTests test CODE_SIGNING_ALLOWED=NO
```

预期：行为断言失败，实际值仍为中文硬编码，期望值为英文资源；不得把测试编译错误计作 RED。

- [ ] **Step 3: 替换生产硬编码**

```swift
static let unknownArtist = L10n.text("track.unknown_artist")
static let unknownAlbum = L10n.text("track.unknown_album")
```

持久化 warning 使用：

```swift
let baseWarning = L10n.text("storage.persistence.unavailable")
let warning = detail.isEmpty
    ? baseWarning
    : L10n.format("storage.persistence.unavailable_with_detail", baseWarning, detail)
```

下载存储分别使用 `storage.download.unavailable` 和 `storage.download.unavailable_short`；`NSLog` 仍保留中文开发者诊断，不进入资源。

- [ ] **Step 4: 运行 focused GREEN**

运行 Step 2 命令。

预期：三个测试类全部通过。

- [ ] **Step 5: 提交 Task 2**

```bash
git add SimpleMusic/Domain/MusicTrack.swift SimpleMusic/Persistence/AppStorageRecovery.swift \
  SimpleMusic/App/AppCoordinator.swift SimpleMusicTests/MusicTrackTests.swift \
  SimpleMusicTests/AppCoordinatorTests.swift SimpleMusicTests/LocalMusicStoreTests.swift
git commit -m "feat: 本地化存储降级与曲目信息"
```

---

### Task 3: 本地化首次授权和 iPhone/iPad 根壳

**Files:**
- Modify: `SimpleMusic/SimpleMusic/UI/Permission/PermissionViewController.swift:20-70`
- Modify: `SimpleMusic/SimpleMusic/UI/Main/MainTabBarController.swift:85-105`
- Modify: `SimpleMusic/SimpleMusic/UI/Main/PadRootViewController.swift:40-70,220-240`
- Modify: `SimpleMusic/SimpleMusicTests/AppCoordinatorTests.swift:240-330`
- Modify: `SimpleMusic/SimpleMusicTests/LibraryViewModelTests.swift`（Tab/侧栏标题断言）
- Modify: `SimpleMusic/SimpleMusicTests/PlayerViewControllerTests.swift:450-520`

**Interfaces:**
- Consumes: `L10n.text` 与 `app.name`、`permission.*`、`tab.*`、`pad.player_guide`。
- Produces: 三语言首次授权页、Tab 标题、iPad 侧栏品牌与播放引导。

- [ ] **Step 1: 为英文运行环境写失败断言**

在真实控制器上断言：

```swift
XCTAssertEqual(permissionTitle.text, L10n.text("permission.title"))
XCTAssertEqual(allowButton.configuration?.title, L10n.text("permission.allow"))
XCTAssertEqual(phone.viewControllers?[0].tabBarItem.title, L10n.text("tab.library"))
XCTAssertEqual(phone.viewControllers?[1].tabBarItem.title, L10n.text("tab.search"))
XCTAssertEqual(guide.accessibilityLabel, L10n.text("pad.player_guide"))
```

给授权页现有 label/button 增加稳定 accessibility identifier 只用于用户可访问性和测试定位，例如 `permission.title`、`permission.allow`；不要暴露测试专用 getter。

- [ ] **Step 2: 运行 focused RED**

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' \
  -parallel-testing-enabled NO -testLanguage en \
  -only-testing:SimpleMusicTests/AppCoordinatorTests \
  -only-testing:SimpleMusicTests/PlayerViewControllerTests/testPadPlayerGuideAppearsForFirstTrackAndStaysDismissedAfterOpening \
  test CODE_SIGNING_ALLOWED=NO
```

预期：授权页、Tab 或 guide 至少一项实际中文、期望英文而失败。

- [ ] **Step 3: 接入根壳本地化 key**

把以下硬编码逐项替换：

```swift
label.text = L10n.text("permission.title")
button.configuration?.title = L10n.text("permission.allow")
tab.title = L10n.text("tab.library")
titleLabel.text = L10n.text("app.name")
container.accessibilityLabel = L10n.text("pad.player_guide")
```

权限 body 与 direct-link note 分别使用 `permission.body`、`permission.direct_link_note`，不要在 Swift 中插入品牌名。

- [ ] **Step 4: 运行 focused GREEN**

运行 Step 2 命令，预期全部通过。

- [ ] **Step 5: 提交 Task 3**

```bash
git add SimpleMusic/UI/Permission/PermissionViewController.swift \
  SimpleMusic/UI/Main/MainTabBarController.swift SimpleMusic/UI/Main/PadRootViewController.swift \
  SimpleMusicTests/AppCoordinatorTests.swift SimpleMusicTests/LibraryViewModelTests.swift \
  SimpleMusicTests/PlayerViewControllerTests.swift
git commit -m "feat: 本地化授权页与应用根壳"
```

---

### Task 4: 本地化资料库、分类列表、删除确认与搜索

**Files:**
- Modify: `SimpleMusic/SimpleMusic/UI/Library/LibraryViewController.swift:25-245`
- Modify: `SimpleMusic/SimpleMusic/UI/Library/LibraryViewModel.swift:115-175`
- Modify: `SimpleMusic/SimpleMusic/UI/Library/LocalTrackDeletionPrompt.swift:1-20`
- Modify: `SimpleMusic/SimpleMusic/UI/Library/TrackCell.swift:40-65`
- Modify: `SimpleMusic/SimpleMusic/UI/Library/TrackListViewController.swift:1-20,170-190,320-335`
- Modify: `SimpleMusic/SimpleMusic/UI/Search/SearchViewController.swift:38-150`
- Modify: `SimpleMusic/SimpleMusicTests/LibraryViewModelTests.swift:520-900,1000-1100`

**Interfaces:**
- Consumes: `library.*`、`category.*`、`list.*`、`track.*`、`deletion.*`、`search.*`、`tracks.count`。
- Produces: 本地化资料库首页、四类列表、歌曲数量、删除弹窗和搜索状态。

- [ ] **Step 1: 写真实页面失败测试**

在 `LibraryViewModelTests` 增加或更新：

```swift
XCTAssertEqual(library.title, L10n.text("library.title"))
XCTAssertEqual(navigation.topViewController?.title, L10n.text("category.songs"))
XCTAssertEqual(search.title, L10n.text("search.title"))
XCTAssertEqual(search.searchController.searchBar.placeholder, L10n.text("search.placeholder"))
XCTAssertEqual(downloadedBadge.text, L10n.text("track.downloaded"))
```

创建真实 `LocalTrackDeletionPrompt`，检查 alert 标题、包含歌曲名的 message、取消和删除 action 标题。对 `TrackGroupCell.configure(title:count:)` 断言 count label 等于 `L10n.plural("tracks.count", count: 2)`，且 accessibility label 等于 `L10n.format("track_group.accessibility", title, countText)`。

- [ ] **Step 2: 运行 focused RED**

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' \
  -parallel-testing-enabled NO -testLanguage en \
  -only-testing:SimpleMusicTests/LibraryViewModelTests test CODE_SIGNING_ALLOWED=NO
```

预期：现有中文标题、badge、搜索或数量文案与英文资源不一致。

- [ ] **Step 3: 替换资料库与 ViewModel 用户文案**

逐项使用资源 key，格式化调用必须是：

```swift
alert.message = L10n.format("deletion.message", track.title)
countLabel.text = L10n.plural("tracks.count", count: count)
accessibilityLabel = L10n.format(
    "track_group.accessibility",
    title,
    L10n.plural("tracks.count", count: count)
)
```

`LibraryCategory.title` 使用 `category.songs`、`category.albums`、`category.artists`、`category.downloaded`。删除/读取失败状态使用 `library.error.delete_local`、`library.error.system`、`library.error.local`。搜索空查询和无结果分别使用 `search.empty_library`、`search.no_results`。

- [ ] **Step 4: 运行 focused GREEN**

运行 Step 2 命令，预期 `LibraryViewModelTests` 全部通过。

- [ ] **Step 5: 提交 Task 4**

```bash
git add SimpleMusic/UI/Library SimpleMusic/UI/Search/SearchViewController.swift \
  SimpleMusicTests/LibraryViewModelTests.swift
git commit -m "feat: 本地化资料库与搜索界面"
```

---

### Task 5: 本地化迷你播放器、全屏播放器和 iPad 播放面板

**Files:**
- Modify: `SimpleMusic/SimpleMusic/UI/Player/MiniPlayerView.swift:50-65,185-198`
- Modify: `SimpleMusic/SimpleMusic/UI/Player/NowPlayingPanelController.swift:10-20`
- Modify: `SimpleMusic/SimpleMusic/UI/Player/PlayerViewController.swift:65-125,185-200,310-360,445-460`
- Modify: `SimpleMusic/SimpleMusicTests/LibraryViewModelTests.swift:440-580`
- Modify: `SimpleMusic/SimpleMusicTests/PlayerViewControllerTests.swift:1-360,450-520`

**Interfaces:**
- Consumes: `common.play`、`common.pause`、`player.*` 和播放器 accessibility key。
- Produces: 三语言播放控制、空状态、队列位置和无障碍标签。

- [ ] **Step 1: 把播放器测试改为本地化期望并取得行为 RED**

```swift
XCTAssertEqual(title.text, L10n.text("player.empty_title"))
XCTAssertEqual(toggle.accessibilityLabel, L10n.text("common.pause"))
XCTAssertEqual(queue.text, L10n.format("player.queue.position", 2, 4))
XCTAssertEqual(guide.accessibilityLabel, L10n.text("pad.player_guide"))
```

同时断言空队列、队列结束、上一首、下一首、进度和打开/关闭正在播放的 accessibility label。

- [ ] **Step 2: 运行 focused RED**

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' \
  -parallel-testing-enabled NO -testLanguage en \
  -only-testing:SimpleMusicTests/PlayerViewControllerTests \
  -only-testing:SimpleMusicTests/LibraryViewModelTests/testMiniPlayerHidesWithoutTrackAndShowsCurrentMetadata \
  -only-testing:SimpleMusicTests/LibraryViewModelTests/testMiniPlayerUsesPauseOnlyWhilePlaying \
  test CODE_SIGNING_ALLOWED=NO
```

预期：播放器中文硬编码与英文资源不一致。

- [ ] **Step 3: 替换播放器文案**

队列位置必须使用：

```swift
private static func queueText(_ snapshot: PlaybackSnapshot) -> String {
    guard snapshot.queueCount > 0 else { return L10n.text("player.queue_empty") }
    guard let index = snapshot.queueIndex else { return L10n.text("player.queue_ended") }
    return L10n.format("player.queue.position", index + 1, snapshot.queueCount)
}
```

播放/暂停、上一首/下一首、进度、正在播放、接下来播放、空状态和面板关闭标签均使用附录 key。不要改 88pt 默认音符、播放状态机或控制可用矩阵。

- [ ] **Step 4: 运行 focused GREEN**

运行 Step 2 命令，预期全部通过。

- [ ] **Step 5: 提交 Task 5**

```bash
git add SimpleMusic/UI/Player SimpleMusicTests/PlayerViewControllerTests.swift \
  SimpleMusicTests/LibraryViewModelTests.swift
git commit -m "feat: 本地化播放器界面"
```

---

### Task 6: 本地化下载输入、状态和错误信息

**Files:**
- Modify: `SimpleMusic/SimpleMusic/UI/Download/DownloadSheetViewController.swift:80-185,235-350`
- Modify: `SimpleMusic/SimpleMusic/UI/Download/DownloadUnavailableViewController.swift:1-30`
- Modify: `SimpleMusic/SimpleMusicTests/DownloadAndSettingsFlowTests.swift:1-380`
- Modify: `SimpleMusic/SimpleMusicTests/AppCoordinatorTests.swift:70-100`

**Interfaces:**
- Consumes: `download.*`、`common.cancel`、`common.done` 和 storage key。
- Produces: 下载四状态、格式校验错误、进度、成功信息和降级页的三语言文案。

- [ ] **Step 1: 写下载状态失败测试**

真实构造 `DownloadSheetViewController`，断言输入态标题、取消、URL accessibility label、placeholder、说明和提交按钮使用 `L10n`。驱动现有 fake manager 进入 downloading/success/failure，断言：

```swift
XCTAssertEqual(titleLabel.text, L10n.text("download.downloading"))
XCTAssertEqual(progressLabel.text, L10n.format("download.progress_saving", 50))
XCTAssertEqual(successLabel.text, L10n.format("download.success_message", track.title))
XCTAssertEqual(errorLabel.text, L10n.text("download.error.generic"))
```

- [ ] **Step 2: 运行 focused RED**

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' \
  -parallel-testing-enabled NO -testLanguage en \
  -only-testing:SimpleMusicTests/DownloadAndSettingsFlowTests \
  -only-testing:SimpleMusicTests/AppCoordinatorTests/testDownloadUnavailableControllerExplainsRecovery \
  test CODE_SIGNING_ALLOWED=NO
```

预期：输入态或下载状态至少一项仍为中文并失败。

- [ ] **Step 3: 替换下载文案和错误映射**

进度与成功必须使用参数化 key：

```swift
progressLabel.text = L10n.format(
    "download.progress_saving",
    Int((clamped * 100).rounded())
)
successLabel.text = L10n.format("download.success_message", track.title)
```

错误分支严格映射：不支持扩展名→`download.error.unsupported_url`，响应不是音频→`download.error.invalid_payload`，其他错误→`download.error.generic`，非法输入→`download.error.invalid_url`。保留现有 generation、取消和终态封口逻辑。

- [ ] **Step 4: 运行 focused GREEN**

运行 Step 2 命令，预期全部通过。

- [ ] **Step 5: 提交 Task 6**

```bash
git add SimpleMusic/UI/Download SimpleMusicTests/DownloadAndSettingsFlowTests.swift \
  SimpleMusicTests/AppCoordinatorTests.swift
git commit -m "feat: 本地化下载流程"
```

---

### Task 7: 本地化设置、权限状态和关于页

**Files:**
- Modify: `SimpleMusic/SimpleMusic/UI/Settings/SettingsViewController.swift:60-140,230-250`
- Modify: `SimpleMusic/SimpleMusic/UI/Settings/AboutViewController.swift:1-45`
- Modify: `SimpleMusic/SimpleMusicTests/DownloadAndSettingsFlowTests.swift:280-380`

**Interfaces:**
- Consumes: `settings.*`、`about.*`、`app.name`。
- Produces: 三语言设置分区、权限状态、下载选项和关于页。

- [ ] **Step 1: 为设置和关于真实页面写失败断言**

```swift
XCTAssertEqual(settings.title, L10n.text("settings.title"))
XCTAssertEqual(cellularSwitch.accessibilityLabel, L10n.text("settings.cellular_title"))
XCTAssertEqual(about.title, L10n.text("about.page_title"))
XCTAssertTrue(aboutCopy.contains(L10n.text("about.privacy_detail")))
```

遍历 `.notDetermined`、`.denied`、`.restricted`、`.authorized`，断言 permission status label 分别使用 `settings.permission_status.*`。

- [ ] **Step 2: 运行 focused RED**

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' \
  -parallel-testing-enabled NO -testLanguage en \
  -only-testing:SimpleMusicTests/DownloadAndSettingsFlowTests test CODE_SIGNING_ALLOWED=NO
```

预期：设置或关于页中文硬编码与英文资源不一致。

- [ ] **Step 3: 替换设置和关于文案**

页面标题、section heading、row title/detail、switch accessibility label、权限状态、关于标题、品牌名、副标题、格式说明和隐私说明均使用附录 key。品牌 label 使用 `L10n.text("app.name")`，不要在代码中分别判断简繁中文。

- [ ] **Step 4: 运行 focused GREEN**

运行 Step 2 命令，预期全部通过。

- [ ] **Step 5: 提交 Task 7**

```bash
git add SimpleMusic/UI/Settings SimpleMusicTests/DownloadAndSettingsFlowTests.swift
git commit -m "feat: 本地化设置与关于页面"
```

---

### Task 8: 全局文字审计、三语言回归与产物验证

**Files:**
- Modify: `SimpleMusic/SimpleMusicTests/LocalizationTests.swift`
- Modify: `SimpleMusic/docs/testing/2026-08-14-simple-music-player-verification.md`（追加本地化验证记录）

**Interfaces:**
- Consumes: Tasks 1-7 的完整资源和本地化生产界面。
- Produces: 无遗漏审计、三语言测试/启动证据、最终验证记录。

- [ ] **Step 1: 新增生产 Swift 用户文案审计测试**

在 `LocalizationTests` 读取 production Swift 源码，匹配字符串字面量中的汉字。允许列表只包含：

- `NSLog(...)` 的开发者诊断。
- `fatalError(...)` 和 `preconditionFailure(...)` 的不可用初始化/内部不变量。
- 明确列出的测试 fixture 不在 production 目录，因此无需允许。

测试失败信息输出 `file:line` 和原始 literal；不要以整文件白名单绕过遗漏。

- [ ] **Step 2: 运行审计 RED 或确认直接 GREEN**

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' \
  -parallel-testing-enabled NO -testLanguage en \
  -only-testing:SimpleMusicTests/LocalizationTests test CODE_SIGNING_ALLOWED=NO
```

若失败，逐条判断是否用户可见：真实遗漏必须回到 Task 2-7 中对应的 owning task，补资源、测试并使用该 task 的提交范围重新提交；开发者诊断只加入精确 literal/调用类型允许规则。若直接 GREEN，记录为审计证据，不制造无意义生产改动。

- [ ] **Step 3: 分别运行三语言资源和主要 UI focused 测试**

依次使用 `-testLanguage en`、`-testLanguage zh-Hans`、`-testLanguage zh-Hant` 运行：

```bash
for sm_language in en zh-Hans zh-Hant; do
  xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' \
    -parallel-testing-enabled NO -testLanguage "$sm_language" \
    -only-testing:SimpleMusicTests/LocalizationTests \
    -only-testing:SimpleMusicTests/AppCoordinatorTests \
    -only-testing:SimpleMusicTests/LibraryViewModelTests \
    -only-testing:SimpleMusicTests/PlayerViewControllerTests \
    -only-testing:SimpleMusicTests/DownloadAndSettingsFlowTests \
    test CODE_SIGNING_ALLOWED=NO || exit 1
done
```

预期：三次均 `** TEST SUCCEEDED **`；机器汇总 failed/skipped 均为 0。

- [ ] **Step 4: 运行全量测试**

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' \
  test CODE_SIGNING_ALLOWED=NO
```

预期：`** TEST SUCCEEDED **`，xcresult `failedTests = 0`、`skippedTests = 0`。

- [ ] **Step 5: 运行模拟器和设备构建**

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

预期：两次均 `** BUILD SUCCEEDED **`；本次生产 Swift 无新增 warning/error。

- [ ] **Step 6: 审计构建产物本地化资源**

使用独立 DerivedData：

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/simplemusic-localization-dd \
  build CODE_SIGNING_ALLOWED=NO
find /private/tmp/simplemusic-localization-dd/Build/Products/Debug-iphonesimulator/SimpleMusic.app \
  -maxdepth 2 -type f \( -name 'Localizable.strings' -o -name 'Localizable.stringsdict' \
  -o -name 'InfoPlist.strings' \) -print
```

预期：App bundle 含 `en.lproj`、`zh-Hans.lproj`、`zh-Hant.lproj` 三套资源。用 `plutil -p` 读取三套 `InfoPlist.strings`，核对 `DiskTone`、`听见`、`聽見` 和权限说明。

- [ ] **Step 7: 三语言 iPhone/iPad 启动检查**

使用当前可用的 iPhone 17 Pro Max iOS 26.4（UDID `6B1893C7-7A88-4EF0-A804-35BA9A1988B1`）与 iPad (A16) iOS 26.4（UDID `D89CD6CE-158A-4218-9BA4-8A25D6D26C45`）安装同一构建产物。若本机设备清单已变化，先运行 `xcrun simctl list devices available`，在验证记录中写明替代设备的完整名称、OS 与 UDID，再继续。按以下六组明确命令启动：

```bash
xcrun simctl launch --terminate-running-process 6B1893C7-7A88-4EF0-A804-35BA9A1988B1 DB.SimpleMusic -AppleLanguages '(en)'
xcrun simctl launch --terminate-running-process 6B1893C7-7A88-4EF0-A804-35BA9A1988B1 DB.SimpleMusic -AppleLanguages '(zh-Hans)'
xcrun simctl launch --terminate-running-process 6B1893C7-7A88-4EF0-A804-35BA9A1988B1 DB.SimpleMusic -AppleLanguages '(zh-Hant)'
xcrun simctl launch --terminate-running-process D89CD6CE-158A-4218-9BA4-8A25D6D26C45 DB.SimpleMusic -AppleLanguages '(en)'
xcrun simctl launch --terminate-running-process D89CD6CE-158A-4218-9BA4-8A25D6D26C45 DB.SimpleMusic -AppleLanguages '(zh-Hans)'
xcrun simctl launch --terminate-running-process D89CD6CE-158A-4218-9BA4-8A25D6D26C45 DB.SimpleMusic -AppleLanguages '(zh-Hant)'
```

分别检查首页/授权、资料库、搜索、播放器、下载、设置和关于页。截图保存为 `/private/tmp/simplemusic-localization-iphone-en.png`、`/private/tmp/simplemusic-localization-iphone-zh-Hans.png`、`/private/tmp/simplemusic-localization-iphone-zh-Hant.png`、`/private/tmp/simplemusic-localization-ipad-en.png`、`/private/tmp/simplemusic-localization-ipad-zh-Hans.png`、`/private/tmp/simplemusic-localization-ipad-zh-Hant.png`。预期无 localization key、混合语言、明显截断或启动崩溃；真实系统音乐权限文案标记为真机发布前复核。

- [ ] **Step 8: 更新验证记录并提交**

在验证文档追加：三语言 key 数、focused/full 测试结果、sim/device build、产物资源路径、启动截图路径、环境 warning 和真机 deferred 项。

```bash
git add SimpleMusicTests/LocalizationTests.swift \
  docs/testing/2026-08-14-simple-music-player-verification.md
git diff --cached --check
git commit -m "test: 完成SimpleMusic三语言验证"
```

任何审计遗漏都必须在 Step 2 回到对应 owning task 完成并提交，因此 Task 8 只暂存上述两个验证文件，不提交用户的 Xcode `xcuserdata`。

---

## 附录 A：`Localizable.strings` 完整内容

### `en.lproj/Localizable.strings`

```text
"app.name" = "DiskTone";
"common.cancel" = "Cancel";
"common.delete" = "Delete";
"common.play" = "Play";
"common.pause" = "Pause";
"common.done" = "Done";
"common.library" = "Library";
"common.search" = "Search";
"common.settings" = "Settings";
"track.unknown_artist" = "Unknown Artist";
"track.unknown_album" = "Unknown Album";
"track.downloaded" = "Downloaded";
"track.more_actions" = "More Actions";
"track_group.accessibility" = "%1$@, %2$@";
"storage.persistence.unavailable" = "Local storage is temporarily unavailable. DiskTone is using memory only; your original data was not deleted. Restart the app to try again.";
"storage.persistence.unavailable_with_detail" = "%1$@ (%2$@)";
"storage.download.unavailable" = "Download storage is temporarily unavailable. Check your device storage and restart the app to try again.";
"storage.download.unavailable_short" = "Download storage is temporarily unavailable.";
"permission.title" = "Access Your Music Library";
"permission.body" = "Allow DiskTone to access songs, albums, and artist information on this device. Your music stays on this device for browsing and playback.";
"permission.allow" = "Allow Access";
"permission.not_now" = "Not Now";
"permission.direct_link_note" = "You can also paste a direct .mp3, .m4a, or .wav audio link in Library, then play the download alongside your system music.";
"tab.library" = "Library";
"tab.search" = "Search";
"pad.player_guide" = "Tap the mini player to open the player on the right";
"library.title" = "Library";
"library.download_audio" = "Download Audio";
"library.open_settings" = "Open Settings";
"library.recently_added" = "Recently Added";
"library.permission_required" = "Music Library access is not enabled. Only downloaded songs are shown.";
"library.empty" = "Your library is empty.\nAllow Music Library access or add a local audio file to get started.";
"library.error.delete_local" = "Unable to delete the local song";
"library.error.system" = "Unable to load the system music library";
"library.error.local" = "Unable to load downloaded songs";
"category.songs" = "Songs";
"category.albums" = "Albums";
"category.artists" = "Artists";
"category.downloaded" = "Downloaded";
"list.play_all" = "Play All";
"list.shuffle" = "Shuffle";
"list.sort" = "Sort";
"deletion.title" = "Delete Local Song?";
"deletion.message" = "Remove “%@” and its download record from this device?";
"search.title" = "Search";
"search.placeholder" = "Search songs, artists, or albums";
"search.empty_library" = "There are no songs in your library";
"search.no_results" = "No matching songs found";
"player.open_now_playing" = "Open Now Playing";
"player.close_now_playing" = "Close Now Playing";
"player.progress" = "Playback Progress";
"player.previous" = "Previous Track";
"player.next" = "Next Track";
"player.now_playing" = "Now Playing";
"player.up_next" = "Up Next";
"player.empty_title" = "Nothing Playing";
"player.empty_subtitle" = "Choose a song to start playing";
"player.queue_empty" = "Queue is empty";
"player.queue_ended" = "Queue ended";
"player.queue.position" = "Track %1$d of %2$d";
"download.unavailable.title" = "Downloads Unavailable";
"download.title" = "Download Audio from a Link";
"download.url_accessibility" = "Direct Audio File Link";
"download.url_placeholder" = "Paste a direct .mp3, .m4a, or .wav link";
"download.direct_only" = "Only direct audio file links are supported. Music services and ordinary web pages are not parsed.";
"download.submit" = "Download to Library";
"download.downloading" = "Downloading";
"download.cancel" = "Cancel Download";
"download.success_title" = "Added to Library";
"download.play_now" = "Play Now";
"download.failure_title" = "Download Failed";
"download.reenter" = "Enter Another Link";
"download.progress_saving" = "%1$d%% · Saving to your local library";
"download.success_message" = "%@ has been downloaded and is available offline.";
"download.error.invalid_url" = "Enter a valid direct audio file link.";
"download.error.unsupported_url" = "Only direct MP3, M4A, or WAV file links are supported.";
"download.error.invalid_payload" = "The link did not return a downloadable audio file.";
"download.error.generic" = "The download could not be completed. Check the link and your network, then try again.";
"settings.title" = "Settings";
"settings.permission_title" = "Music Library Access";
"settings.cellular_title" = "Allow Cellular Downloads";
"settings.cellular_detail" = "When off, audio downloads use Wi-Fi only";
"settings.autoplay_title" = "Play After Download";
"settings.autoplay_detail" = "When off, the download result stays on screen";
"settings.about_title" = "About DiskTone";
"settings.section.library" = "Library";
"settings.section.download" = "Downloads";
"settings.section.about" = "About";
"settings.permission_status.not_requested" = "Not Requested";
"settings.permission_status.denied" = "Denied · Open Settings";
"settings.permission_status.restricted" = "Restricted · Open Settings";
"settings.permission_status.authorized" = "Allowed";
"settings.permission_status.open_settings" = "Open Settings";
"about.page_title" = "About DiskTone";
"about.subtitle" = "Designed for music on your device and local downloads";
"about.formats_title" = "MP3, M4A, WAV";
"about.formats_detail" = "Only direct audio file download links are supported.";
"about.privacy_title" = "Privacy";
"about.privacy_detail" = "Music stays on this device. It is never uploaded or synced to the cloud, and DiskTone does not parse music services or ordinary web pages.";
```

### `zh-Hans.lproj/Localizable.strings`

```text
"app.name" = "听见";
"common.cancel" = "取消";
"common.delete" = "删除";
"common.play" = "播放";
"common.pause" = "暂停";
"common.done" = "完成";
"common.library" = "资料库";
"common.search" = "搜索";
"common.settings" = "设置";
"track.unknown_artist" = "未知艺人";
"track.unknown_album" = "未知专辑";
"track.downloaded" = "已下载";
"track.more_actions" = "更多操作";
"track_group.accessibility" = "%1$@，%2$@";
"storage.persistence.unavailable" = "本地持久化暂不可用，已进入内存模式；原始资料未删除，请重启应用重试。";
"storage.persistence.unavailable_with_detail" = "%1$@（%2$@）";
"storage.download.unavailable" = "下载存储暂不可用，请检查设备空间并重启应用后重试。";
"storage.download.unavailable_short" = "下载存储暂不可用";
"permission.title" = "访问你的音乐资料库";
"permission.body" = "允许「听见」读取设备上的歌曲、专辑和艺人信息。你的音乐仅在本机浏览和播放。";
"permission.allow" = "允许访问";
"permission.not_now" = "暂不";
"permission.direct_link_note" = "也可以在资料库中粘贴 .mp3、.m4a 或 .wav 音频直链，下载后与系统歌曲一起播放。";
"tab.library" = "资料库";
"tab.search" = "搜索";
"pad.player_guide" = "点击迷你播放器，从右侧打开播放页面";
"library.title" = "资料库";
"library.download_audio" = "下载音频";
"library.open_settings" = "打开设置";
"library.recently_added" = "最近添加";
"library.permission_required" = "尚未授权系统音乐资料库，只显示已下载歌曲。";
"library.empty" = "资料库还是空的\n授权系统音乐或添加本地音频后会显示在这里。";
"library.error.delete_local" = "无法删除本地歌曲";
"library.error.system" = "无法读取系统音乐资料库";
"library.error.local" = "无法读取已下载歌曲";
"category.songs" = "歌曲";
"category.albums" = "专辑";
"category.artists" = "艺人";
"category.downloaded" = "已下载";
"list.play_all" = "全部播放";
"list.shuffle" = "随机播放";
"list.sort" = "排序";
"deletion.title" = "删除本地歌曲？";
"deletion.message" = "将从此设备移除“%@”及其下载记录。";
"search.title" = "搜索";
"search.placeholder" = "搜索歌曲、艺人或专辑";
"search.empty_library" = "资料库中没有歌曲";
"search.no_results" = "没有找到匹配的歌曲";
"player.open_now_playing" = "打开正在播放";
"player.close_now_playing" = "关闭正在播放";
"player.progress" = "播放进度";
"player.previous" = "上一首";
"player.next" = "下一首";
"player.now_playing" = "正在播放";
"player.up_next" = "接下来播放";
"player.empty_title" = "尚未播放";
"player.empty_subtitle" = "选择一首歌曲开始播放";
"player.queue_empty" = "队列为空";
"player.queue_ended" = "队列已结束";
"player.queue.position" = "第 %1$d / %2$d 首";
"download.unavailable.title" = "下载不可用";
"download.title" = "从链接下载音频";
"download.url_accessibility" = "音频文件直链";
"download.url_placeholder" = "粘贴 .mp3、.m4a 或 .wav 直链";
"download.direct_only" = "仅支持直接指向音频文件的链接，不解析音乐平台或普通网页链接。";
"download.submit" = "下载到资料库";
"download.downloading" = "正在下载";
"download.cancel" = "取消下载";
"download.success_title" = "已添加到资料库";
"download.play_now" = "立即播放";
"download.failure_title" = "下载失败";
"download.reenter" = "重新输入";
"download.progress_saving" = "%1$d%% · 正在保存到本地资料库";
"download.success_message" = "%@ 已下载完成，可离线播放。";
"download.error.invalid_url" = "请输入有效的音频文件直链。";
"download.error.unsupported_url" = "仅支持直接指向 MP3、M4A 或 WAV 文件的链接。";
"download.error.invalid_payload" = "链接未返回可下载的音频文件。";
"download.error.generic" = "下载未完成，请检查链接和网络后重试。";
"settings.title" = "设置";
"settings.permission_title" = "音乐资料库权限";
"settings.cellular_title" = "允许蜂窝网络下载";
"settings.cellular_detail" = "关闭时仅通过 Wi-Fi 下载音频";
"settings.autoplay_title" = "下载后自动播放";
"settings.autoplay_detail" = "关闭时完成后停留在下载结果页";
"settings.about_title" = "关于听见";
"settings.section.library" = "资料库";
"settings.section.download" = "下载";
"settings.section.about" = "关于";
"settings.permission_status.not_requested" = "未请求";
"settings.permission_status.denied" = "已拒绝 · 去设置";
"settings.permission_status.restricted" = "受限 · 去设置";
"settings.permission_status.authorized" = "已允许";
"settings.permission_status.open_settings" = "去设置";
"about.page_title" = "关于听见";
"about.subtitle" = "为设备音乐与本地下载而设计";
"about.formats_title" = "MP3、M4A、WAV";
"about.formats_detail" = "仅支持直接指向音频文件的下载链接。";
"about.privacy_title" = "隐私原则";
"about.privacy_detail" = "音乐仅保存在本机，不上传、不进行云同步；不解析音乐平台或普通网页链接。";
```

### `zh-Hant.lproj/Localizable.strings`

```text
"app.name" = "聽見";
"common.cancel" = "取消";
"common.delete" = "刪除";
"common.play" = "播放";
"common.pause" = "暫停";
"common.done" = "完成";
"common.library" = "資料庫";
"common.search" = "搜尋";
"common.settings" = "設定";
"track.unknown_artist" = "未知藝人";
"track.unknown_album" = "未知專輯";
"track.downloaded" = "已下載";
"track.more_actions" = "更多操作";
"track_group.accessibility" = "%1$@，%2$@";
"storage.persistence.unavailable" = "本機持久化儲存空間暫時無法使用，已切換為記憶體模式；原始資料未刪除，請重新啟動 App 後再試。";
"storage.persistence.unavailable_with_detail" = "%1$@（%2$@）";
"storage.download.unavailable" = "下載儲存空間暫時無法使用，請檢查裝置空間並重新啟動 App 後再試。";
"storage.download.unavailable_short" = "下載儲存空間暫時無法使用";
"permission.title" = "存取你的音樂資料庫";
"permission.body" = "允許「聽見」讀取裝置上的歌曲、專輯與藝人資訊。你的音樂只會在本機瀏覽與播放。";
"permission.allow" = "允許存取";
"permission.not_now" = "暫不";
"permission.direct_link_note" = "你也可以在資料庫中貼上 .mp3、.m4a 或 .wav 音訊直連，下載後與系統歌曲一起播放。";
"tab.library" = "資料庫";
"tab.search" = "搜尋";
"pad.player_guide" = "點一下迷你播放器，從右側開啟播放頁面";
"library.title" = "資料庫";
"library.download_audio" = "下載音訊";
"library.open_settings" = "開啟設定";
"library.recently_added" = "最近加入";
"library.permission_required" = "尚未允許存取系統音樂資料庫，目前只顯示已下載歌曲。";
"library.empty" = "資料庫仍是空的\n允許存取系統音樂或加入本機音訊後，歌曲會顯示在這裡。";
"library.error.delete_local" = "無法刪除本機歌曲";
"library.error.system" = "無法讀取系統音樂資料庫";
"library.error.local" = "無法讀取已下載歌曲";
"category.songs" = "歌曲";
"category.albums" = "專輯";
"category.artists" = "藝人";
"category.downloaded" = "已下載";
"list.play_all" = "全部播放";
"list.shuffle" = "隨機播放";
"list.sort" = "排序";
"deletion.title" = "刪除本機歌曲？";
"deletion.message" = "將從此裝置移除「%@」及其下載記錄。";
"search.title" = "搜尋";
"search.placeholder" = "搜尋歌曲、藝人或專輯";
"search.empty_library" = "資料庫中沒有歌曲";
"search.no_results" = "找不到符合的歌曲";
"player.open_now_playing" = "開啟播放中項目";
"player.close_now_playing" = "關閉播放中項目";
"player.progress" = "播放進度";
"player.previous" = "上一首";
"player.next" = "下一首";
"player.now_playing" = "正在播放";
"player.up_next" = "接著播放";
"player.empty_title" = "尚未播放";
"player.empty_subtitle" = "選擇一首歌曲開始播放";
"player.queue_empty" = "播放佇列是空的";
"player.queue_ended" = "播放佇列已結束";
"player.queue.position" = "第 %1$d / %2$d 首";
"download.unavailable.title" = "無法下載";
"download.title" = "從連結下載音訊";
"download.url_accessibility" = "音訊檔案直連";
"download.url_placeholder" = "貼上 .mp3、.m4a 或 .wav 直連";
"download.direct_only" = "僅支援直接指向音訊檔案的連結，不會解析音樂平台或一般網頁連結。";
"download.submit" = "下載到資料庫";
"download.downloading" = "正在下載";
"download.cancel" = "取消下載";
"download.success_title" = "已加入資料庫";
"download.play_now" = "立即播放";
"download.failure_title" = "下載失敗";
"download.reenter" = "重新輸入";
"download.progress_saving" = "%1$d%% · 正在儲存到本機資料庫";
"download.success_message" = "%@ 已下載完成，可離線播放。";
"download.error.invalid_url" = "請輸入有效的音訊檔案直連。";
"download.error.unsupported_url" = "僅支援直接指向 MP3、M4A 或 WAV 檔案的連結。";
"download.error.invalid_payload" = "連結未傳回可下載的音訊檔案。";
"download.error.generic" = "下載尚未完成，請檢查連結與網路後再試一次。";
"settings.title" = "設定";
"settings.permission_title" = "音樂資料庫權限";
"settings.cellular_title" = "允許使用行動網路下載";
"settings.cellular_detail" = "關閉時只會透過 Wi-Fi 下載音訊";
"settings.autoplay_title" = "下載後自動播放";
"settings.autoplay_detail" = "關閉時，下載完成後會停留在結果頁面";
"settings.about_title" = "關於聽見";
"settings.section.library" = "資料庫";
"settings.section.download" = "下載";
"settings.section.about" = "關於";
"settings.permission_status.not_requested" = "尚未詢問";
"settings.permission_status.denied" = "已拒絕 · 前往設定";
"settings.permission_status.restricted" = "受限制 · 前往設定";
"settings.permission_status.authorized" = "已允許";
"settings.permission_status.open_settings" = "前往設定";
"about.page_title" = "關於聽見";
"about.subtitle" = "專為裝置音樂與本機下載設計";
"about.formats_title" = "MP3、M4A、WAV";
"about.formats_detail" = "僅支援直接指向音訊檔案的下載連結。";
"about.privacy_title" = "隱私原則";
"about.privacy_detail" = "音樂只會儲存在本機，不會上傳或進行雲端同步；也不會解析音樂平台或一般網頁連結。";
```

## 附录 B：复数与 InfoPlist 资源

### `en.lproj/Localizable.stringsdict`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>tracks.count</key><dict>
    <key>NSStringLocalizedFormatKey</key><string>%#@songs@</string>
    <key>songs</key><dict>
      <key>NSStringFormatSpecTypeKey</key><string>NSStringPluralRuleType</string>
      <key>NSStringFormatValueTypeKey</key><string>d</string>
      <key>one</key><string>%d song</string>
      <key>other</key><string>%d songs</string>
    </dict>
  </dict>
</dict></plist>
```

### `zh-Hans.lproj/Localizable.stringsdict`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>tracks.count</key><dict>
    <key>NSStringLocalizedFormatKey</key><string>%#@songs@</string>
    <key>songs</key><dict>
      <key>NSStringFormatSpecTypeKey</key><string>NSStringPluralRuleType</string>
      <key>NSStringFormatValueTypeKey</key><string>d</string>
      <key>other</key><string>%d 首</string>
    </dict>
  </dict>
</dict></plist>
```

### `zh-Hant.lproj/Localizable.stringsdict`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>tracks.count</key><dict>
    <key>NSStringLocalizedFormatKey</key><string>%#@songs@</string>
    <key>songs</key><dict>
      <key>NSStringFormatSpecTypeKey</key><string>NSStringPluralRuleType</string>
      <key>NSStringFormatValueTypeKey</key><string>d</string>
      <key>other</key><string>%d 首</string>
    </dict>
  </dict>
</dict></plist>
```

### `InfoPlist.strings`

```text
// en.lproj/InfoPlist.strings
"CFBundleDisplayName" = "DiskTone";
"NSAppleMusicUsageDescription" = "DiskTone uses your music library to browse and play music on this device.";

// zh-Hans.lproj/InfoPlist.strings
"CFBundleDisplayName" = "听见";
"NSAppleMusicUsageDescription" = "“听见”使用你的音乐资料库，以浏览并播放此设备上的音乐。";

// zh-Hant.lproj/InfoPlist.strings
"CFBundleDisplayName" = "聽見";
"NSAppleMusicUsageDescription" = "「聽見」會使用你的音樂資料庫，以瀏覽並播放此裝置上的音樂。";
```
