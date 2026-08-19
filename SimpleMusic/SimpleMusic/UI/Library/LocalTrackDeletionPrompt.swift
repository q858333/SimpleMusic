import UIKit

extension UIViewController {
    /// 本地删除必须经用户确认；系统歌曲在调用前已被 TrackCell 隐藏入口。
    func presentLocalTrackDeletionPrompt(
        for track: MusicTrack,
        onConfirm: @escaping () -> Void
    ) {
        guard case .downloaded = track.source, presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "删除本地歌曲？",
            message: "将从此设备移除“\(track.title)”及其下载记录。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in onConfirm() })
        present(alert, animated: true)
    }
}
