import UIKit

/// iPhone 竖屏根壳；这里只定义导航边界，业务页面由后续任务替换占位控制器。
final class MainTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()
        tabBar.tintColor = Theme.accent
        viewControllers = [
            makePlaceholder(title: "资料库", symbol: "music.note.list"),
            makePlaceholder(title: "搜索", symbol: "magnifyingglass")
        ]
    }

    private func makePlaceholder(title: String, symbol: String) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = Theme.background
        controller.title = title
        controller.tabBarItem = UITabBarItem(
            title: title,
            image: UIImage(systemName: symbol),
            selectedImage: nil
        )
        return UINavigationController(rootViewController: controller)
    }
}
