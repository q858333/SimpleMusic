# 下载队列验证报告

日期：2026-08-21

验证输入范围：`e27a196..e968742`

工作分支：`codex/download-queue`

## 结论

应用内下载队列的聚焦测试、全量 XCTest、generic iOS Simulator 构建和 generic iOS device 构建均通过。静态审计确认下载页面不持有或取消传输任务，生产环境只创建一个应用级 `DownloadQueue`，队列主动限制最多 3 个活动任务，`DownloadManager` 仍保留 3 permit 安全网；恢复流程先查询索引，再把受控叶子文件名交给 `DownloadFileStore` 清理。

本报告只证明模拟器自动化与无签名 generic 构建覆盖的行为。真机弱网、真实大文件传输、系统后台冻结时机仍属于发布前设备集成检查。

## 聚焦测试

以下命令均使用 `set -o pipefail`，命令 exit code 与 `xcresulttool get test-results summary` 的机器汇总一致。

### 下载领域

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO \
  -only-testing:SimpleMusicTests/DownloadQueueTests \
  -only-testing:SimpleMusicTests/DownloadManagerConcurrencyTests \
  -only-testing:SimpleMusicTests/DownloadFileStoreTests \
  -only-testing:SimpleMusicTests/LocalMusicStoreTests \
  test CODE_SIGNING_ALLOWED=NO
```

- exit code：0；`** TEST SUCCEEDED **`
- 机器汇总：85 passed，0 failed，0 skipped，0 expected failures
- xcresult：`/Users/db/Library/Developer/Xcode/DerivedData/SimpleMusic-ftixrzkordvhdifswddbiugcjmzw/Logs/Test/Test-SimpleMusic-2026.08.21_17-33-52-+0800.xcresult`
- 日志：`/tmp/download-queue-domain-final.log`

### 下载页面与应用接线

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO \
  -only-testing:SimpleMusicTests/DownloadAndSettingsFlowTests \
  -only-testing:SimpleMusicTests/AppCoordinatorTests \
  test CODE_SIGNING_ALLOWED=NO
```

- exit code：0；`** TEST SUCCEEDED **`
- 机器汇总：44 passed，0 failed，0 skipped，0 expected failures
- xcresult：`/Users/db/Library/Developer/Xcode/DerivedData/SimpleMusic-ftixrzkordvhdifswddbiugcjmzw/Logs/Test/Test-SimpleMusic-2026.08.21_17-34-13-+0800.xcresult`
- 日志：`/tmp/download-queue-ui-final.log`

### 本地化

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO \
  -only-testing:SimpleMusicTests/LocalizationTests \
  test CODE_SIGNING_ALLOWED=NO
```

- exit code：0；`** TEST SUCCEEDED **`
- 机器汇总：18 passed，0 failed，0 skipped，0 expected failures
- xcresult：`/Users/db/Library/Developer/Xcode/DerivedData/SimpleMusic-ftixrzkordvhdifswddbiugcjmzw/Logs/Test/Test-SimpleMusic-2026.08.21_17-34-29-+0800.xcresult`
- 日志：`/tmp/download-queue-localization-final.log`

## 全量测试

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -parallel-testing-enabled NO test CODE_SIGNING_ALLOWED=NO
```

- exit code：0；`** TEST SUCCEEDED **`
- `xcresulttool` 机器汇总：276 total，276 passed，0 failed，0 skipped，0 expected failures
- xcresult：`/Users/db/Library/Developer/Xcode/DerivedData/SimpleMusic-ftixrzkordvhdifswddbiugcjmzw/Logs/Test/Test-SimpleMusic-2026.08.21_17-34-50-+0800.xcresult`
- 日志：`/tmp/download-queue-full-final.log`

## 构建验证与警告分类

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO

xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

- generic iOS Simulator：exit code 0；`** BUILD SUCCEEDED **`；日志 `/tmp/download-queue-simulator-build.log`
- generic iOS device：exit code 0；`** BUILD SUCCEEDED **`；日志 `/tmp/download-queue-device-build.log`
- 本次下载队列、下载页面和应用接线 Swift 文件没有编译 warning；没有方向 validation 或资源缺失错误。
- 非本次改动 warning：IQKeyboardManager Pod 的弃用/隐式捕获警告、播放器既有 `showsRouteButton` 弃用警告、LaunchScreen 既有非 Dynamic Type 字体警告。
- 环境型 warning：当前 Metal toolchain Swift 搜索路径不存在；AppIntents 元数据因工程不依赖 AppIntents 而跳过。

## 行为与 testcase 对照

| 行为 | 直接覆盖的 testcase |
| --- | --- |
| 最多 3 个并发，第 4 个等待 | `DownloadQueueTests.testQueueStartsThreeAndWaitsFourthUntilFirstFinishes`；`DownloadManagerConcurrencyTests.testFourthDownloadStartsOnlyAfterOneOfThreeActiveDownloadsFinishes` |
| FIFO，包括同时间戳稳定顺序 | `DownloadQueueTests.testQueueStartsSameTimestampJobsInSubmissionOrderWithSingleSlot`；`DownloadManagerConcurrencyTests.testQueuedDownloadsStartInSubmissionOrder` |
| 各任务独立进度 | `DownloadQueueTests.testProgressForOneJobDoesNotChangeOtherJobs`；`DownloadAndSettingsFlowTests.testDownloadingRowExposesLocalizedProgressAndMinimumActionTarget` |
| 关闭/释放页面后继续下载 | `DownloadAndSettingsFlowTests.testClosingAndReleasingSheetDoesNotCancelActiveQueueJob` |
| 重开页面显示原任务与最新进度 | `DownloadAndSettingsFlowTests.testReopenedSheetShowsSameJobsAndLatestProgress` |
| 逐项取消且不影响其他任务 | `DownloadQueueTests.testFailureAndCancellationEachReleaseExactlyOneSlot`；`DownloadAndSettingsFlowTests.testRowActionsOnlyAffectMatchingJobID`；`DownloadManagerConcurrencyTests.testCancellingActiveDownloadReleasesPermitForQueuedFourth` |
| 单任务自动播放、多任务不抢占、播放只消费一次 | `DownloadQueueTests.testOnlySingleEligibleAttemptAutoPlaysAndManualPlayConsumesOnce`；`DownloadQueueTests.testQueuedSecondDoesNotAutoPlayAfterSingleSlotBecomesFree`；`DownloadQueueTests.testPendingRetryPrecedesLaterEnqueueAndOwnsOnlyAutoPlayEligibility` |
| 进程终止后的未完成记录恢复为 interrupted，且不自动发起网络请求 | `DownloadQueueTests.testLaunchMarksUnfinishedInterruptedWithoutStartingNetwork`；`DownloadQueueTests.testRecoveryErrorKeepsInterruptedRecordAndRetryReconcilesBeforeNetwork` |
| 索引优先的 reservation 恢复 | `DownloadQueueTests.testRecoveryKeepsIndexedFileAndCleansOnlyUnindexedControlledFile`；`DownloadQueueTests.testRecoveryRemovesIndexedRecordButKeepsInterruptedCleanedJob`；`LocalMusicStoreTests.testContainsDownloadedFileNameReturnsTrueOnlyForIndexedName` |
| traversal、符号链接、临时文件与类型替换安全清理 | `DownloadQueueTests.testRecoveryRejectsTraversalAndDoesNotDeleteExternalFile`；`DownloadQueueTests.testTemporaryCleanupRemovesOnlyOwnedTransferFiles`；`DownloadQueueTests.testTemporaryCleanupUnlinksOwnedSymlinkWithoutDeletingExternalTarget`；`DownloadQueueTests.testTemporaryCleanupRejectsDirectoryThatReplacesClassifiedFile`；`DownloadFileStoreTests.testFileURLRejectsEmptySeparatorsAndTraversal` |
| reservation 在提交前持久化，失败不写索引 | `DownloadManagerConcurrencyTests.testReservationObserverRunsBeforeCommitAndReceivesControlledLeafName`；`DownloadManagerConcurrencyTests.testReservationPersistenceFailureDiscardsReservationAndDoesNotInsertIndex` |
| iPhone/iPad 共用应用级队列 | `AppCoordinatorTests.testPhoneAndPadDownloadFactoriesUseEnvironmentSharedQueue` |
| 三语言 key、参数、本地化进度及无硬编码汉字 | `LocalizationTests.testDownloadQueueLocalizationsExposeCompleteSharedKeySet`；`LocalizationTests.testDownloadQueueProgressUsesLocalizedIntegerFormatAcrossLanguages`；`LocalizationTests.testLocalizableStringKeysMatchAcrossLanguages`；`LocalizationTests.testProductionSwiftHasNoUnlocalizedHanStringLiterals` |

## 静态所有权、安全与本地化审计

- `SimpleMusic/UI/Download` 中没有 owning transfer `Task`；唯一 `.cancel(id:)` 是任务行把稳定 UUID 转发给应用级队列。关闭按钮和 `presentationControllerDidDismiss` 只释放 Combine UI 订阅。
- 生产代码只在 `AppEnvironment` 构造一个 lazy `DownloadQueue` 和一个 `DownloadManager`；手机与 iPad 工厂共享该实例。
- `DownloadQueue.maximumActiveCount` 默认值为 3；`DownloadManager` 的 `DownloadPermitPool(limit: 3)` 保留防御性安全网。
- `DownloadRecoveryService.reconcile` 先调用 `LocalMusicStore.contains(fileName:)`；只在无索引时调用 `DownloadFileStore.removeFile(named:)`。后者拒绝空值、分隔符、`.`、`..` 和跨根路径，使用 `lstat`/`unlink` 删除叶子，不跟随符号链接，也不递归删除目录。
- en、zh-Hans、zh-Hant 的 `Localizable.strings` 各有 110 个 key，集合差异为 0；10 个 `download.queue.*` key 三语言齐全。
- `git diff --check` 无输出；开始验证时与写报告前工作区均无用户脏文件。

## 明确边界与发布前检查

- 当前传输使用普通 `URLSessionConfiguration.default`。下载页面关闭后，任务由应用级队列继续持有；应用进入后台后只在 iOS 允许的执行时间内继续，系统后台执行时间结束后传输可能暂停或冻结。
- 用户强制结束 App、系统终止进程或设备重启后不续传。下次启动只把未完成任务恢复为 `interrupted`，进度归零；用户手动重试会从 0 发起新请求。
- XCTest 使用受控 operation、临时文件和模拟器，不等价于真实网络与真机生命周期验证。发布前仍需在真机验证弱网切换、蜂窝/Wi-Fi 策略、真实大文件的进度与清理、前后台切换以及系统冻结/恢复时机。
- ledger 保留一项非阻塞审查注记：`DownloadManagerConcurrencyTests` 的 `onCommit` 测试 seam 名称实际对应元数据阶段。当前测试验证 reservation observer 位于该阶段之前，但最终审查仍需判断是否补强到真实 commit 邻接顺序。
