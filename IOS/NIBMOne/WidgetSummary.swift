import Foundation

// This file belongs to both the app and widget targets. No credentials enter this cache.
struct WidgetSummary: Codable, Equatable {
    static let groupID = "group.com.nawoda.nibmone"
    static let kind = "NIBMOneSummary"
    static let cacheKey = "signed-in-summary-v1"
    let updatedAt: Date
    let isDemo: Bool
    let firstIn: String
    let lastOut: String
    let pendingLeave: Int
    let openTickets: Int

    func isCurrent(at date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Colombo")!
        let age = date.timeIntervalSince(updatedAt)
        return age >= 0 && age < 8 * 60 * 60 && calendar.isDate(updatedAt, inSameDayAs: date)
    }
}

enum WidgetSummaryStore {
    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSummary.groupID) != nil
    }
    private static var defaults: UserDefaults? {
        guard isAvailable else { return nil }
        return UserDefaults(suiteName: WidgetSummary.groupID)
    }
    static func save(_ summary: WidgetSummary) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        defaults?.set(data, forKey: WidgetSummary.cacheKey)
    }
    static func load(at date: Date = Date()) -> WidgetSummary? {
        guard let data = defaults?.data(forKey: WidgetSummary.cacheKey),
              let summary = try? JSONDecoder().decode(WidgetSummary.self, from: data),
              summary.isCurrent(at: date) else { return nil }
        return summary
    }
    static func clear() { defaults?.removeObject(forKey: WidgetSummary.cacheKey) }
}
