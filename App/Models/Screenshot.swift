import Foundation

struct Screenshot: Identifiable, Sendable {
    let id: String
    let revision: Revision

    var date: Date? { revision.date }
    var isFavorite: Bool { revision.isFavorite }

    struct Revision: Equatable, Sendable {
        let date: Date?
        let modifiedAt: Date?
        let width: Int
        let height: Int
        let isFavorite: Bool
    }
}

struct ScreenshotMonth: Identifiable, Sendable {
    let date: Date?
    var screenshots: [Screenshot]

    var id: Date? { date }
}

enum PhotoAccess: Equatable, Sendable {
    case notDetermined, restricted, denied, authorized, limited, unknown

    var canRead: Bool { self == .authorized || self == .limited }
}

enum DeletionOutcome: Sendable {
    case success, changed, cancelled, failed, unknown
}
