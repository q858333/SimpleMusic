import SnapKit
import UIKit

/// 下载能力降级页不阻塞资料库与系统歌曲播放。
final class DownloadUnavailableViewController: UIViewController {
    private let message: String

    init(message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
        title = "下载不可用"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DownloadUnavailableViewController 仅支持纯代码初始化")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        let label = UILabel()
        label.accessibilityIdentifier = "download.unavailable"
        label.text = message
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        view.addSubview(label)
        label.snp.makeConstraints { make in
            make.center.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(28)
        }
    }
}
