import Combine
import SnapKit
import UIKit

/// 播放快照的轻量入口；完整播放器页面由后续任务承接。
final class MiniPlayerView: UIView {
    private let onTogglePlay: () -> Void
    private let onOpenPlayer: () -> Void
    private var snapshotCancellable: AnyCancellable?
    private var usesPlaceholderArtwork = false

    private let materialView: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        view.accessibilityIdentifier = "mini.material"
        view.isUserInteractionEnabled = false
        return view
    }()

    private let artworkView: UIImageView = {
        let view = UIImageView()
        view.accessibilityIdentifier = "mini.artwork"
        view.backgroundColor = UIColor.tertiarySystemFill
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 10
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.accessibilityIdentifier = "mini.title"
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        return label
    }()

    private let artistLabel: UILabel = {
        let label = UILabel()
        label.accessibilityIdentifier = "mini.artist"
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        return label
    }()

    private lazy var metadataStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        stack.axis = .vertical
        stack.spacing = 2
        return stack
    }()

    private lazy var toggleButton: UIButton = {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "mini.toggle"
        button.tintColor = .label
        Theme.installPressFeedback(on: button)
        button.addAction(UIAction { [weak self] _ in
            self?.onTogglePlay()
        }, for: .touchUpInside)
        return button
    }()

    private lazy var openButton: UIButton = {
        let button = UIButton(type: .custom)
        button.accessibilityIdentifier = "mini.open"
        button.accessibilityLabel = L10n.text("player.open_now_playing")
        Theme.installPressFeedback(on: button)
        button.addAction(UIAction { [weak self] _ in
            self?.onOpenPlayer()
        }, for: .touchUpInside)
        return button
    }()

    init(
        snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never>,
        onTogglePlay: @escaping () -> Void,
        onOpenPlayer: @escaping () -> Void
    ) {
        self.onTogglePlay = onTogglePlay
        self.onOpenPlayer = onOpenPlayer
        super.init(frame: .zero)
        isHidden = true
        buildView()
        if #available(iOS 17.0, *) {
            // 新版 UIKit 需显式监听界面样式，确保迷你播放器即时切换红白音符。
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                (view: MiniPlayerView, _) in
                view.updateBorderColor()
                if view.usesPlaceholderArtwork {
                    view.updatePlaceholderArtwork()
                }
            }
        }
        snapshotCancellable = snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.render(snapshot)
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MiniPlayerView 仅支持纯代码初始化")
    }

    deinit {
        snapshotCancellable?.cancel()
    }

    override var intrinsicContentSize: CGSize {
        let artworkHeight: CGFloat = 46 + 18
        let metadataHeight = titleLabel.font.lineHeight + artistLabel.font.lineHeight + 2 + 18
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: max(64, max(artworkHeight, metadataHeight))
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory {
            invalidateIntrinsicContentSize()
        }
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateBorderColor()
        }
        guard usesPlaceholderArtwork,
              previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else {
            return
        }
        updatePlaceholderArtwork()
    }

    func stop() {
        snapshotCancellable?.cancel()
        snapshotCancellable = nil
    }

    private func buildView() {
        backgroundColor = .clear
        layer.cornerRadius = 14
        layer.borderWidth = 0.5
        clipsToBounds = true
        updateBorderColor()

        addSubview(materialView)
        addSubview(openButton)
        addSubview(artworkView)
        addSubview(metadataStack)
        addSubview(toggleButton)

        materialView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        openButton.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        artworkView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(9)
            make.centerY.equalToSuperview()
            make.size.equalTo(46)
            make.top.greaterThanOrEqualToSuperview().offset(9)
            make.bottom.lessThanOrEqualToSuperview().inset(9)
        }
        toggleButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(8)
            make.centerY.equalToSuperview()
            make.size.greaterThanOrEqualTo(44)
        }
        metadataStack.snp.makeConstraints { make in
            make.leading.equalTo(artworkView.snp.trailing).offset(10)
            make.trailing.lessThanOrEqualTo(toggleButton.snp.leading).offset(-8)
            make.centerY.equalToSuperview()
            make.top.greaterThanOrEqualToSuperview().offset(9)
            make.bottom.lessThanOrEqualToSuperview().inset(9)
        }
        snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(64)
        }
    }

    private func updateBorderColor() {
        layer.borderColor = Theme.hairline.resolvedColor(with: traitCollection).cgColor
    }

    private func render(_ snapshot: PlaybackSnapshot) {
        guard let track = snapshot.track else {
            isHidden = true
            titleLabel.text = nil
            artistLabel.text = nil
            artworkView.image = nil
            artworkView.contentMode = .scaleAspectFill
            usesPlaceholderArtwork = false
            return
        }

        isHidden = false
        titleLabel.text = track.title
        artistLabel.text = track.artist
        if let artwork = track.artworkData.flatMap(UIImage.init(data:)) {
            usesPlaceholderArtwork = false
            artworkView.image = artwork
            artworkView.contentMode = .scaleAspectFill
        } else {
            usesPlaceholderArtwork = true
            updatePlaceholderArtwork()
        }

        let isPlaying = snapshot.status == .playing
        toggleButton.accessibilityLabel = isPlaying
            ? L10n.text("common.pause")
            : L10n.text("common.play")
        toggleButton.setImage(
            UIImage(systemName: isPlaying ? "pause.fill" : "play.fill"),
            for: .normal
        )
    }

    private func updatePlaceholderArtwork() {
        // 46pt 封面位在浅色模式使用红色音符，深色模式使用白色音符。
        let imageName = traitCollection.userInterfaceStyle == .dark
            ? "music-note-white"
            : "music-note-red"
        artworkView.image = UIImage(named: imageName)
        artworkView.contentMode = .center
    }
}
