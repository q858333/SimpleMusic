# SimpleMusic 全量验证报告

- 验证日期：2026-08-19（Asia/Shanghai）
- 分支：`codex/simple-music-player-sdd`
- 验证范围记录：`75de6db..1115ea3`，共 34 个提交
- Xcode：26.3（17C529）
- macOS：26.2（25C56）
- 构建 SDK：iOS / iOS Simulator 26.2；最低部署版本 15.0
- 测试目标：iPhone 17 Pro，iOS 26.4（23E244），UDID `5B24F1F6-66D9-42AC-898A-819240E92D5C`
- 启动核查目标：iPhone 17 Pro、iPad (A16)，均为 iOS 26.4、竖屏

## 结论

自动化测试与两种通用 Debug 构建通过；iPhone 与 iPad 的首次权限根页面均能安装、启动和截图，未观察到启动崩溃。该结论不等同于完整人工模拟器验收，也不等同于真机运行：真实权限、网络下载、实际音频、后台/锁屏/耳机/AirPlay 等仍按下表标记为待验证。

构建有已知 warning，尤其包括 `AppCoordinator.swift` 两个默认控制器工厂的 MainActor 隔离 warning，以及真机通用编译的竖屏/full-screen validation warning。本任务没有失败检查指向需立即修改的 scope defect，因此只记录，不扩大源码修改范围。

## 命令与原始证据

| 验证项 | 命令 | 退出码 | 结果与日志 |
| --- | --- | ---: | --- |
| 全量测试 | `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO` | 0 | `163/163` test case passed，0 failed，`** TEST SUCCEEDED **`；`/tmp/task12-full-test.log`；xcresult：`/Users/db/Library/Developer/Xcode/DerivedData/SimpleMusic-cotnpdeswyoynecznqacbatfihye/Logs/Test/Test-SimpleMusic-2026.08.19_10-30-16-+0800.xcresult` |
| 空白检查 | `git diff --check` | 0 | 无输出 |
| 通用模拟器 Debug 构建 | `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` | 0 | `** BUILD SUCCEEDED **`；arm64 与 x86_64；`/tmp/task12-generic-simulator-build.log` |
| 通用 iOS device Debug 编译 | `xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -configuration Debug -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO` | 0 | `** BUILD SUCCEEDED **`；arm64；`/tmp/task12-generic-device-build.log`。这里只是无签名设备编译，没有安装或运行到真机 |
| iPhone 启动核查 | `simctl boot/install/launch/io screenshot`，iPhone 17 Pro iOS 26.4 | 0 | launch PID `56361`；临时原始证据 `/tmp/task12-iphone-root-final.png`，1206×2622，竖屏首次权限页。截图未随 commit 持久化，临时文件清理后不可复核 |
| iPad 启动核查 | `simctl boot/install/launch/io screenshot`，iPad (A16) iOS 26.4 | 0 | launch PID `57498`；临时原始证据 `/tmp/task12-ipad-root.png`，1640×2360，竖屏首次权限页。截图未随 commit 持久化，临时文件清理后不可复核 |

> **证据耐久性限制：** 两张截图只位于 `/tmp`，是本轮查看过的临时原始证据，没有随 commit 持久化；临时文件清理后，仓库只能复核报告中的 PID、尺寸和观察记录，不能复核截图像素内容。

补充工具边界：iOS 26.2 原始 iPhone 模拟器虽然能 boot，但一次 `simctl install` 超过 60 秒无输出，人工中断后 exit 130。改用此前任务报告中更稳定的 iOS 26.4 目标后，boot/install/launch/screenshot 全链路 exit 0。该环境现象没有通过源码改动规避。

## 工程与约束审计

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| iOS 15 最低版本 | PASS | `Podfile`、app/test target build settings 与实际编译 triple 均为 15.0；构建产物 `MinimumOSVersion = 15.0` |
| CocoaPods / SnapKit | PASS | workspace 依赖 `Pods-SimpleMusic`；`Podfile.lock` 为 SnapKit 5.7.1；测试和两类构建均经过 Pods target |
| iPhone + iPad | PASS | `TARGETED_DEVICE_FAMILY = "1,2"`；两类根容器测试通过 |
| 仅竖屏 | PASS（带 warning） | 源与构建产物的 iPhone/iPad orientations 都只有 `UIInterfaceOrientationPortrait`；自动化配置测试通过；device build 另见 warning 清单 |
| Main storyboard 清零 | PASS | `SimpleMusic/Base.lproj/Main.storyboard` 不存在，plist/pbxproj 无 Main/scene storyboard 引用 |
| LaunchScreen 保留 | PASS | `SimpleMusic/Base.lproj/LaunchScreen.storyboard` 存在；构建产物 `UILaunchStoryboardName = LaunchScreen` |
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
| 全部自动化检查 | PASS | 163 passed，0 failed，0 skipped |

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

- `SimpleMusic/App/AppCoordinator.swift:85-86`：默认 `UIViewController()` 工厂在同步非隔离上下文调用 MainActor initializer。通用 simulator/device Debug 构建按架构或构建变体重复输出。
- device validation：`All interface orientations must be supported unless the app requires full screen.` 当前产品约束要求 iPhone/iPad 都只验证竖屏；是否补充 full-screen 配置应在后续工程配置任务中明确裁决。
- linker：本机可选 Metal toolchain 下的 Swift library search path 不存在；本轮链接仍成功。
- AppIntents：项目未依赖 AppIntents，metadata processor 明确跳过提取。
- Xcode 环境：DVTDeviceOperation 报告空 build number；全量测试结束有 IDEActivityLogSectionRecorder 停止后写入的内部告警。163 项结果及退出码不受影响。
- 三个日志都出现 `IDERunDestination: Supported platforms for the buildables in the current scheme is empty.`；这是 Xcode 环境诊断，指定测试与两类 build 均实际进入目标依赖图并 exit 0。
- 两张 simulator 截图只保存在 `/tmp`，是临时原始证据，未随 commit 持久化；文件清理后无法从仓库复核其像素内容。

## Ledger 中保留的 deferred minors

- Task 1：project scope 的 `ENABLE_USER_SCRIPT_SANDBOXING = NO`，后续决定是否仅对 app target 收紧。
- Task 4：本机 Metal/AppIntents/IDE activity-log warning；`TestEventProbe` 在 deadline 极窄边界可能报告 synthetic cancellation，但无 task leak。
- Task 6：playback staging 创建忽略 destination close 失败；`PlaybackFileLease` 删除失败后先标 released，无法重试清理。
- Task 8：test target 手写 `$(BUILT_PRODUCTS_DIR)/SnapKit`，没有使用 CocoaPods 管理的 `inherit! :search_paths`；保留干净测试日志的期望。
- Task 9：IDE activity-log、Metal 与 AppIntents 环境 warning。
- Task 10：accessibility focus notification 的参数没有直接回归测试；没有为此新增生产 seam。
- Task 11：点击“重新输入”回到 URL 输入态后不自动恢复键盘焦点。

以上 minor 与本轮新观察到的 warning 均未在 Task 12 无失败检查的情况下扩修。

## 工作树边界

报告写入前与最终检查时，受控仓库没有源码未提交改动；唯一既有未跟踪项是 `?? ../sdd-scripts/`。Task 12 不读取其内容、不修改、不暂存、不提交该目录。
