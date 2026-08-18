import SnapKit
import UIKit

/// iPad 竖屏双栏根壳；固定导航侧栏，右侧 child 容器保持自适应。
final class PadRootViewController: UIViewController {
    private let nowPlayingViewController: UIViewController

    private let sidebarView: UIView = {
        let view = UIView()
        view.accessibilityIdentifier = "pad.sidebar"
        view.backgroundColor = Theme.surface
        return view
    }()

    private let contentView: UIView = {
        let view = UIView()
        view.accessibilityIdentifier = "pad.content"
        view.backgroundColor = Theme.background
        return view
    }()

    convenience init() {
        let placeholder = UIViewController()
        placeholder.view.backgroundColor = Theme.background
        self.init(nowPlayingViewController: placeholder)
    }

    init(nowPlayingViewController: UIViewController) {
        self.nowPlayingViewController = nowPlayingViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PadRootViewController 仅支持纯代码初始化")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        buildColumns()
        installNowPlayingChild()
        buildSidebarPlaceholder()
    }

    private func buildColumns() {
        view.addSubview(sidebarView)
        view.addSubview(contentView)

        sidebarView.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.width.equalTo(264)
        }
        contentView.snp.makeConstraints { make in
            make.leading.equalTo(sidebarView.snp.trailing)
            make.top.trailing.bottom.equalToSuperview()
        }
    }

    private func installNowPlayingChild() {
        // UIKit child containment 顺序必须是 addChild → 挂载 view → didMove。
        addChild(nowPlayingViewController)
        contentView.addSubview(nowPlayingViewController.view)
        nowPlayingViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        nowPlayingViewController.didMove(toParent: self)
    }

    private func buildSidebarPlaceholder() {
        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.text = "听见"
        titleLabel.textColor = .label

        let libraryLabel = UILabel()
        libraryLabel.font = .preferredFont(forTextStyle: .headline)
        libraryLabel.adjustsFontForContentSizeCategory = true
        libraryLabel.text = "资料库"
        libraryLabel.textColor = Theme.accent

        let stack = UIStackView(arrangedSubviews: [titleLabel, libraryLabel])
        stack.axis = .vertical
        stack.spacing = 28
        sidebarView.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.top.equalTo(sidebarView.safeAreaLayoutGuide).offset(28)
            make.leading.trailing.equalToSuperview().inset(28)
        }
    }
}
