# SimpleMusic 本地音乐播放器设计

日期：2026-08-14

## 目标

在现有 SimpleMusic 工程中实现原生 iPhone/iPad 本地音乐播放器“听见”。视觉与交互以 `ios-music-player-v2 (1).html` 和 `ipad-music-player.html` 为基准。

首版真实读取并播放系统音乐资料库，也可从音频直链下载歌曲到 App 私有目录后离线播放。播放器支持后台播放、锁屏与控制中心信息、耳机遥控。不需要账号，不上传音乐，不做云同步，也不解析音乐平台或普通网页链接。

## 技术基线

- Swift 5、UIKit、iOS 15.0 及以上。
- 支持 iPhone 和 iPad，全应用只支持竖屏。
- 使用 CocoaPods；首版仅引入 SnapKit 负责代码布局。
- 正式界面使用纯代码。保留 LaunchScreen storyboard；SceneDelegate 接管根控制器后移除 Main storyboard 入口。
- 播放、资料库、下载和持久化使用 MediaPlayer、AVFoundation、URLSession、Core Data 与 UserDefaults。

## 首版不包含

- 横屏界面、账号、云同步或服务端。
- 音乐平台、播放页或普通网页链接解析。
- 后台断点下载、歌词、均衡器、音频编辑和在线曲库。
- 恢复旧模板中的 Bugly、IQKeyboardManager、Toast、TBActionSheet 或 FBRetainCycleDetector。

## 架构

### AppCoordinator

创建根控制器，根据授权状态切换首次授权页和主界面，并集中管理资料库、搜索、播放页、设置和关于页面的导航。

### MusicLibraryService

通过 `MPMediaLibrary` 请求权限，通过 `MPMediaQuery` 读取歌曲、专辑、艺人和封面。权限被拒绝时返回明确状态，界面仍展示下载歌曲。

系统音乐条目不提取底层文件。受保护或云端歌曲交给 `MPMusicPlayerController`，其可用性和联网要求与系统音乐 App 保持一致。

### DownloadManager

使用 `URLSessionDownloadTask` 下载 HTTP/HTTPS 音频直链。下载前校验协议和扩展名，收到响应后校验 MIME 类型，只接受 MP3、M4A 和 WAV。

文件保存到 App 私有 Application Support 目录。文件名经过清理；同名文件使用唯一标识避免覆盖。禁止蜂窝网络下载时，通过 `URLSessionConfiguration.allowsCellularAccess` 执行。首版不承诺 App 被系统终止后的续传。

### LocalMusicStore

使用现有 Core Data 容器保存下载歌曲的标识、文件名、标题、艺人、专辑、时长、创建时间和最近播放时间。通过 AVAsset 读取文件元数据；缺失时使用文件名、“未知艺人”和“未知专辑”。蜂窝下载和下载后自动播放等设置存入 UserDefaults。

### PlaybackCoordinator

对界面暴露统一队列和统一播放状态。队列项包含稳定标识、来源、标题、艺人、专辑、封面、时长和可播放引用。

- 系统资料库歌曲由 `MPMusicPlayerController` 播放。
- App 下载歌曲由 `AVPlayer` 播放。
- 切换来源时先停止并解除观察旧后端，再启动新后端。
- 播放、暂停、进度跳转、上一首、下一首、播放全部和随机播放均由协调器执行。
- 队列到达末尾后停止，首版不默认循环。

### NowPlayingService

配置音频会话和后台音频，维护 `MPNowPlayingInfoCenter`，响应 `MPRemoteCommandCenter` 的播放、暂停、上一首、下一首和进度跳转。界面、锁屏、控制中心和耳机共享同一播放状态。

## 界面结构

### 首次授权

首次启动显示资料库授权说明。选择“允许访问”后请求系统权限；选择“暂不”也能进入主界面，但只显示下载歌曲，并持续提供授权提示。

### iPhone

- 底部为“资料库”和“搜索”两个 Tab。
- 资料库包含最近播放、歌曲/专辑/艺人/已下载入口、最近添加和迷你播放器。
- 歌曲页支持搜索、播放全部、随机播放和排序。
- 点击歌曲或迷你播放器进入全屏播放页。
- 下载使用底部面板；设置和关于使用标准导航。

### iPad

iPad 只支持竖屏，主界面使用左侧导航和中间内容双栏；正在播放从右侧以面板形式滑入，可关闭返回列表。不实现横屏固定三栏。

### 通用播放界面

展示封面、歌曲名、艺人和专辑、下载标识、播放进度、剩余时间、上一首、播放/暂停、下一首、系统音量、AirPlay 和当前队列。

设计稿中的收藏按钮只有在存在实际收藏数据模型和筛选入口时才启用；否则首版不展示，避免虚假成功状态。

### 设置与关于

设置包含音乐资料库权限、允许蜂窝网络下载、下载后自动播放和关于入口。关于页说明支持格式与本地隐私原则。

## 数据流

1. AppCoordinator 启动后读取音乐权限、本地下载索引和设置。
2. 资料库合并系统音乐与下载音乐，并保留来源信息。
3. 用户选歌后，页面把目标歌曲和当前列表交给 PlaybackCoordinator。
4. PlaybackCoordinator 选择播放后端，并把状态发布给迷你播放器、全屏播放器和 NowPlayingService。
5. 下载完成后，DownloadManager 移动文件，LocalMusicStore 写入元数据并刷新资料库；开启自动播放时创建新队列并播放。

## 下载与异常处理

下载面板包含输入、下载中、成功和失败四种状态。

- URL 非 HTTP/HTTPS、扩展名不支持或 MIME 类型不是音频时拒绝下载。
- 网络中断、空间不足、移动失败或元数据读取失败时显示明确错误，不写入不完整记录。
- 取消下载时删除临时文件并返回输入状态。
- 权限拒绝不阻止应用启动和本地下载歌曲播放。
- 系统歌曲不可播放或需要网络时保留队列，并允许跳到下一首。
- 本地文件损坏或丢失时排除出可播放队列，并提供移除记录操作。

## 视觉与无障碍

- 保持 HTML 中的浅灰背景、白色分组卡片、红色强调色、圆角和信息层级。
- 使用系统字体、SF Symbols、动态字体、安全区和原生控件，不模拟设备外框、状态栏或灵动岛。
- 控件点击区域至少 44×44 点。
- 支持 VoiceOver、动态字体和减少动态效果。
- 所有页面和弹层只按竖屏验证。

## 工程配置

iPhone 和 iPad 均只声明 `UIInterfaceOrientationPortrait`。开启 Audio 后台模式，并在 Info.plist 中提供音乐资料库用途说明。

工程层、Target 层和 Podfile 的最低版本全部统一为 iOS 15.0。依赖通过 `.xcworkspace` 构建。

## 测试与验收

新增 SimpleMusicTests XCTest Target，覆盖：

- URL 协议、扩展名和 MIME 类型校验。
- 同名下载文件的唯一命名。
- 队列的上一首、下一首、末尾停止和随机顺序。
- 系统音乐与本地音乐切换时的后端状态转换。
- Core Data 下载索引的写入、读取和删除。
- UserDefaults 设置持久化。

使用 iPhone/iPad 模拟器验证编译、竖屏布局、下载文件导入、本地播放和错误状态。系统音乐授权、受保护或云端歌曲、后台播放、锁屏/控制中心、AirPlay 和耳机遥控必须真机验证；模拟器编译成功不等同于真机验证完成。

## 完成标准

- iPhone/iPad 均能在竖屏完成授权、浏览、搜索、下载和播放。
- 系统歌曲和下载歌曲进入统一队列，跨来源切换不出现双重播放。
- 下载歌曲在重启后仍存在并可离线播放。
- 后台、锁屏/控制中心和耳机遥控更新同一播放状态。
- 下载限制、权限拒绝和文件错误都有明确、可恢复状态。
- CocoaPods、工程和测试统一以 iOS 15.0 为最低版本并通过构建。
