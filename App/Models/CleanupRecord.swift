import Foundation

struct CleanupHistory: Identifiable {
    let id: String
    let date: Date
    let count: Int
}

struct PendingCleanup {
    let id: String
    let confirmedAt: Date?
}

enum CleanupLimits {
    static let freeItems = 10
    static let batchSize = 200
}
