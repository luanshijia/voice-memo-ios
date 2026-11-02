import Foundation

/// Result selection follows operation creation, never report delivery order.
struct ResultOperation: Codable, Equatable {
    let id: String
    let purpose: String
    let createdAt: String

    private var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: createdAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: createdAt)
    }

    var label: String {
        let name = purpose == "memo" ? "待办" : "会议"
        guard let date else { return name + " · 时间未知" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return name + " · " + formatter.string(from: date)
    }

    func isNewer(than previous: ResultOperation?) -> Bool {
        guard let previous else { return true }
        guard let date else { return false }
        guard let previousDate = previous.date else { return true }
        guard id != previous.id else { return false }
        return date > previousDate
    }
}
