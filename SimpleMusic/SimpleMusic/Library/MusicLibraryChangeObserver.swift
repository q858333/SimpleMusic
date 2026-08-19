import MediaPlayer

/// 系统资料库通知只注册一次，并把变化统一转成共享 ViewModel 的刷新请求。
@MainActor
final class MusicLibraryChangeObserver {
    private let notificationCenter: NotificationCenter
    private let endGenerating: () -> Void
    private var token: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter = .default,
        notificationName: Notification.Name = .MPMediaLibraryDidChange,
        beginGenerating: @escaping () -> Void = {
            MPMediaLibrary.default().beginGeneratingLibraryChangeNotifications()
        },
        endGenerating: @escaping () -> Void = {
            MPMediaLibrary.default().endGeneratingLibraryChangeNotifications()
        },
        onChange: @escaping @MainActor () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.endGenerating = endGenerating
        beginGenerating()
        token = notificationCenter.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    deinit {
        if let token {
            notificationCenter.removeObserver(token)
        }
        endGenerating()
    }
}
