# DiskTone 扩展音效预设 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为下载到本地的歌曲增加“全景环绕、摇滚经典、动感电音、清晰人声”四种组合音效，并让列表播放、单曲循环、随机播放三种模式按钮使用一致的强调色。

**Architecture:** 保留 `AudioEffectSettings`、设置持久化、播放协调器和页面导航结构；把本地音效驱动从单一混响扩展为 `AVAudioPlayerNode → AVAudioUnitEQ → AVAudioUnitReverb → mainMixerNode`。四个新预设由纯 Swift profile 解析为 EQ 频段和混响参数，强度滑块统一缩放增益与 wet/dry mix。系统音乐仍不接入本地音效链。

**Tech Stack:** Swift 5、UIKit、AVFoundation、Combine、XCTest、iOS 15.0+、CocoaPods、SnapKit。

**Spec:** `docs/superpowers/specs/2026-08-22-audio-effect-presets-design.md`

**Working Directory:** 所有命令均从 `/Users/db/Documents/git/my/music/SimpleMusic/SimpleMusic` 执行，文件路径也以该目录为基准。

## Global Constraints

- 不增加第三方依赖，不调整 CocoaPods、部署版本、竖屏配置、页面布局或导航。
- 新增四个预设只作用于 `.downloaded` 本地歌曲；系统音乐继续显示现有不可用提示。
- “全景环绕”是 EQ + 房间混响的立体声拓宽模拟，不实现 Dolby、空间音频或头部追踪。
- 保留现有 `AudioEffectPreset` raw value 和 `wetDryMix` 存储字段，不做数据迁移。
- `wetDryMix` 在 UI 上改称“音效强度”，同时缩放 EQ 增益和混响比例；`off` 必须保持原始输出。
- 播放 generation、lease、切换、seek、完成回调和失败回退语义不得改变。
- 新增文案同时提供 `en`、`zh-Hans`、`zh-Hant`，英文继续作为系统语言缺失时的回退。
- 中文注释只解释本地音效链、强度缩放和系统音乐边界。
- 当前 `PlayerViewController.swift` 已有用户未提交的 `.caption1 → .title1` 修改；不得覆盖或暂存该 hunk。
- 永远不暂存 `SimpleMusic.xcworkspace/xcuserdata/.../UserInterfaceState.xcuserstate`。
- 每个任务执行可信 RED、最小 GREEN、聚焦回归、`git diff --check` 和中文 commit。

---

## File Structure

### 修改文件

- `SimpleMusic/Domain/PlaybackSnapshot.swift`：增加预设枚举值和纯 Swift 音效 profile。
- `SimpleMusic/Persistence/SettingsStore.swift`：生产逻辑保持不变；测试验证新增 raw value 与现有存储兼容。
- `SimpleMusic/Playback/LocalPlaybackBackend.swift`：升级本地音频引擎链并把混响专用命名改成组合音效命名。
- `SimpleMusic/UI/Player/PlayerViewController.swift`：增加四个名称、统一强度文案、统一播放模式颜色。
- `SimpleMusic/en.lproj/Localizable.strings`：英文音效名称和通用强度文案。
- `SimpleMusic/zh-Hans.lproj/Localizable.strings`：简体中文音效名称和通用强度文案。
- `SimpleMusic/zh-Hant.lproj/Localizable.strings`：繁体中文音效名称和通用强度文案。
- `SimpleMusicTests/SettingsStoreTests.swift`：新预设 raw value 持久化及 profile 强度测试。
- `SimpleMusicTests/PlaybackBackendLifecycleTests.swift`：组合音效驱动切换、实时更新和失败回退。
- `SimpleMusicTests/PlaybackCoordinatorTests.swift`：系统音乐不可用、本地歌曲设置传播回归。
- `SimpleMusicTests/PlayerViewControllerTests.swift`：预设显示、选择和播放模式 tint。
- `SimpleMusicTests/LocalizationTests.swift`：三语言 key 和生产字面量审计。
- `docs/app-pages-and-features.md`：更新播放页音效说明。

---

### Task 1: 扩展音效领域模型与持久化兼容

**Files:**
- Modify: `SimpleMusic/Domain/PlaybackSnapshot.swift`
- Modify: `SimpleMusicTests/SettingsStoreTests.swift`

**Interfaces:**

```swift
nonisolated enum AudioEffectFilterKind: Equatable, Sendable {
    case lowShelf
    case parametric
    case highShelf
}

nonisolated struct AudioEffectBandProfile: Equatable, Sendable {
    let kind: AudioEffectFilterKind
    let frequency: Float
    let bandwidth: Float
    let gain: Float
}

nonisolated enum AudioEffectReverbProfile: Equatable, Sendable {
    case smallRoom
    case mediumRoom
    case largeRoom
    case mediumHall
    case largeHall
    case cathedral
    case plate
}

nonisolated struct ResolvedAudioEffectProfile: Equatable, Sendable {
    let bands: [AudioEffectBandProfile]
    let reverb: AudioEffectReverbProfile?
    let wetDryMix: Float
}
```

- [ ] **Step 1: 写新 raw value 与 profile 强度测试**

在 `SettingsStoreTests.swift` 增加：

```swift
func testNewAudioEffectPresetRawValuesRoundTripThroughSettingsStore() {
    let suiteName = "\(#function).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = SettingsStore(defaults: defaults)
    let presets: [AudioEffectPreset] = [
        .panoramicSurround,
        .classicRock,
        .dynamicElectronic,
        .clearVocal
    ]

    for preset in presets {
        store.audioEffectSettings = AudioEffectSettings(preset: preset, wetDryMix: 67)
        let restored = SettingsStore(defaults: defaults).audioEffectSettings
        XCTAssertEqual(restored.preset, preset)
        XCTAssertEqual(restored.wetDryMix, 67)
    }
}

func testPanoramicProfileScalesEQAndReverbWithIntensity() {
    let full = AudioEffectPreset.panoramicSurround.resolvedProfile(intensity: 100)
    let half = AudioEffectPreset.panoramicSurround.resolvedProfile(intensity: 50)

    XCTAssertEqual(full.bands.map(\.frequency), [120, 600, 7_000])
    XCTAssertEqual(full.bands.map(\.gain), [1.5, -1.5, 2])
    XCTAssertEqual(half.bands.map(\.gain), [0.75, -0.75, 1])
    XCTAssertEqual(full.reverb, .largeRoom)
    XCTAssertEqual(full.wetDryMix, 30)
    XCTAssertEqual(half.wetDryMix, 15)
}

func testOffProfileBypassesEQAndReverb() {
    let profile = AudioEffectPreset.off.resolvedProfile(intensity: 100)
    XCTAssertTrue(profile.bands.isEmpty)
    XCTAssertNil(profile.reverb)
    XCTAssertEqual(profile.wetDryMix, 0)
}
```

- [ ] **Step 2: 运行测试取得可信 RED**

```bash
set -o pipefail
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO \
  -only-testing:SimpleMusicTests/SettingsStoreTests test CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee /tmp/audio-effect-task1-red.log
```

预期：exit 65，只因四个 case 或 `resolvedProfile` 不存在而失败；测试 helper 自身编译错误不算 RED。

- [ ] **Step 3: 增加四个稳定 raw value**

在 `AudioEffectPreset` 末尾追加，不能改旧 case 顺序或名称：

```swift
case panoramicSurround
case classicRock
case dynamicElectronic
case clearVocal
```

- [ ] **Step 4: 实现纯 Swift profile 解析**

在 `PlaybackSnapshot.swift` 定义上述 profile 类型，并实现：

```swift
nonisolated extension AudioEffectPreset {
    func resolvedProfile(intensity: Float) -> ResolvedAudioEffectProfile {
        let scale = min(100, max(0, intensity)) / 100
        let baseBands: [AudioEffectBandProfile]
        let reverb: AudioEffectReverbProfile?
        let maximumWetMix: Float

        switch self {
        case .off:
            return ResolvedAudioEffectProfile(bands: [], reverb: nil, wetDryMix: 0)
        case .panoramicSurround:
            baseBands = [
                .init(kind: .lowShelf, frequency: 120, bandwidth: 1, gain: 1.5),
                .init(kind: .parametric, frequency: 600, bandwidth: 1, gain: -1.5),
                .init(kind: .highShelf, frequency: 7_000, bandwidth: 1, gain: 2)
            ]
            reverb = .largeRoom
            maximumWetMix = 30
        case .classicRock:
            baseBands = [
                .init(kind: .lowShelf, frequency: 90, bandwidth: 1, gain: 3),
                .init(kind: .parametric, frequency: 300, bandwidth: 1, gain: -1),
                .init(kind: .parametric, frequency: 1_800, bandwidth: 1, gain: 2.5),
                .init(kind: .highShelf, frequency: 6_000, bandwidth: 1, gain: 2)
            ]
            reverb = .plate
            maximumWetMix = 12
        case .dynamicElectronic:
            baseBands = [
                .init(kind: .lowShelf, frequency: 70, bandwidth: 1, gain: 4),
                .init(kind: .parametric, frequency: 500, bandwidth: 1, gain: -2),
                .init(kind: .highShelf, frequency: 8_000, bandwidth: 1, gain: 3)
            ]
            reverb = .plate
            maximumWetMix = 16
        case .clearVocal:
            baseBands = [
                .init(kind: .parametric, frequency: 250, bandwidth: 1, gain: -2),
                .init(kind: .parametric, frequency: 2_500, bandwidth: 1, gain: 3),
                .init(kind: .highShelf, frequency: 6_000, bandwidth: 1, gain: 2)
            ]
            reverb = .smallRoom
            maximumWetMix = 8
        case .smallRoom, .mediumRoom, .largeRoom, .mediumHall, .largeHall, .cathedral, .plate:
            baseBands = []
            reverb = legacyReverbProfile
            maximumWetMix = 100
        }

        let bands = baseBands.map {
            AudioEffectBandProfile(
                kind: $0.kind,
                frequency: $0.frequency,
                bandwidth: $0.bandwidth,
                gain: $0.gain * scale
            )
        }
        return ResolvedAudioEffectProfile(
            bands: bands,
            reverb: reverb,
            wetDryMix: maximumWetMix * scale
        )
    }
}
```

同一 extension 内的 `legacyReverbProfile` 必须显式实现，不能依赖 AVFoundation：

```swift
private var legacyReverbProfile: AudioEffectReverbProfile? {
    switch self {
    case .off, .panoramicSurround, .classicRock, .dynamicElectronic, .clearVocal:
        return nil
    case .smallRoom: return .smallRoom
    case .mediumRoom: return .mediumRoom
    case .largeRoom: return .largeRoom
    case .mediumHall: return .mediumHall
    case .largeHall: return .largeHall
    case .cathedral: return .cathedral
    case .plate: return .plate
    }
}
```

这样原 7 个混响 case 保持相同原厂 preset 语义，旧预设的 `wetDryMix` 仍直接使用 0...100 强度。

- [ ] **Step 5: 运行 GREEN 与提交**

重复 Step 2，预期 `SettingsStoreTests` 全绿；随后：

```bash
git diff --check
git add SimpleMusic/Domain/PlaybackSnapshot.swift SimpleMusicTests/SettingsStoreTests.swift
git commit -m "feat: 添加组合音效预设参数"
```

---

### Task 2: 升级本地音频引擎为 EQ + Reverb

**Files:**
- Modify: `SimpleMusic/Playback/LocalPlaybackBackend.swift`
- Modify: `SimpleMusicTests/PlaybackBackendLifecycleTests.swift`
- Modify: `SimpleMusicTests/PlaybackCoordinatorTests.swift`

- [ ] **Step 1: 先把测试 fake 和断言改成组合音效语义**

在 `PlaybackBackendLifecycleTests.swift` 将测试专用名称改为：

```swift
@MainActor
private final class FakeAudioEffectPlayer: AudioEffectAudioPlaying {
    var elapsed: TimeInterval = 12
    var duration: TimeInterval = 60
    var onFinish: (() -> Void)?
    private(set) var loadedSettings = [AudioEffectSettings]()
    private(set) var updatedSettings = [AudioEffectSettings]()
    private(set) var playCallCount = 0
    var loadError: Error?

    func load(url: URL, startingAt seconds: TimeInterval, settings: AudioEffectSettings) throws {
        if let loadError { throw loadError }
        elapsed = seconds
        loadedSettings.append(settings)
    }

    func update(settings: AudioEffectSettings) { updatedSettings.append(settings) }
    func play() { playCallCount += 1 }
    func pause() {}
    func stop() {}
    func seek(to seconds: TimeInterval) { elapsed = seconds }
    func finish() { onFinish?() }
}
```

把现有三个混响生命周期测试改用 `.panoramicSurround`、`.classicRock`，并新增以下断言：

```swift
func testLocalBackendAppliesNewEffectPresetWithoutReloadingTrack() async throws {
    // 沿用现有 testLocalBackendSwitchesToReverbPlayer... 的 root/store/player 构造方式。
    let effectPlayer = FakeAudioEffectPlayer()
    let backend = LocalPlaybackBackend(
        fileStore: store,
        player: player,
        notificationCenter: center,
        effectPlayer: effectPlayer
    )
    try backend.load(downloadedTrack(id: "song"), generation: generation)
    backend.play()
    try await waitUntil { player.currentItem != nil }

    backend.updateAudioEffect(.init(preset: .panoramicSurround, wetDryMix: 60))
    try await waitUntil { effectPlayer.playCallCount == 1 }
    backend.updateAudioEffect(.init(preset: .clearVocal, wetDryMix: 45))

    XCTAssertEqual(effectPlayer.loadedSettings.last?.preset, .panoramicSurround)
    XCTAssertEqual(effectPlayer.updatedSettings.last?.preset, .clearVocal)
}
```

实际测试必须展开现有测试中的 `root`、`DownloadFileStore`、音频文件、`AVPlayer`、`NotificationCenter` 和 `generation` 初始化，不新增只使用一次的 fixture 抽象。

- [ ] **Step 2: 运行 lifecycle 测试取得可信 RED**

```bash
set -o pipefail
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO \
  -only-testing:SimpleMusicTests/PlaybackBackendLifecycleTests \
  -only-testing:SimpleMusicTests/PlaybackCoordinatorTests \
  test CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/audio-effect-task2-red.log
```

预期：exit 65，只因 `AudioEffectAudioPlaying`、`effectPlayer` initializer 或新 profile 处理尚不存在而失败。

- [ ] **Step 3: 统一内部命名**

在生产和对应测试中做限定重命名：

```text
ReverbAudioPlaying          → AudioEffectAudioPlaying
SystemReverbAudioPlayer     → SystemAudioEffectPlayer
reverbPlayer                → effectPlayer
isReverbTransportActive     → isEffectTransportActive
switchToReverbPlayback      → switchToEffectPlayback
reverbDidFinish             → effectDidFinish
```

不要改公开 `AudioEffectSettings`、播放协调器或持久化接口。

- [ ] **Step 4: 建立 AVAudioEngine 组合链**

`SystemAudioEffectPlayer` 增加：

```swift
private let equalizer = AVAudioUnitEQ(numberOfBands: 4)
```

初始化 attach `playerNode`、`equalizer`、`reverb`；load 时连接：

```swift
engine.connect(playerNode, to: equalizer, format: file.processingFormat)
engine.connect(equalizer, to: reverb, format: file.processingFormat)
engine.connect(reverb, to: engine.mainMixerNode, format: nil)
```

重连前依次断开 player、EQ、reverb 输出，避免重复 load 残留旧连接。

- [ ] **Step 5: 把 profile 应用到 EQ 和混响**

`update(settings:)` 必须：

1. 调用 `settings.preset.resolvedProfile(intensity: settings.wetDryMix)`。
2. 先禁用全部 4 个 band。
3. 逐个设置 `filterType`、`frequency`、`bandwidth`、`gain`、`bypass = false`。
4. 将 `.lowShelf/.parametric/.highShelf` 映射到对应 `AVAudioUnitEQFilterType`。
5. 将 `AudioEffectReverbProfile` 的 7 个 case 逐一映射到同名 `AVAudioUnitReverbPreset`。
6. profile 无 reverb 时设 `reverb.wetDryMix = 0`；否则加载 preset 再写 profile 的 `wetDryMix`。

旧纯混响预设必须保持原厂 preset 和原始强度；新四种预设才使用各自最大 wet mix。

- [ ] **Step 6: 保持本地/系统边界并跑 GREEN**

确认 `LocalPlaybackBackend.updateAudioEffect` 仍只对 `.downloaded` lease 路径切换音效驱动；系统 backend 和 `PlaybackCoordinator` 的不可用状态不变。

重复 Step 2，预期两组测试全绿。然后：

```bash
git diff --check
git add SimpleMusic/Playback/LocalPlaybackBackend.swift \
  SimpleMusicTests/PlaybackBackendLifecycleTests.swift \
  SimpleMusicTests/PlaybackCoordinatorTests.swift
git commit -m "feat: 升级本地组合音效引擎"
```

---

### Task 3: 更新播放器 UI、三语言与播放模式颜色

**Files:**
- Modify: `SimpleMusic/UI/Player/PlayerViewController.swift`
- Modify: `SimpleMusic/en.lproj/Localizable.strings`
- Modify: `SimpleMusic/zh-Hans.lproj/Localizable.strings`
- Modify: `SimpleMusic/zh-Hant.lproj/Localizable.strings`
- Modify: `SimpleMusicTests/PlayerViewControllerTests.swift`
- Modify: `SimpleMusicTests/LocalizationTests.swift`

- [ ] **Step 1: 写四个预设名称和三种模式 tint 测试**

在 `PlayerViewControllerTests.swift` 使用现有音效弹窗/按钮访问 helper，增加：

复制现有 `testBottomToolbarPresentsAudioEffectsAndRoutesChanges` 的 snapshot、window、
toolbar 和 more 按钮构造，打开同一个 `AudioEffectsViewController`，再增加：

```swift
let navigation = try XCTUnwrap(sut.presentedViewController as? UINavigationController)
let effects = try XCTUnwrap(navigation.topViewController as? AudioEffectsViewController)
effects.loadViewIfNeeded()
let table = try XCTUnwrap(
    findView(identifier: "effects.presets", in: effects.view) as? UITableView
)
let titles = (0..<table.numberOfRows(inSection: 0)).compactMap {
    table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: $0, section: 0))
        .textLabel?.text
}
XCTAssertTrue(titles.contains(L10n.text("effects.preset.panoramic_surround")))
XCTAssertTrue(titles.contains(L10n.text("effects.preset.classic_rock")))
XCTAssertTrue(titles.contains(L10n.text("effects.preset.dynamic_electronic")))
XCTAssertTrue(titles.contains(L10n.text("effects.preset.clear_vocal")))

effects.selectPresetForTesting(.clearVocal)
XCTAssertEqual(updates.last, .init(preset: .clearVocal, wetDryMix: 25))
```

在现有 `testPlaybackModeButtonPrecedesPreviousAndRendersEveryMode` 中，取得
`player.playbackMode` 按钮后，在 list、repeatOne、shuffle 三个快照各自渲染完成时增加：

```swift
XCTAssertEqual(mode.tintColor, Theme.accent)
```

不要扩大 private 控件可见性。

在 `LocalizationTests.swift` 把四个 key 加入三语言必备 key 集合。

- [ ] **Step 2: 运行 UI/localization 测试取得可信 RED**

```bash
set -o pipefail
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO \
  -only-testing:SimpleMusicTests/PlayerViewControllerTests \
  -only-testing:SimpleMusicTests/LocalizationTests \
  test CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/audio-effect-task3-red.log
```

预期：四个 key/标题缺失、列表模式 tint 不同导致失败。

- [ ] **Step 3: 添加三语言文案**

每个语言文件新增相同 key：

```text
effects.preset.panoramic_surround
effects.preset.classic_rock
effects.preset.dynamic_electronic
effects.preset.clear_vocal
```

值分别为：

| Key | en | zh-Hans | zh-Hant |
|---|---|---|---|
| panoramic_surround | Panoramic Surround | 全景环绕 | 全景環繞 |
| classic_rock | Classic Rock | 摇滚经典 | 搖滾經典 |
| dynamic_electronic | Dynamic Electronic | 动感电音 | 動感電音 |
| clear_vocal | Clear Vocal | 清晰人声 | 清晰人聲 |

同时把 `effects.intensity` 改为 `Effect Intensity` / `音效强度` / `音效強度`；`effects.intensity_value` 的参数格式不变。

- [ ] **Step 4: 更新 preset key 映射并统一 tint**

在 `PlayerViewController.swift` 的 preset 本地化 switch 追加四个 case。播放模式颜色改为：

```swift
// 三种播放模式都处于可操作状态，仅通过图标区分语义，统一使用品牌强调色。
playbackModeButton.tintColor = Theme.accent
```

- [ ] **Step 5: 运行 GREEN 并只暂存本任务 hunk**

重复 Step 2，预期两组全绿。检查用户已有修改：

```bash
git diff -- SimpleMusic/UI/Player/PlayerViewController.swift
```

使用交互式暂存：

```bash
git add -p SimpleMusic/UI/Player/PlayerViewController.swift
```

对 `.caption1 → .title1` hunk 输入 `n`；只对新增预设映射、通用强度和 tint hunk 输入 `y`。再执行：

```bash
git add SimpleMusic/en.lproj/Localizable.strings \
  SimpleMusic/zh-Hans.lproj/Localizable.strings \
  SimpleMusic/zh-Hant.lproj/Localizable.strings \
  SimpleMusicTests/PlayerViewControllerTests.swift \
  SimpleMusicTests/LocalizationTests.swift
git diff --cached --check
git diff --cached --name-only
git commit -m "feat: 添加特色音效与统一模式颜色"
```

提交前确认 cached diff 不含 `.title1` hunk，不含 `xcuserdata`。

---

### Task 4: 全量验证和功能文档

**Files:**
- Modify: `docs/app-pages-and-features.md`

- [ ] **Step 1: 跑音效相关聚焦测试**

```bash
set -o pipefail
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO \
  -only-testing:SimpleMusicTests/SettingsStoreTests \
  -only-testing:SimpleMusicTests/PlaybackBackendLifecycleTests \
  -only-testing:SimpleMusicTests/PlaybackCoordinatorTests \
  -only-testing:SimpleMusicTests/PlayerViewControllerTests \
  -only-testing:SimpleMusicTests/LocalizationTests \
  test CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/audio-effect-focused-final.log
```

预期：exit 0、`** TEST SUCCEEDED **`、0 failed。

- [ ] **Step 2: 跑全量 XCTest**

```bash
set -o pipefail
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO test CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee /tmp/audio-effect-full-final.log
```

预期：exit 0、`** TEST SUCCEEDED **`、0 failed/skipped。

- [ ] **Step 3: 跑 Simulator 和 Device 编译**

```bash
set -o pipefail
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee /tmp/audio-effect-simulator-build.log

set -o pipefail
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee /tmp/audio-effect-device-build.log
```

预期：两次均 exit 0、`** BUILD SUCCEEDED **`；记录但不借机修改已有环境 warning。

- [ ] **Step 4: 更新功能说明**

在 `docs/app-pages-and-features.md` 播放页章节补充：

- 本地下载歌曲支持原混响与四个组合音效。
- 全景环绕是立体声拓宽模拟。
- 音效强度同时控制 EQ 与混响。
- 系统音乐不支持这些本地音效。
- 三种播放模式图标统一使用强调色。

- [ ] **Step 5: 最终范围审计和提交**

```bash
git diff --check
git status --short
git diff -- SimpleMusic/UI/Player/PlayerViewController.swift
git add docs/app-pages-and-features.md
git diff --cached --check
git commit -m "docs: 更新本地音效功能说明"
git status --short
```

最终允许保留的未提交内容只有用户原有的 `PlayerViewController.swift` `.title1` hunk 和 `xcuserdata`；不得把它们带入任何提交。
