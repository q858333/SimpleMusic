import SnapKit
import UIKit

/// 统一承载轻量品牌插图与现有空状态文案，不改变页面原有状态判断。
final class BrandedEmptyStateView: UIView {
    let messageLabel = UILabel()

    private let artworkView = UIImageView()

    init(
        identifier: String,
        artworkIdentifier: String,
        messageIdentifier: String,
        message: String,
        messageMaximumWidth: CGFloat = 212
    ) {
        super.init(frame: .zero)
        accessibilityIdentifier = identifier
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5

        artworkView.accessibilityIdentifier = artworkIdentifier
        artworkView.contentMode = .scaleAspectFit

        messageLabel.accessibilityIdentifier = messageIdentifier
        messageLabel.text = message
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [artworkView, messageLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12

        addSubview(stack)
        artworkView.snp.makeConstraints { make in
            make.width.height.equalTo(52)
        }
        messageLabel.snp.makeConstraints { make in
            make.width.lessThanOrEqualTo(messageMaximumWidth)
            make.leading.greaterThanOrEqualTo(stack)
            make.trailing.lessThanOrEqualTo(stack)
        }
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(24)
        }

        updateVisuals()
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                (view: BrandedEmptyStateView, _) in
                view.updateVisuals()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrandedEmptyStateView 仅支持纯代码初始化")
    }

    var message: String? {
        get { messageLabel.text }
        set { messageLabel.text = newValue }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        updateVisuals()
    }

    private func updateVisuals() {
        backgroundColor = Theme.elevatedSurface
        layer.borderColor = Theme.hairline.resolvedColor(with: traitCollection).cgColor
        let imageName = traitCollection.userInterfaceStyle == .dark
            ? "music-note-white"
            : "music-note-red"
        artworkView.image = UIImage(named: imageName)
    }
}
