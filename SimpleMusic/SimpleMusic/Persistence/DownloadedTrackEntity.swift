import CoreData

/// Core Data 手写实体，字段必须与 Manual/None 数据模型保持一致。
@objc(DownloadedTrackEntity)
final class DownloadedTrackEntity: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var fileName: String
    @NSManaged var title: String
    @NSManaged var artist: String
    @NSManaged var album: String
    @NSManaged var duration: Double
    @NSManaged var createdAt: Date
    @NSManaged var lastPlayedAt: Date?
    @NSManaged var sourceURL: String?
}
