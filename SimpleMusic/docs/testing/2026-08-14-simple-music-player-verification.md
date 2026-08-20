# SimpleMusic 全量验证报告

- 验证日期：2026-08-19（Asia/Shanghai）
- 分支：`codex/simple-music-player-sdd`
- 验证代码 HEAD：`e4f8db14c715b40c8141406c5ede9abc60d802f9`（发布门禁提交 `979d8c2`），验证范围 `75de6db..e4f8db1`，共 40 个提交
- Xcode：26.3（17C529）
- macOS：26.2（25C56）
- 构建 SDK：iOS / iOS Simulator 26.2；最低部署版本 15.0
- 测试目标：iPhone 17 Pro，iOS 26.4（23E244），UDID `5B24F1F6-66D9-42AC-898A-819240E92D5C`
- 启动核查目标：iPhone 17 Pro、iPad (A16)，均为 iOS 26.4、竖屏

## 结论

最终修复后的 197 项自动化测试与两种通用 Debug 构建全部通过；发布产物包含有效的 app 自有隐私清单及已编译 AppIcon，设备构建不再出现 MainActor 或“必须支持全部方向”的 validation warning。此前 iPhone 与 iPad 的首次权限根页面启动核查仍有效；本轮没有重新声称完整人工模拟器或真机验收，真实权限、网络下载、实际音频、后台/锁屏/耳机/AirPlay 等仍按下表标记为待验证。

reviewer 的 7 项 Important 及最终复审的两处闭环已在 `979d8c2`、`81978ca` 与 `e4f8db1` 收敛：发布门禁、四类资料库 live 动作、共享权限刷新、保守的本地索引协调/安全删除，以及 Core Data/下载目录可恢复降级均有生产入口和自动化覆盖。构建只剩本机 Metal toolchain 搜索路径与项目未使用 AppIntents 的环境提示。

## 命令与原始证据

| 验证项 | 命令 | 退出码 | 结果与日志 |
| --- | --- | ---: | --- |
| 最终复审 focused 测试 | `xcodebuild ... <9 个 -only-testing>` | 0 | xcresult machine summary：`9/9` passed，0 failed；`Test-SimpleMusic-2026.08.19_14-02-02-+0800.xcresult`；覆盖 traversal、EACCES/EIO、AV throw、空文件及三类 live TrackList 行为 |
| Library + Local + Download 较宽回归 | `xcodebuild ... -only-testing:SimpleMusicTests/LibraryViewModelTests -only-testing:SimpleMusicTests/LocalMusicStoreTests -only-testing:SimpleMusicTests/DownloadFileStoreTests test` | 0 | xcresult machine summary：`67/67` passed，0 failed，0 skipped；`/private/tmp/simplemusic-final-review-wide-20260819-1403.xcresult` |
| 全量测试 | `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath /private/tmp/simplemusic-final-review-full-20260819-1405.xcresult test CODE_SIGNING_ALLOWED=NO` | 0 | xcresult machine summary：`197/197` passed，0 failed，0 skipped，`** TEST SUCCEEDED **`；同名前缀 `.log` |
| 空白检查 | `git diff --check` | 0 | 无输出 |
| 通用模拟器 Debug 构建 | `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` | 0 | `** BUILD SUCCEEDED **`；arm64 与 x86_64；`/private/tmp/simplemusic-final-review-sim-build-20260819-1406.log`；xcresult 同名前缀 |
| 通用 iOS device Debug 编译 | `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -configuration Debug -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO` | 0 | `** BUILD SUCCEEDED **`；arm64；`/private/tmp/simplemusic-final-review-device-build-20260819-1407.log`；xcresult 同名前缀。这里只是无签名设备编译，没有安装或运行到真机 |
| 发布产物审计 | `plutil -lint/-p`、`xcrun assetutil --info Assets.car`、`sips`、`git diff 80cdc... -- <4 exact paths>` | 0 | app 内 `PrivacyInfo.xcprivacy: OK`；UserDefaults `CA92.1`、FileTimestamp `C617.1`、不追踪、无收集数据；`Assets.car` 含 AppIcon 三种 rendition；三张源 PNG 均 1024×1024 且与批准 commit 精确一致 |
| iPhone 启动核查 | `simctl boot/install/launch/io screenshot`，iPhone 17 Pro iOS 26.4 | 0 | launch PID `56361`；临时原始证据 `/tmp/task12-iphone-root-final.png`，1206×2622，竖屏首次权限页。截图未随 commit 持久化，临时文件清理后不可复核 |
| iPad 启动核查 | `simctl boot/install/launch/io screenshot`，iPad (A16) iOS 26.4 | 0 | launch PID `57498`；临时原始证据 `/tmp/task12-ipad-root.png`，1640×2360，竖屏首次权限页。截图未随 commit 持久化，临时文件清理后不可复核 |

> **证据耐久性限制：** 两张截图只位于 `/tmp`，是本轮查看过的临时原始证据，没有随 commit 持久化；临时文件清理后，仓库只能复核报告中的 PID、尺寸和观察记录，不能复核截图像素内容。

补充工具边界：iOS 26.2 原始 iPhone 模拟器虽然能 boot，但一次 `simctl install` 超过 60 秒无输出，人工中断后 exit 130。改用此前任务报告中更稳定的 iOS 26.4 目标后，boot/install/launch/screenshot 全链路 exit 0。该环境现象没有通过源码改动规避。

最终修复验证中，第一次 sandbox 内 generic simulator build 因 CoreSimulator 连接失效而 exit 66，未进入可信产品构建；使用相同代码、相同 destination 在获准的 Xcode 环境重跑后 exit 0，证据采用上表 `1320` 日志与 xcresult，没有以重复并发构建掩盖结果。

## 本地删除授权与边界

用户在 final-fix wave 中明确授权：自动删除文件缺失、明确不可播放、空文件或符号链接/非普通文件对应的 Core Data 索引；用户确认主动删除时，仅 unlink `DownloadFileStore` 根内受控叶子并删除该记录。实现不会跟随 symlink，不删除目录外目标，不把系统歌曲当成本地删除；无效/越界索引名、EACCES/未知 open/fstat I/O、AVFoundation 读取错误与 staging 创建/复制等瞬时错误向上抛并保留索引。focused 9 项、较宽 67 项及 full 197 项均覆盖这些边界。

## 工程与约束审计

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| iOS 15 最低版本 | PASS | `Podfile`、app/test target build settings 与实际编译 triple 均为 15.0；构建产物 `MinimumOSVersion = 15.0` |
| CocoaPods / SnapKit | PASS | workspace 依赖 `Pods-SimpleMusic`；`Podfile.lock` 为 SnapKit 5.7.1；测试和两类构建均经过 Pods target |
| iPhone + iPad | PASS | `TARGETED_DEVICE_FAMILY = "1,2"`；两类根容器测试通过 |
| 仅竖屏 | PASS（当前兼容边界） | 源与构建产物的 iPhone/iPad orientations 都只有 `UIInterfaceOrientationPortrait`，且 `UIRequiresFullScreen = true`；device validation 的方向 warning 已消失。iPadOS 26 后续风险见 TN3192 deferred |
| Main storyboard 清零 | PASS | `SimpleMusic/Base.lproj/Main.storyboard` 不存在，plist/pbxproj 无 Main/scene storyboard 引用 |
| LaunchScreen 保留 | PASS | `SimpleMusic/Base.lproj/LaunchScreen.storyboard` 存在；构建产物 `UILaunchStoryboardName = LaunchScreen` |
| app 隐私清单 | PASS | `PrivacyInfo.xcprivacy` 已加入 app resources，源与 device app 均 `plutil` 有效；按 Apple TN3183/required reasons 声明 UserDefaults `CA92.1` 与 app-container 文件 metadata `C617.1`，并声明不追踪、无收集数据 |
| AppIcon | PASS | 只从用户批准 commit `80cdc3873f134d2ba03a94010a13365a43da799f` 恢复 `Contents.json` 与三张 `app-icon-record-*-1024.png`；精确路径 diff 为空，`sips` 为 1024×1024，device `Assets.car` 的 `assetutil` 输出含 primary/dark/tinted rendition |
| 四类资料库闭环 | PASS（自动化） | Songs=全部、Downloaded=本地、Albums/Artists=真实分组并可进入 live 子列表；生产父/子页订阅同一 ViewModel，删除、撤权、媒体新增后实时重筛/重分组；全部播放、随机播放、排序使用最新 tracks；Recently Played 静态承诺已移除，Recent Added 保留 |
| 权限/媒体库刷新 | PASS（自动化） | 授权完成、scene active、`MPMediaLibraryDidChange` 与下载完成统一调用共享 ViewModel `requestReload()`；generation 防陈旧结果，合并并发刷新，observer 释放时成对停止通知；iPhone/iPad 共用同一实例 |
| 本地文件协调与删除 | PASS（自动化） | fetch 只暴露安全根内、非 symlink、regular、非空且明确可播放的文件；只对白名单确定不可恢复状态清索引。主动删除须弹确认，仅 unlink 受控叶子并删对应记录；invalid filename、fileAccess errno、AV throw、越界文件、系统歌曲与瞬时 staging 故障均不误删 |
| 存储降级 | PASS（自动化） | persistent store 加载失败转内存模式并保留原 store、向 UI 暴露 warning；save 失败记录并发通知而非崩溃。下载根失败只禁用下载并显示可理解说明，不以临时目录伪装持久下载，系统资料库浏览/播放仍可用 |
| 最大 3 个并发下载 | PASS（自动化） | `DownloadPermitPool(limit: 3)`；并发上限测试通过 |
| 超额 FIFO | PASS（自动化） | waiter `append` + `removeFirst`；提交顺序测试、等待取消/活动取消测试通过 |
| 下载文件原子保护 | PASS（自动化） | reservation/commit/discard、同名并发、跨 store、单次消费、symlink/regular-file 边界测试通过 |
| Accessibility 直接回归 | PASS（自动化，限定范围） | 直接断言 MiniPlayer 播放/暂停 accessibility label、非触摸 slider `.valueChanged` seek，以及 iPad 播放面板 accessibility-modal 生命周期；生产代码还有关闭、下载、设置等 labels，但本套测试未逐项直接断言 |
| Dynamic Type 真实辅助字号布局 | PASS（自动化，限定范围） | About、MiniPlayer、TrackCell 有 Accessibility XXXL 真实布局/滚动/自适应高度断言 |
| 权限、下载、设置的文字与触控基础 | PASS（自动化，限定范围） | 权限页断言按钮 `adjustsFontForContentSizeCategory`、72pt 图标与 48pt 按钮；设置页断言可见 labels 的 adjustsFont；下载页断言 URL 键盘及 44pt 按钮。没有把三页称为 Accessibility XXXL 完整布局通过 |
| 减少动态效果 | PASS（自动化） | iPad 播放面板 reduce-motion 立即完成测试通过 |

## PASS / FAIL / DEFERRED 矩阵

### 自动化与只读启动核查

| 场景 | 状态 | 说明 |
| --- | --- | --- |
| 首次选择允许或暂不后只进入主界面一次 | PASS（自动化） | `AppCoordinatorTests` 覆盖授权返回任意状态与暂不路径 |
| 空资料库、权限不足与单来源失败状态 | PASS（自动化） | ViewModel/UI state 测试覆盖；未做手工点击 |
| 有效/无效下载输入、四态、取消和迟到事件 | PASS（自动化） | validator、manager、download sheet 测试覆盖；未访问真实网络 |
| 播放队列、本地/系统后端切换、进度、上一首/下一首 | PASS（自动化） | coordinator/backend/player controller 测试覆盖；未证明模拟器实际扬声器输出 |
| 搜索与设置持久化 | PASS（自动化） | 搜索过滤和 `SettingsStore` 跨实例持久化测试通过 |
| iPhone 竖屏首次权限根页启动 | PASS（启动核查）/ DEFERRED（证据耐久性） | simctl launch 有 PID，临时截图中未观察到启动崩溃；截图未随 commit 持久化，临时文件清理后不可复核 |
| iPad 竖屏首次权限根页启动 | PASS（启动核查）/ DEFERRED（证据耐久性） | simctl launch 有 PID，临时截图中未观察到启动崩溃；截图未随 commit 持久化，临时文件清理后不可复核 |
| iPad 授权后的 264pt 双栏与 324pt 播放面板 | PASS（自动化）/ DEFERRED（人工视觉） | containment、宽度、遮罩与面板测试通过；本次截图停留在首次权限页 |
| Accessibility 与减少动态效果 | PASS（自动化，限定范围）/ DEFERRED（人工辅助功能） | 直接覆盖播放/暂停 label、slider 非触摸 seek、iPad modal 生命周期及 reduce motion；其他 labels 只有生产配置证据，未逐项回归；未实际开启 VoiceOver 操作完整页面 |
| Dynamic Type | PASS（About/MiniPlayer/TrackCell 的 XXXL 自动化）/ DEFERRED（其余页面与人工视觉） | 权限/设置只覆盖 adjustsFont 或默认尺寸，下载只覆盖输入和触控基础；未证明这些页面在 XXXL 下完整布局通过 |
| 全部自动化检查 | PASS | 197 passed，0 failed，0 skipped |

本轮没有自动化 FAIL。以下模拟器交互仍待人工验收：实际拒绝系统权限弹窗后浏览主界面、空资料库手工浏览、真实有效/无效 URL 网络下载、本地文件实际音频输出、拖动与前后切换的听感、搜索/设置手工交互、授权后的 iPhone/iPad 全页面视觉、真实 VoiceOver 焦点顺序与朗读、辅助字号以及减少动态效果。

### 真机清单

| 真机场景 | 状态 |
| --- | --- |
| 系统 Music Library 授权弹窗与拒绝/允许路径 | DEFERRED — 待真机验证 |
| 系统歌曲读取与实际播放 | DEFERRED — 待真机验证 |
| 受保护或云端歌曲边界 | DEFERRED — 待真机验证 |
| 系统歌曲与下载歌曲跨来源切换 | DEFERRED — 待真机验证 |
| 后台持续播放 | DEFERRED — 待真机验证 |
| 锁屏/控制中心元数据与进度 | DEFERRED — 待真机验证 |
| 耳机播放/暂停/上一首/下一首 | DEFERRED — 待真机验证 |
| AirPlay 设备选择与切换 | DEFERRED — 待真机验证 |
| 禁止蜂窝网络时不使用蜂窝下载 | DEFERRED — 待真机验证 |

## Warnings

- 原 `AppCoordinator` 默认工厂 MainActor warning 已通过显式 `@MainActor` 契约消除；最终 simulator/device 日志均无该 warning。
- 原 device orientation validation warning 已通过 `UIRequiresFullScreen = true` 消除；这是用户明确 portrait-only 下针对现有部署范围的兼容修复，不代表已完成 iPad 可变窗口迁移。
- linker：本机可选 Metal toolchain 下的 Swift library search path 不存在；本轮链接仍成功。
- AppIntents：项目未依赖 AppIntents，metadata processor 明确跳过提取。
- Xcode 环境在首次 sandbox generic simulator 尝试中失去 CoreSimulator 连接；获准重跑及最终复审 simulator/device build 均进入完整依赖图并 exit 0，197 项 xcresult machine summary 也为 Passed。
- 两张 simulator 截图只保存在 `/tmp`，是临时原始证据，未随 commit 持久化；文件清理后无法从仓库复核其像素内容。

## Ledger 中保留的 deferred minors

- Task 1：project scope 的 `ENABLE_USER_SCRIPT_SANDBOXING = NO`，后续决定是否仅对 app target 收紧。
- Task 4：本机 Metal/AppIntents/IDE activity-log warning；`TestEventProbe` 在 deadline 极窄边界可能报告 synthetic cancellation，但无 task leak。
- Task 6：playback staging 创建忽略 destination close 失败；`PlaybackFileLease` 删除失败后先标 released，无法重试清理。
- Task 8：test target 手写 `$(BUILT_PRODUCTS_DIR)/SnapKit`，没有使用 CocoaPods 管理的 `inherit! :search_paths`；保留干净测试日志的期望。
- Task 9：IDE activity-log、Metal 与 AppIntents 环境 warning。
- Task 10：accessibility focus notification 的参数没有直接回归测试；没有为此新增生产 seam。
- Task 11：点击“重新输入”回到 URL 输入态后不自动恢复键盘焦点。
- Final fix：Apple [TN3192](https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key) 说明 `UIRequiresFullScreen` 兼容模式从 iPadOS 26 起 deprecated，并会在未来版本被忽略。真正支持可变窗口、全部方向与动态 scene resize 是后续产品迁移；本轮不违反用户明确的 portrait-only 决策。

以上 minor 与未来迁移项不属于本轮 7 个 Important，未扩展功能范围。隐私声明依据 Apple [TN3183](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest) 与 [required reason values](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons)。

## 工作树边界

代码提交 `e4f8db1` 后，受控仓库没有源码未提交改动；报告提交后的最终检查目标是唯一既有未跟踪项 `?? ../sdd-scripts/`。final-fix wave 不读取其内容、不修改、不暂存、不提交该目录。

## 本地化三语言验证（2026-08-20）

- 分支：`codex/simplemusic-localization`；验证基线 HEAD：`80febe4d0d23005a551664ed1aa0e4f13f25d103`。
- 环境：Xcode 26.3（17C529）、macOS 26.2（25C56）、iOS Simulator 26.4（23E244）。
- 语言约束：系统跟随，`en` 为 development/fallback，仅包含 `en` / `zh-Hans` / `zh-Hant`，繁中按台湾措辞。

### Production Swift 用户文案审计

`LocalizationTests.testProductionSwiftHasNoUnlocalizedHanStringLiterals` 递归读取 40 个 production Swift 文件，对含 Han Unicode scalar 的字符串 literal 输出 `file:line` 与原 literal。允许规则只匹配 literal 紧邻的调用上下文，没有整文件白名单：6 个 `NSLog`、19 个 `fatalError`、1 个 `preconditionFailure`。最终审计命令 exit 0，`LocalizationTests` 11/11 passed，真实 production 用户可见遗漏为 0；证据为 `/private/tmp/simplemusic-localization-audit-green.log` 与同名 `.xcresult`。

首轮审计曾把 `TrackCell.swift:98` 的 `"\\(track.artist) · \\(track.album)"` 误报为 Han literal，原因是 Foundation 便捷 regular-expression search 对 `\p{Han}` 的解析不符合预期；改为显式 Unicode scalar 范围后 GREEN，未改 production。首轮 `zh-Hans` focused 另暴露两个测试语言绑定错误：主 bundle 正确返回中文时旧测试仍固定期待英文，以及在中文 locale 下强行混用英文 bundle 做复数选择。测试改为校验当前 app language 的 main bundle 输出后三语言通过，不属于 production 遗漏。

### 测试与构建证据

| 验证项 | 命令摘要 | 退出码 | 机器汇总 / 产物 |
| --- | --- | ---: | --- |
| en focused | `xcodebuild ... -testLanguage en <5 个 only-testing> test` | 0 | 115 passed，0 failed，0 skipped；`/private/tmp/simplemusic-localization-focused-v2-en.{log,xcresult}` |
| zh-Hans focused | `xcodebuild ... -testLanguage zh-Hans <5 个 only-testing> test` | 0 | 115 passed，0 failed，0 skipped；`/private/tmp/simplemusic-localization-focused-v2-zh-Hans.{log,xcresult}` |
| zh-Hant focused | `xcodebuild ... -testLanguage zh-Hant <5 个 only-testing> test` | 0 | 115 passed，0 failed，0 skipped；`/private/tmp/simplemusic-localization-focused-v2-zh-Hant.{log,xcresult}` |
| full | `xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' test` | 0 | 231 passed，0 failed，0 skipped；`/private/tmp/simplemusic-localization-full.{log,xcresult}` |
| generic simulator build | `xcodebuild ... -destination 'generic/platform=iOS Simulator' build` | 0 | `** BUILD SUCCEEDED **`；`/private/tmp/simplemusic-localization-sim-build.{log,xcresult}` |
| generic device build | `xcodebuild ... -destination 'generic/platform=iOS' build` | 0 | `** BUILD SUCCEEDED **`；无签名编译，未安装到真机；`/private/tmp/simplemusic-localization-device-build.{log,xcresult}` |
| 独立 DerivedData | `xcodebuild ... -derivedDataPath /private/tmp/simplemusic-localization-dd build` | 0 | `** BUILD SUCCEEDED **`；app 路径见下 |

focused 覆盖 `LocalizationTests`、`AppCoordinatorTests`、`LibraryViewModelTests`、`PlayerViewControllerTests`、`DownloadAndSettingsFlowTests`，用自动化检查权限页、资料库/搜索、播放器、下载、设置与关于页的文案和主要 UI 契约。

### App bundle 资源审计

产物：`/private/tmp/simplemusic-localization-dd/Build/Products/Debug-iphonesimulator/SimpleMusic.app`。共找到 9 个编译资源文件；三语言的 `Localizable.strings`、`Localizable.stringsdict`、`InfoPlist.strings` 均为 Apple binary property list。

| 语言 | Localizable keys | stringsdict 顶层 keys | InfoPlist keys | display name | Music Library 权限说明 |
| --- | ---: | ---: | ---: | --- | --- |
| en | 99 | 1 | 2 | DiskTone | `DiskTone uses your music library to browse and play music on this device.` |
| zh-Hans | 99 | 1 | 2 | 听见 | `“听见”使用你的音乐资料库，以浏览并播放此设备上的音乐。` |
| zh-Hant | 99 | 1 | 2 | 聽見 | `「聽見」會使用你的音樂資料庫，以瀏覽並播放此裝置上的音樂。` |

构建产物 `Info.plist` 的 `CFBundleDevelopmentRegion = en`、`CFBundleIdentifier = DB.SimpleMusic`；未发现缺少语言、key 数不一致、格式参数不一致或 InfoPlist 缺项。

### iPhone / iPad 三语言启动与截图

设备清单未漂移：iPhone 17 Pro Max iOS 26.4 `6B1893C7-7A88-4EF0-A804-35BA9A1988B1`；iPad (A16) iOS 26.4 `D89CD6CE-158A-4218-9BA4-8A25D6D26C45`。两台均安装上述同一 app，六次 `simctl launch --terminate-running-process ... -AppleLanguages (...)` 均返回 PID，未观察到启动崩溃。

| 设备 / 语言 | 截图路径 | 像素 | 启动可见证据 |
| --- | --- | ---: | --- |
| iPhone / en | `/private/tmp/simplemusic-localization-iphone-en.png` | 1320×2868 | Library 主页英文，无 key/明显截断 |
| iPhone / zh-Hans | `/private/tmp/simplemusic-localization-iphone-zh-Hans.png` | 1320×2868 | 资料库主页简中，无 key/明显截断 |
| iPhone / zh-Hant | `/private/tmp/simplemusic-localization-iphone-zh-Hant.png` | 1320×2868 | 資料庫主頁繁中，无 key/明顯截斷 |
| iPad / en | `/private/tmp/simplemusic-localization-ipad-en.png` | 1640×2360 | app 已英文启动；被系统 Apple Music 权限弹窗遮挡 |
| iPad / zh-Hans | `/private/tmp/simplemusic-localization-ipad-zh-Hans.png` | 1640×2360 | app 已简中启动；被系统 Apple Music 权限弹窗遮挡 |
| iPad / zh-Hant | `/private/tmp/simplemusic-localization-ipad-zh-Hant.png` | 1640×2360 | app 已繁中启动；被系统 Apple Music 权限弹窗遮挡 |

iPhone 三张只能证明启动后资料库根页的主要文案；iPad 三张只能证明 app 启动和弹窗内 app permission copy，不能证明关闭弹窗后的 iPad 主页。搜索、播放器、下载、设置、关于页由上述三语 focused 自动化覆盖，本轮没有伪称完成六个页面的人工点击验收。

### Warnings 与 deferred

- 三类构建中 app 自有 Swift warning 均为 0。全新 generic simulator / device 构建分别重新编译 Pods，因此记录 IQKeyboardManager 既有 deprecated/implicit-retain warning（simulator 44、device 22）；还有 Metal toolchain Swift search path warning（simulator 6、device 3）和项目未使用 AppIntents 的 metadata skip（各1）。它们不是本地化产品失败。
- 测试运行期还有模拟器的 DVT device metadata、CoreUI theme、未授权 `MPMediaLibrary`、MediaRemote AVF、CA launch metric 与部分 unit-test appearance-transition 日志；xcresult 仍均为 0 failed / 0 skipped。
- iPad 系统 Apple Music 弹窗的按钮语言由模拟器系统中文环境控制，不随 app-only `-AppleLanguages` 参数切换；真机三语系统按钮、权限时序和真实 Music Library 行为全部 DEFERRED，发布前必须在真机复核。
- Task 7 reviewer 保留的 `@unknown default` minor 仍 deferred：当前 closed enum 无法构造未知 case，本轮不为此新增 production seam。
- `/private/tmp` 日志、xcresult 和六张截图均为本机临时证据，不随 git commit 持久化；文件被系统清理后不能从仓库复核像素内容。
