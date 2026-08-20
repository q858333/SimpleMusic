import UIKit

extension UIViewController {
    /// 本地删除必须经用户确认；系统歌曲在调用前已被 TrackCell 隐藏入口。
    func presentLocalTrackDeletionPrompt(
        for track: MusicTrack,
        onConfirm: @escaping () -> Void
    ) {
        guard case .downloaded = track.source, presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: L10n.text("deletion.title"),
            message: L10n.format("deletion.message", track.title),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.text("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.text("common.delete"), style: .destructive) { _ in onConfirm() })
        present(alert, animated: true)
    }
}
