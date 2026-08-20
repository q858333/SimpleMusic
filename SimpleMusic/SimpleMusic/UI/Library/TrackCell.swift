import SnapKit
import UIKit

/// 资料库和搜索共用的歌曲行，内容完全来自统一 MusicTrack。
final class TrackCell: UICollectionViewCell {
    static let reuseIdentifier = "TrackCell"

    var onMore: (() -> Void)?
    private var usesPlaceholderArtwork = false

    private let artworkView: UIImageView = {
        let view = UIImageView()
        view.accessibilityIdentifier = "track.artwork"
        view.backgroundColor = UIColor.tertiarySystemFill
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 10
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.accessibilityIdentifier = "track.title"
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.accessibilityIdentifier = "track.subtitle"
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }()

    private let downloadedLabel: UILabel = {
        let label = InsetLabel(contentInsets: UIEdgeInsets(top: 4, left: 7, bottom: 4, right: 7))
        label.accessibilityIdentifier = "track.downloaded"
        label.text = L10n.text("track.downloaded")
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.backgroundColor = UIColor.tertiarySystemFill
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.textAlignment = .center
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }()

    private lazy var moreButton: UIButton = {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "track.more"
        button.accessibilityLabel = L10n.text("track.more_actions")
        button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        button.tintColor = .secondaryLabel
        button.addAction(UIAction { [weak self] _ in
            self?.onMore?()
        }, for: .touchUpInside)
        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildView()
        if #available(iOS 17.0, *) {
            // 新版 UIKit 不再保证调用 traitCollectionDidChange，需显式监听界面样式变化。
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                (cell: TrackCell, _) in
                guard cell.usesPlaceholderArtwork else { return }
                cell.updatePlaceholderArtwork()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TrackCell 仅支持纯代码初始化")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkView.image = nil
        artworkView.contentMode = .scaleAspectFill
        usesPlaceholderArtwork = false
        onMore = nil
    }

    func configure(with track: MusicTrack) {
        titleLabel.text = track.title
        subtitleLabel.text = "\(track.artist) · \(track.album)"
        if let artwork = track.artworkData.flatMap(UIImage.init(data:)) {
            usesPlaceholderArtwork = false
            artworkView.image = artwork
            artworkView.contentMode = .scaleAspectFill
        } else {
            usesPlaceholderArtwork = true
            updatePlaceholderArtwork()
        }
        if case .downloaded = track.source {
            downloadedLabel.isHidden = false
            moreButton.isHidden = false
        } else {
            downloadedLabel.isHidden = true
            moreButton.isHidden = true
        }
        accessibilityLabel = L10n.format("track.accessibility", track.title, track.artist, track.album)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard usesPlaceholderArtwork,
              previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else {
            return
        }
        updatePlaceholderArtwork()
    }

    private func updatePlaceholderArtwork() {
        // 浅色背景使用红色音符，深色背景使用白色音符，保证占位图清晰可辨。
        let imageName = traitCollection.userInterfaceStyle == .dark
            ? "music-note-white"
            : "music-note-red"
        artworkView.image = UIImage(named: imageName)
        artworkView.contentMode = .center
    }

    private func buildView() {
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 12
        clipsToBounds = true

        contentView.addSubview(artworkView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(downloadedLabel)
        contentView.addSubview(moreButton)

        artworkView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(10)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(46)
            make.top.greaterThanOrEqualToSuperview().offset(10)
            make.bottom.lessThanOrEqualToSuperview().inset(10)
        }
        moreButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(4)
            make.centerY.equalToSuperview()
            make.width.height.greaterThanOrEqualTo(44)
        }
        downloadedLabel.snp.makeConstraints { make in
            make.trailing.equalTo(moreButton.snp.leading).offset(-4)
            make.centerY.equalToSuperview()
            make.width.greaterThanOrEqualTo(50)
            make.height.greaterThanOrEqualTo(22)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(artworkView.snp.trailing).offset(10)
            make.trailing.lessThanOrEqualTo(downloadedLabel.snp.leading).offset(-8)
            make.top.equalToSuperview().offset(11)
        }
        subtitleLabel.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel)
            make.trailing.lessThanOrEqualTo(downloadedLabel.snp.leading).offset(-8)
            make.top.equalTo(titleLabel.snp.bottom).offset(3)
            make.bottom.equalToSuperview().inset(9)
        }
    }
}

/// 下载标识由文本和内边距共同决定尺寸，辅助字号下不固定裁切。
private final class InsetLabel: UILabel {
    private let contentInsets: UIEdgeInsets

    init(contentInsets: UIEdgeInsets) {
        self.contentInsets = contentInsets
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InsetLabel 仅支持纯代码初始化")
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + contentInsets.left + contentInsets.right,
            height: size.height + contentInsets.top + contentInsets.bottom
        )
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
    }
}
