# SimpleMusic 应用内下载队列设计

日期：2026-08-21

## 目标

把当前由 `DownloadSheetViewController` 单独持有的一次性下载，改为由应用环境持有的应用内下载队列。

用户可以连续提交多个音频直链；应用同时最多下载 3 个，其余任务按提交顺序等待。关闭、下拉收起或重新打开下载页面都不会取消任务，页面重新出现后继续展示同一批任务及实时进度。用户可以单独取消、重试或删除任务记录。

本方案采用用户确认的“应用内后台队列”方案：关闭下载页面后继续下载；应用进入后台时在 iOS 允许的执行时间内继续传输。用户强制结束应用、系统终止进程或设备重启后，未完成任务不会继续传输，下次启动时显示为“已中断”，由用户手动从 0 重新下载。

## 非目标

- 不改用系统后台 `URLSessionConfiguration.background`，因此不承诺应用被终止后继续传输或断点续传。
- 不增加账号、云端同步、跨设备同步或远程下载服务。
- 不解析网页、播放列表或流媒体地址，仍只接受现有下载校验器支持的音频直链。
- 不突破现有最多 3 个并发下载的产品限制。
- 不自动重试失败或已中断任务，避免在蜂窝网络、失效链接或存储不足时反复消耗资源。
- 不为下载记录增加历史归档或自动过期策略；记录只由用户明确删除。

## 现状与问题

当前 `DownloadSheetViewController` 自己持有一个 `Task`，并通过 `guard downloadTask == nil` 限制页面只能处理一个任务。关闭按钮、交互式下拉和控制器释放都会取消这个任务。虽然 `DownloadManager` 已有最多 3 个 permit，但单任务页面无法利用该能力，也无法在页面关闭后继续展示或管理传输。

需要把任务生命周期从页面移到应用级对象中，并把“队列状态”和“传输实现”分开：

- `DownloadQueue` 负责任务、排队、并发、持久化、重试和 UI 可观察状态。
- `DownloadManager` 继续负责单个任务的网络传输、校验、文件提交、元数据读取、索引写入和失败回滚。
- `DownloadSheetViewController` 只负责提交 URL、渲染任务列表和转发用户操作。

## 总体架构

```text
AppEnvironment
  ├─ DownloadManager          单任务下载事务
  ├─ DownloadQueueStore       JSON 任务账本
  └─ DownloadQueue            应用级队列，最多启动 3 个 Task
        ├─ queued jobs
        ├─ active Task handles
        └─ publisher/current snapshot
                 │
                 ▼
       DownloadSheetViewController
       输入框 + 下载任务列表
```

`AppEnvironment` 只创建一个 `DownloadQueue`。iPhone 和 iPad 的下载入口都注入这个相同实例，禁止页面自己创建 `DownloadManager`、任务账本或第二个队列。

## 数据模型

### DownloadJob

任务使用稳定的 `UUID` 标识，并保存以下字段：

- `id`：任务标识。
- `sourceURL`：用户提交的原始音频直链。
- `displayName`：由 URL 文件名生成、供列表展示的名称。
- `state`：当前状态。
- `progress`：`0...1`；重试时重置为 `0`。
- `createdAt`：提交时间，用于稳定 FIFO 排序。
- `failureReason`：失败时的本地化错误类别，不持久化已经翻译的文字。
- `track`：仅当前进程中成功后保留的 `MusicTrack`，供“立即播放”使用。
- `reservedFileName`：单任务事务已经预留的受控文件名，用于进程终止后的安全恢复。

### 状态

```text
queued       等待并发槽位
downloading  正在传输或提交
success      已写入本地资料库
failure      本次尝试失败，可重试
cancelled    用户取消，可重试或删除记录
interrupted  上次进程结束时未完成，可从 0 重试
```

状态转换：

```text
提交 ──> queued ──取得槽位──> downloading ──> success
                      │               ├──────> failure
用户取消 <────────────┴───────────────┘

queued/downloading ──进程终止并再次启动──> interrupted
failure/cancelled/interrupted ──重试──> queued
终态 ──用户删除记录──> 从队列移除
```

`success` 是不可被迟到进度、取消回调或失败回调覆盖的终态。每次尝试使用独立 generation；取消或重试先推进 generation，再处理旧 `Task`，旧回调必须被忽略。

## DownloadQueue 职责与接口

`DownloadQueue` 为 `@MainActor` 应用级对象，通过 Combine 发布不可变的 `[DownloadJob]` 快照。建议接口：

```swift
@MainActor
final class DownloadQueue {
    var jobsPublisher: AnyPublisher<[DownloadJob], Never> { get }
    var jobs: [DownloadJob] { get }

    @discardableResult
    func enqueue(_ url: URL) throws -> UUID
    func cancel(id: UUID)
    func retry(id: UUID)
    func remove(id: UUID)
}
```

队列自己维护 `activeTasks: [UUID: Task<Void, Never>]`，并在每次提交、完成、取消或重试后调用 `scheduleIfNeeded()`：

1. 计算空闲槽位，确保活动数不超过 3。
2. 按 `createdAt` 和稳定插入顺序从 `queued` 中取任务。
3. 先把任务标记为 `downloading` 并持久化，再创建传输 `Task`。
4. 每个活动任务结束后释放槽位，并立即调度下一项。

并发门禁由 `DownloadQueue` 主动控制，使 UI 能准确区分“等待中”和“下载中”。`DownloadManager` 现有的 3 permit 限制保留为防御性安全网，但正常路径不应在 Manager 内再次排队。

若为避免两层排队而新增内部入口，`DownloadManager.download` 的现有公开行为和并发测试保持兼容；队列使用一个明确的“已取得队列槽位”单任务入口，不能通过把限制改成无限来削弱现有保护。

## 持久化与终止恢复

新增 `DownloadQueueStore`，把可恢复字段编码为 JSON，写入 Application Support 下的应用专属文件。写入使用原子替换，测试可注入临时 URL。运行中的 `Task`、闭包、`MusicTrack` 实例和已翻译文本不进入 JSON。

每次状态变化都立即保存，至少包括：

- 新任务入队。
- 开始下载及进度变化；进度持久化做节流，避免每个网络回调都写磁盘。
- 预留文件名产生。
- 失败、取消、成功或用户删除。

启动恢复规则：

1. 读取任务账本；账本不存在时使用空队列。
2. JSON 损坏时保留文件并记录诊断，使用空内存队列，不让应用崩溃。
3. 对上次的 `queued` 或 `downloading` 任务做恢复核对。
4. 若 `reservedFileName` 已存在于本地音乐索引，说明歌曲事务已完成：保留歌曲，从任务账本移除，不误删已入库文件。
5. 若没有对应索引，只通过 `DownloadFileStore` 的受控文件名 API 清理该任务的 reservation/文件；绝不跟随符号链接，也不删除下载根目录之外的路径。
6. 将未完成记录改为 `interrupted`，进度重置为 `0`，等待用户手动重试。
7. `failure`、`cancelled` 和 `interrupted` 记录保留；成功记录不跨进程保留，成功歌曲由资料库承载。

上述恢复避免把“任务记录持久化”误解为断点续传：重试始终创建新的网络请求并从 0 开始。

## 单任务事务与恢复标记

为让队列能安全恢复，`DownloadManager` 在预留目标文件后、提交文件前，通过同步的内部阶段回调把 `reservedFileName` 告诉队列。队列必须先原子保存这个文件名，Manager 才继续提交。

任务完成的顺序为：

1. 网络临时文件下载完成。
2. 校验 URL、响应和音频。
3. 预留受控目标文件。
4. 队列持久化 `reservedFileName`。
5. 提交文件、读取元数据、写入 Core Data 索引。
6. 队列收到 `MusicTrack`，发布成功状态并刷新共享资料库。
7. 队列从持久账本移除成功记录。

恢复时先查询索引再清文件，覆盖“已写索引但进程尚未来得及清任务账本”的窗口。现有文件 reservation、取消检查和回滚规则继续由 `DownloadManager` 负责。

## 页面与交互

下载页面改为一个持续可用的表单和任务列表：

- 顶部保留 URL 输入框、说明和“添加下载”按钮。
- 提交有效 URL 后立即清空输入框并生成一条任务，不切换成独占的全页状态。
- 列表按 `createdAt` 倒序展示，最新提交在最上方；实际调度仍按正序 FIFO。同一实现必须在 iPhone 和 iPad 共用。
- `queued` 显示“等待中”。
- `downloading` 显示任务级进度条、百分比和“取消”。
- `failure` 显示可理解的错误、重试和删除。
- `cancelled`、`interrupted` 显示对应状态、重试和删除。
- `success` 显示歌曲名、“立即播放”和删除任务记录；删除成功任务记录不删除已经入库的歌曲。
- 关闭按钮和交互式下拉只关闭页面，不改变任何任务状态。
- 取消必须由具体任务行的“取消”按钮显式触发，并仅取消该任务。

任务行使用 Dynamic Type，按钮触控区域至少 44pt，状态和进度提供 VoiceOver 文本。所有新增文案补齐英文、简体中文和繁体中文；英文继续作为默认回退。

## 成功后的资料库与播放

每个成功任务都调用共享 `LibraryViewModel.requestReload()`，因此关闭下载页面后资料库仍会更新。

多个任务完成时不自动抢占当前播放。自动播放规则按用户已确认的保守语义处理：

- 提交某任务时，如果队列中没有其他 `queued` 或 `downloading` 任务，则该任务记录本次尝试是否允许自动播放。
- 只有这个单独任务成功，并且 `SettingsStore.autoPlayAfterDownload` 在提交时为开启，才自动播放一次。
- 一旦提交时已经存在其他未完成任务，该任务成功后只更新列表和资料库，不自动播放。
- 所有成功任务都可由用户点“立即播放”；每次成功的立即播放动作只能消费一次，避免快速连点重复触发。

自动播放资格是单次尝试的内存状态，不跨进程恢复；`interrupted` 重试时重新按当时队列情况计算。

## 取消、失败与清理

- 取消 `queued`：直接标记 `cancelled`，不占用槽位。
- 取消 `downloading`：先让 generation 失效，再取消对应 `Task`；Manager 按现有事务规则清理临时文件、reservation 或已提交但尚未索引的文件。
- 取消、失败或已中断任务都不会自动写入资料库。
- 网络、响应、音频校验、存储和索引错误映射为稳定错误类别，界面在当前语言下格式化文字。
- 清理失败不得伪装成普通下载失败；保留原始错误和清理错误的现有 `DownloadRollbackError` 语义，并让任务进入可重试的 `failure`。
- 用户删除任务记录时只删除队列账本项；只有取消活动任务需要先等待其进入终态，避免删除记录后仍有回调重新生成任务。

## 应用生命周期

页面生命周期不再控制下载生命周期：

- `DownloadSheetViewController.deinit` 不取消队列任务。
- `presentationControllerDidDismiss` 不取消队列任务。
- 应用进入后台不主动取消；普通 `URLSession` 能运行多久仍由 iOS 决定。
- 应用进入前台后继续订阅同一队列并刷新快照。
- 进程即将终止时尽力保存当前账本，但正确性不依赖终止回调；每个关键状态已经即时持久化。

## 依赖注入与降级

`AppEnvironment` 在下载存储可用时创建 `DownloadManager`、`DownloadQueueStore` 和唯一 `DownloadQueue`，并把队列交给 `AppRootDependencies` 的下载页面工厂。

如果下载根目录不可用，保留现有 `DownloadUnavailableViewController` 降级，不创建伪队列；系统资料库浏览和系统音乐播放继续可用。队列持久化文件损坏只影响任务记录，不能让应用启动失败或删除本地歌曲。

测试可注入：

- 单任务下载 operation。
- JSON store URL 或内存 store。
- 受控文件恢复接口和索引查询。
- 当前时间。
- 资料库刷新与播放回调。

这些 seam 只用于隔离 I/O 和确定性测试，不引入未使用的生产配置开关。

## 测试策略

### DownloadQueue 单元测试

- 连续提交 4 个任务时仅前 3 个开始，第 4 个保持 `queued`。
- 任一活动任务完成、失败或取消后，FIFO 的下一项开始。
- 不同任务的进度分别更新，不互相覆盖。
- 取消某一任务不影响另外两个活动任务。
- 取消后迟到进度和结果不能覆盖 `cancelled` 或新 generation。
- `failure`、`cancelled`、`interrupted` 重试时进度归零并重新排队。
- 同一成功任务“立即播放”快速触发两次也只执行一次。
- 多任务完成不自动抢占播放；只有符合单任务规则的任务自动播放一次。

### 持久化与恢复测试

- JSON 原子保存和加载保持 ID、URL、顺序及状态。
- 上次 `queued/downloading` 在启动时变为 `interrupted`，不会自行发起请求。
- 已有索引的 reserved 文件被视为已完成且不删除。
- 无索引的受控 reserved 文件被清理，任务变为 `interrupted`。
- traversal、符号链接和未知 I/O 错误不越过 `DownloadFileStore` 安全边界，也不误删用户数据。
- 损坏账本不崩溃、不删除歌曲，并留下诊断。

### 页面行为测试

- 提交多个 URL 后产生多条任务行。
- 关闭、下拉和控制器释放不调用队列取消。
- 使用同一队列重新打开页面能看到原任务和最新进度。
- 每行取消、重试、删除和立即播放只操作对应 ID。
- iPhone 与 iPad 下载入口持有同一队列实例。
- 三种语言的状态、错误、按钮、百分比和无障碍文本均有资源且 key 一致。

### 回归验证

- 现有 `DownloadManagerConcurrencyTests` 继续证明底层最多 3 个并发、FIFO、取消和事务回滚。
- 现有下载文件安全、资料库刷新、播放和设置测试继续通过。
- 运行完整 XCTest、generic iOS Simulator build 和 generic iOS device build。

## 实施边界

预计只修改下载领域、应用环境接线、下载 UI、本地化资源、必要的工程文件和对应测试。不会顺手重构播放器、资料库布局或系统音乐权限流程。

实现必须使用现有 CocoaPods/SnapKit 代码布局，保持 iOS 15 最低版本和仅竖屏配置。新增生产代码保留简洁中文注释，只解释队列所有权、generation 隔离、恢复顺序和文件安全等非显而易见约束。

## 完成标准

- 用户可连续添加任意数量的有效音频直链。
- 应用内同时最多 3 个任务下载，其余按 FIFO 等待。
- 关闭或重新打开下载页面不会取消任务，状态和进度连续可见。
- 用户能逐项取消、重试、删除记录和播放成功歌曲。
- 应用进程终止后，未完成任务下次启动显示“已中断”，不会自动继续，手动重试从 0 开始。
- 未完成任务不会进入资料库；恢复清理不误删已入库歌曲或下载根之外的文件。
- 多任务完成不会抢占播放，单任务自动播放遵循设置且最多触发一次。
- 英文、简体中文和繁体中文界面及无障碍文本完整。
- 相关聚焦测试、全量测试以及模拟器和设备构建通过。
