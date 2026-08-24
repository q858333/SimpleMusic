//
//  AppDelegate.swift
//  SimpleMusic
//
//  Created by db on 2026/8/14.
//

import UIKit
import CoreData

extension Notification.Name {
    static let persistentStoreSaveDidFail = Notification.Name("SimpleMusic.persistentStoreSaveDidFail")
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var persistentStoreFactory = PersistentStoreFactory()
    var saveContextOperation: (NSManagedObjectContext) throws -> Void = { context in
        try context.save()
    }
    var appNotificationCenter = NotificationCenter.default
    var apnsTokenStore = APNsTokenStore.shared
    var remoteNotificationRegistrar: (UIApplication) -> Void = {
        $0.registerForRemoteNotifications()
    }

    private lazy var persistentStoreResolution = persistentStoreFactory.resolve()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 注册本身不会弹出通知权限框；系统会通过下方 delegate 回调返回最新 Token。
        remoteNotificationRegistrar(application)
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        apnsTokenStore.update(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("APNs 注册失败：%@", String(describing: error))
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }

    // MARK: - Core Data stack

    var persistentContainer: NSPersistentContainer {
        persistentStoreResolution.container
    }

    var persistentStoreWarning: String? {
        persistentStoreResolution.warning
    }

    // MARK: - Core Data Saving support

    func saveContext () {
        let context = persistentContainer.viewContext
        if context.hasChanges {
            do {
                try saveContextOperation(context)
            } catch {
                NSLog("本地索引保存失败：%@", String(describing: error))
                appNotificationCenter.post(
                    name: .persistentStoreSaveDidFail,
                    object: self,
                    userInfo: ["error": error]
                )
            }
        }
    }

}
