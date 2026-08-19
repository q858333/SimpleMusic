import CoreData
import Foundation

struct PersistentStoreResolution {
    let container: NSPersistentContainer
    let warning: String?
}

/// 把持久 store 加载变成可注入边界，测试无需真的破坏用户数据库。
struct PersistentStoreFactory {
    typealias ContainerFactory = () -> NSPersistentContainer
    typealias Loader = (NSPersistentContainer, @escaping (Error?) -> Void) -> Void

    private let makePersistentContainer: ContainerFactory
    private let makeMemoryContainer: ContainerFactory
    private let load: Loader

    init(
        makePersistentContainer: @escaping ContainerFactory = {
            NSPersistentContainer(name: "SimpleMusic")
        },
        makeMemoryContainer: @escaping ContainerFactory = {
            let container = NSPersistentContainer(name: "SimpleMusic")
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            description.shouldAddStoreAsynchronously = false
            container.persistentStoreDescriptions = [description]
            return container
        },
        load: @escaping Loader = { container, completion in
            container.persistentStoreDescriptions.forEach {
                $0.shouldAddStoreAsynchronously = false
            }
            container.loadPersistentStores { _, error in completion(error) }
        }
    ) {
        self.makePersistentContainer = makePersistentContainer
        self.makeMemoryContainer = makeMemoryContainer
        self.load = load
    }

    func resolve() -> PersistentStoreResolution {
        let persistent = makePersistentContainer()
        var loadingError: Error?
        var didFinishLoading = false
        load(persistent) {
            loadingError = $0
            didFinishLoading = true
        }
        guard didFinishLoading, loadingError == nil else {
            let memory = makeMemoryContainer()
            var memoryError: Error?
            load(memory) { memoryError = $0 }
            let detail = [loadingError, memoryError]
                .compactMap { $0 }
                .map(String.init(describing:))
                .joined(separator: "；")
            let warning = "本地持久化暂不可用，已进入内存模式；原始资料未删除，请重启应用重试。"
                + (detail.isEmpty ? "" : "（\(detail)）")
            return PersistentStoreResolution(container: memory, warning: warning)
        }
        return PersistentStoreResolution(container: persistent, warning: nil)
    }
}

struct DownloadStorageResolution {
    let store: DownloadFileStore?
    let warning: String?
}

/// 下载目录失败只关闭下载能力，不创建临时目录冒充持久存储。
struct DownloadStorageFactory {
    typealias RootProvider = () throws -> URL
    private let rootProvider: RootProvider

    init(rootProvider: @escaping RootProvider = {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Downloads", isDirectory: true)
    }) {
        self.rootProvider = rootProvider
    }

    func resolve() -> DownloadStorageResolution {
        do {
            return DownloadStorageResolution(
                store: try DownloadFileStore(rootURL: rootProvider()),
                warning: nil
            )
        } catch {
            return DownloadStorageResolution(
                store: nil,
                warning: "下载存储暂不可用，请检查设备空间并重启应用后重试。"
            )
        }
    }
}
