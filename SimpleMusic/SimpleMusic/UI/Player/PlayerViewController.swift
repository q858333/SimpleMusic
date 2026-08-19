import AVKit
import Combine
import MediaPlayer
import SnapKit
import UIKit

/// iPhone 全屏页和 iPad 侧栏共用的播放内容，只消费统一播放快照和控制动作。
final class PlayerViewController: UIViewController {
    var onDismiss: (() -> Void)?

    private let onTogglePlay: () -> Void
    private let onPrevious: () -> Void
    private let onNext: () -> Void
    private let onSeek: (TimeInterval) -> Void
    private var snapshotCancellable: AnyCancellable?
    private var isSeeking = false

    private let artworkView: UIImageView = {
        let view = UIImageView()
        view.accessibilityIdentifier = "player.artwork"
        view.backgroundColor = Theme.accent
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 20
        view.tintColor = .white
        return view
    }()

    private let placeholderArtworkView: UIImageView = {
        let view = UIImageView(image: UIImage(named: "music-note-white"))
        view.accessibilityIdentifier = "player.artwork.placeholder"
        view.contentMode = .scaleAspectFit
        view.isAccessibilityElement = false
        return view
    }()

    private let titleLabel = PlayerViewController.label(
        identifier: "player.title",
        style: .title2,
        weight: .semibold,
        color: .label
    )
    private let artistLabel = PlayerViewController.label(
        identifier: "player.artist",
        style: .body,
        color: .secondaryLabel
    )
    private let albumLabel = PlayerViewController.label(
        identifier: "player.album",
        style: .subheadline,
        color: .secondaryLabel
    )
    private let elapsedLabel = PlayerViewController.label(
        identifier: "player.elapsed",
        style: .caption1,
        color: .secondaryLabel
    )
    private let remainingLabel = PlayerViewController.label(
        identifier: "player.remaining",
        style: .caption1,
        color: .secondaryLabel
    )
    private let queuePositionLabel = PlayerViewController.label(
        identifier: "player.queue",
        style: .subheadline,
        color: .label
    )

    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "player.close"
        button.accessibilityLabel = "关闭正在播放"
        button.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        button.tintColor = .label
        button.addAction(UIAction { [weak self] _ in
            self?.onDismiss?()
        }, for: .touchUpInside)
        return button
    }()

    var initialAccessibilityFocusView: UIView {
        loadViewIfNeeded()
        return closeButton
    }

    private lazy var progressSlider: UISlider = {
        let slider = UISlider()
        slider.accessibilityIdentifier = "player.progress"
        slider.accessibilityLabel = "播放进度"
        slider.minimumTrackTintColor = Theme.accent
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.addTarget(self, action: #selector(beginSeeking), for: .touchDown)
        slider.addTarget(self, action: #selector(progressValueChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(endSeeking), for: [
            .touchUpInside,
            .touchUpOutside,
            .touchCancel
        ])
        return slider
    }()

    private lazy var previousButton = controlButton(
        identifier: "player.previous",
        label: "上一首",
        symbol: "backward.fill",
        action: onPrevious
    )
    private lazy var toggleButton = controlButton(
        identifier: "player.toggle",
        label: "播放",
        symbol: "play.fill",
        prominent: true,
        action: onTogglePlay
    )
    private lazy var nextButton = controlButton(
        identifier: "player.next",
        label: "下一首",
        symbol: "forward.fill",
        action: onNext
    )

    private let volumeView: MPVolumeView = {
        let view = MPVolumeView()
        view.accessibilityIdentifier = "player.volume"
        return view
    }()

    private let routePickerView: AVRoutePickerView = {
        let view = AVRoutePickerView()
        view.accessibilityIdentifier = "player.airplay"
        view.accessibilityLabel = "AirPlay"
        view.tintColor = Theme.accent
        view.activeTintColor = Theme.accent
        return view
    }()

    init(
        snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never>,
        onTogglePlay: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.onTogglePlay = onTogglePlay
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onSeek = onSeek
        super.init(nibName: nil, bundle: nil)
        snapshotCancellable = snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.render(snapshot)
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlayerViewController 仅支持纯代码初始化")
    }

    deinit {
        snapshotCancellable?.cancel()
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var shouldAutorotate: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        buildView()
    }

    private func buildView() {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        let contentView = UIView()
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        contentView.snp.makeConstraints { make in
            make.edges.equalTo(scrollView.contentLayoutGuide)
            make.width.equalTo(scrollView.frameLayoutGuide)
        }

        let headerLabel = Self.label(style: .caption1, weight: .semibold, color: .secondaryLabel)
        headerLabel.text = "正在播放"
        headerLabel.textAlignment = .center

        let queueTitle = Self.label(style: .headline, weight: .semibold, color: .secondaryLabel)
        queueTitle.text = "接下来播放"

        let controls = UIStackView(arrangedSubviews: [previousButton, toggleButton, nextButton])
        controls.axis = .horizontal
        controls.alignment = .center
        controls.distribution = .equalCentering

        let utilities = UIStackView(arrangedSubviews: [volumeView, routePickerView])
        utilities.axis = .horizontal
        utilities.alignment = .center
        utilities.spacing = 12

        [
            closeButton,
            headerLabel,
            artworkView,
            titleLabel,
            artistLabel,
            albumLabel,
            progressSlider,
            elapsedLabel,
            remainingLabel,
            controls,
            utilities,
            queueTitle,
            queuePositionLabel
        ].forEach(contentView.addSubview)

        artworkView.addSubview(placeholderArtworkView)
        placeholderArtworkView.snp.makeConstraints { make in
            // 播放器的大封面区域使用 88pt 音符，避免默认图在 iPad 侧栏中过小。
            make.center.equalToSuperview()
            make.size.equalTo(88)
        }

        closeButton.snp.makeConstraints { make in
            make.top.equalTo(contentView.safeAreaLayoutGuide).offset(4)
            make.leading.equalToSuperview().offset(12)
            make.size.greaterThanOrEqualTo(44)
        }
        headerLabel.snp.makeConstraints { make in
            make.centerY.equalTo(closeButton)
            make.centerX.equalToSuperview()
            make.leading.greaterThanOrEqualTo(closeButton.snp.trailing).offset(8)
        }
        artworkView.snp.makeConstraints { make in
            make.top.equalTo(closeButton.snp.bottom).offset(14)
            make.centerX.equalToSuperview()
            make.width.equalToSuperview().inset(20).priority(.high)
            make.width.lessThanOrEqualTo(342)
            make.height.equalTo(artworkView.snp.width)
        }
        titleLabel.snp.makeConstraints { make in
            make.top.equalTo(artworkView.snp.bottom).offset(22)
            make.leading.trailing.equalToSuperview().inset(20)
        }
        artistLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(4)
            make.leading.trailing.equalTo(titleLabel)
        }
        albumLabel.snp.makeConstraints { make in
            make.top.equalTo(artistLabel.snp.bottom).offset(3)
            make.leading.trailing.equalTo(titleLabel)
        }
        progressSlider.snp.makeConstraints { make in
            make.top.equalTo(albumLabel.snp.bottom).offset(14)
            make.leading.trailing.equalToSuperview().inset(20)
            make.height.greaterThanOrEqualTo(44)
        }
        elapsedLabel.snp.makeConstraints { make in
            make.top.equalTo(progressSlider.snp.bottom).offset(-4)
            make.leading.equalTo(progressSlider)
        }
        remainingLabel.snp.makeConstraints { make in
            make.centerY.equalTo(elapsedLabel)
            make.trailing.equalTo(progressSlider)
        }
        controls.snp.makeConstraints { make in
            make.top.equalTo(elapsedLabel.snp.bottom).offset(12)
            make.leading.trailing.equalToSuperview().inset(46)
        }
        utilities.snp.makeConstraints { make in
            make.top.equalTo(controls.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(20)
        }
        volumeView.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(44)
        }
        routePickerView.snp.makeConstraints { make in
            make.size.greaterThanOrEqualTo(44)
        }
        queueTitle.snp.makeConstraints { make in
            make.top.equalTo(utilities.snp.bottom).offset(18)
            make.leading.trailing.equalToSuperview().inset(20)
        }
        queuePositionLabel.snp.makeConstraints { make in
            make.top.equalTo(queueTitle.snp.bottom).offset(8)
            make.leading.trailing.equalTo(queueTitle)
            make.bottom.equalToSuperview().inset(24)
        }
    }

    private func render(_ snapshot: PlaybackSnapshot) {
        guard let track = snapshot.track else {
            renderEmptyState()
            return
        }

        titleLabel.text = track.title
        artistLabel.text = track.artist
        albumLabel.text = track.album
        if let artwork = track.artworkData.flatMap(UIImage.init(data:)) {
            artworkView.image = artwork
            artworkView.contentMode = .scaleAspectFill
            placeholderArtworkView.isHidden = true
        } else {
            artworkView.image = nil
            artworkView.contentMode = .scaleAspectFill
            placeholderArtworkView.isHidden = false
        }

        let isPlaying = snapshot.status == .playing
        toggleButton.accessibilityLabel = isPlaying ? "暂停" : "播放"
        toggleButton.setImage(
            UIImage(systemName: isPlaying ? "pause.fill" : "play.fill"),
            for: .normal
        )
        updateControlAvailability(for: snapshot)
        // 进入不可 seek 状态即结束本地拖动，避免迟到的终止事件提交失效进度。
        if !progressSlider.isEnabled {
            isSeeking = false
        }
        elapsedLabel.text = Self.timeText(snapshot.elapsed)
        remainingLabel.text = "-\(Self.timeText(max(0, snapshot.duration - snapshot.elapsed)))"
        queuePositionLabel.text = Self.queueText(snapshot)

        // 手指按住时保留用户选择，避免周期快照把滑块抢回旧进度。
        if !isSeeking {
            progressSlider.maximumValue = Float(max(1, snapshot.duration))
            progressSlider.value = Float(min(max(0, snapshot.elapsed), snapshot.duration))
        }
    }

    private func renderEmptyState() {
        // 空快照结束上一首的本地拖动，迟到 touchUp 不得作用于下一首。
        isSeeking = false
        titleLabel.text = "尚未播放"
        artistLabel.text = "选择一首歌曲开始播放"
        albumLabel.text = nil
        artworkView.image = nil
        artworkView.contentMode = .scaleAspectFill
        placeholderArtworkView.isHidden = false
        elapsedLabel.text = "0:00"
        remainingLabel.text = "-0:00"
        queuePositionLabel.text = "队列为空"
        progressSlider.maximumValue = 1
        progressSlider.value = 0
        toggleButton.accessibilityLabel = "播放"
        toggleButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        setPlaybackControlsEnabled(false)
    }

    private func setPlaybackControlsEnabled(_ enabled: Bool) {
        [previousButton, toggleButton, nextButton].forEach { $0.isEnabled = enabled }
        progressSlider.isEnabled = enabled
        setSystemUtilitiesEnabled(enabled)
    }

    private func updateControlAvailability(for snapshot: PlaybackSnapshot) {
        guard let index = snapshot.queueIndex,
              (0..<snapshot.queueCount).contains(index) else {
            setPlaybackControlsEnabled(false)
            return
        }

        let isReady: Bool
        switch snapshot.status {
        case .playing, .paused:
            isReady = true
        case .idle, .loading, .failed:
            isReady = false
        }

        // 切歌只在真实相邻项存在时开放；播放切换和进度只在后端已就绪时开放。
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index + 1 < snapshot.queueCount
        toggleButton.isEnabled = isReady
        progressSlider.isEnabled = isReady
        setSystemUtilitiesEnabled(true)
    }

    private func setSystemUtilitiesEnabled(_ enabled: Bool) {
        volumeView.isUserInteractionEnabled = enabled
        routePickerView.isUserInteractionEnabled = enabled
        volumeView.alpha = enabled ? 1 : 0.45
        routePickerView.alpha = enabled ? 1 : 0.45
    }

    @objc private func beginSeeking() {
        isSeeking = true
    }

    @objc private func endSeeking() {
        guard isSeeking else { return }
        isSeeking = false
        guard progressSlider.isEnabled else { return }
        onSeek(TimeInterval(progressSlider.value))
    }

    @objc private func progressValueChanged() {
        guard progressSlider.isEnabled, !isSeeking, !progressSlider.isTracking else { return }
        onSeek(TimeInterval(progressSlider.value))
    }

    private func controlButton(
        identifier: String,
        label: String,
        symbol: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = label
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = prominent ? .white : .label
        if prominent {
            button.backgroundColor = Theme.accent
            button.layer.cornerRadius = 31
            button.snp.makeConstraints { make in make.size.equalTo(62) }
        } else {
            button.snp.makeConstraints { make in make.size.greaterThanOrEqualTo(44) }
        }
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private static func label(
        identifier: String? = nil,
        style: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        color: UIColor
    ) -> UILabel {
        let label = UILabel()
        label.accessibilityIdentifier = identifier
        label.font = .preferredFont(forTextStyle: style).withWeight(weight)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 1
        return label
    }

    private static func timeText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    private static func queueText(_ snapshot: PlaybackSnapshot) -> String {
        guard snapshot.queueCount > 0 else { return "队列为空" }
        guard let index = snapshot.queueIndex else { return "队列已结束" }
        return "第 \(index + 1) / \(snapshot.queueCount) 首"
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
