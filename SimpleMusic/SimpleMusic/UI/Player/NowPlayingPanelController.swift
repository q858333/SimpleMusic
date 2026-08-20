import SnapKit
import UIKit

/// iPad 正在播放遮罩容器；播放内容始终复用 PlayerViewController。
final class NowPlayingPanelController: UIViewController {
    private let playerViewController: PlayerViewController
    private let isReduceMotionEnabled: () -> Bool
    private var trailingConstraint: Constraint?
    private var transitionGeneration = 0
    private weak var focusReturnView: UIView?
    private(set) var isPresented = false

    private lazy var maskButton: UIButton = {
        let button = UIButton(type: .custom)
        button.accessibilityIdentifier = "player.mask"
        button.accessibilityLabel = L10n.text("player.close_now_playing")
        button.backgroundColor = UIColor.black.withAlphaComponent(0.22)
        button.addAction(UIAction { [weak self] _ in
            self?.dismissPanel()
        }, for: .touchUpInside)
        return button
    }()

    private let panelView: UIView = {
        let view = UIView()
        view.accessibilityIdentifier = "player.panel"
        view.backgroundColor = Theme.surface
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.16
        view.layer.shadowRadius = 18
        view.layer.shadowOffset = CGSize(width: -8, height: 0)
        return view
    }()

    init(
        playerViewController: PlayerViewController,
        isReduceMotionEnabled: @escaping () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    ) {
        self.playerViewController = playerViewController
        self.isReduceMotionEnabled = isReduceMotionEnabled
        super.init(nibName: nil, bundle: nil)
        playerViewController.onDismiss = { [weak self] in
            self?.dismissPanel()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("NowPlayingPanelController 仅支持纯代码初始化")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isHidden = true
        buildView()
    }

    func show(animated: Bool = true, returnFocusTo view: UIView? = nil) {
        loadViewIfNeeded()
        guard !isPresented else { return }
        isPresented = true
        transitionGeneration += 1
        let generation = transitionGeneration
        focusReturnView = view
        self.view.isHidden = false
        self.view.accessibilityViewIsModal = true
        self.view.superview?.bringSubviewToFront(self.view)
        self.view.superview?.layoutIfNeeded()
        trailingConstraint?.update(offset: 0)
        animateLayout(animated: animated) { [weak self] in
            guard let self, generation == transitionGeneration, isPresented else { return }
            UIAccessibility.post(
                notification: .screenChanged,
                argument: playerViewController.initialAccessibilityFocusView
            )
        }
    }

    func dismissPanel(animated: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        transitionGeneration += 1
        let generation = transitionGeneration
        trailingConstraint?.update(offset: 324)
        animateLayout(animated: animated) { [weak self] in
            guard let self, generation == transitionGeneration, !isPresented else { return }
            // 只隐藏最新一次关闭，避免快速重开后被旧动画 completion 盖掉。
            view.isHidden = true
            view.accessibilityViewIsModal = false
            UIAccessibility.post(notification: .screenChanged, argument: focusReturnView)
            focusReturnView = nil
        }
    }

    private func buildView() {
        view.addSubview(maskButton)
        view.addSubview(panelView)
        maskButton.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        panelView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.width.equalTo(324)
            trailingConstraint = make.trailing.equalToSuperview().offset(324).constraint
        }

        addChild(playerViewController)
        panelView.addSubview(playerViewController.view)
        playerViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        playerViewController.didMove(toParent: self)
    }

    private func animateLayout(animated: Bool, completion: (() -> Void)? = nil) {
        let animations: () -> Void = { [weak self] in
            self?.view.layoutIfNeeded()
        }
        guard animated, !isReduceMotionEnabled() else {
            animations()
            completion?()
            return
        }
        UIView.animate(
            withDuration: 0.24,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState],
            animations: animations,
            completion: { _ in completion?() }
        )
    }
}
