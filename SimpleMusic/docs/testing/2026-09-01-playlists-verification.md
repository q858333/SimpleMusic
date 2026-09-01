# 播放列表验证报告

日期：2026-09-01

验证输入范围：`3070c42`

工作分支：`codex/playlists-20260901`

## 结论

播放列表聚焦测试、完整 XCTest、通用 iOS Simulator 构建和通用 iOS device 构建均通过。本报告证明模拟器自动化测试和无签名 generic 构建结果；不等同于真机运行验证。

所有命令均在工作树的 iOS 工程目录 `SimpleMusic/` 中运行。

## 播放列表聚焦测试

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SimpleMusicTests/PlaylistStoreTests -only-testing:SimpleMusicTests/PlaylistViewModelTests -only-testing:SimpleMusicTests/LibraryViewModelTests -only-testing:SimpleMusicTests/LocalizationTests test CODE_SIGNING_ALLOWED=NO
```

- exit code：0；`** TEST SUCCEEDED **`
- XCResult 汇总：95 total，95 passed，0 failed，0 skipped，0 expected failures
- XCResult：`/Users/db/Library/Developer/Xcode/DerivedData/SimpleMusic-guxfsrskjptdbvfqpvftxrnfpbzq/Logs/Test/Test-SimpleMusic-2026.09.01_13-40-28-+0800.xcresult`

## 完整 XCTest

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO
```

- exit code：0；`** TEST SUCCEEDED **`
- XCResult 汇总：371 total，371 passed，0 failed，0 skipped，0 expected failures
- XCResult：`/Users/db/Library/Developer/Xcode/DerivedData/SimpleMusic-guxfsrskjptdbvfqpvftxrnfpbzq/Logs/Test/Test-SimpleMusic-2026.09.01_13-42-51-+0800.xcresult`

## 构建验证

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

- exit code：0；`** BUILD SUCCEEDED **`

```bash
xcodebuild -workspace SimpleMusic.xcworkspace -scheme SimpleMusic -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

- exit code：0；`** BUILD SUCCEEDED **`

## 环境 warning 与边界

- 首次在 worktree 外层目录运行聚焦命令时，因该目录不含 `SimpleMusic.xcworkspace` 而以 exit code 66 退出；工程实际位于 `SimpleMusic/` 子目录。切换至该目录后重跑，结果见上。
- Xcode 输出 `IDERunDestination: Supported platforms for the buildables in the current scheme is empty.`，但四项最终验证均成功。
- 两个 generic 构建均提示 Metal toolchain 的 Swift 搜索路径不存在；链接继续完成。
- 构建在项目未依赖 AppIntents 时跳过 metadata extraction；device 构建亦提示没有 AppShortcuts。`CODE_SIGNING_ALLOWED=NO` 导致 CopySwiftLibs 忽略 strip-bitcode。这些均未阻断构建。
- 变更文件：仅本报告 `docs/testing/2026-09-01-playlists-verification.md`。
