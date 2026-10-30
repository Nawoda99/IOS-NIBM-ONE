import SwiftUI
import WidgetKit

struct SummaryEntry: TimelineEntry {
    let date: Date
    let summary: WidgetSummary?
}

struct SummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SummaryEntry { SummaryEntry(date: Date(), summary: nil) }
    func getSnapshot(in context: Context, completion: @escaping (SummaryEntry) -> Void) {
        completion(SummaryEntry(date: Date(), summary: WidgetSummaryStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SummaryEntry>) -> Void) {
        let now = Date(), summary = WidgetSummaryStore.load()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Colombo")!
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let expiry = min(midnight, summary?.updatedAt.addingTimeInterval(8 * 60 * 60) ?? midnight)
        let entries = [SummaryEntry(date: now, summary: summary), SummaryEntry(date: expiry, summary: nil)]
        completion(Timeline(entries: entries, policy: .after(min(now.addingTimeInterval(15 * 60), expiry))))
    }
}

struct SummaryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SummaryEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("NIBM ONE", systemImage: "building.2.fill").font(.caption.bold())
                Spacer()
                if entry.summary?.isDemo == true { Text("DEMO").font(.caption2.bold()) }
            }
            if let summary = entry.summary {
                HStack(alignment: .top, spacing: 14) {
                    Link(destination: URL(string: "nibmone://attendance")!) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Today").font(.caption).foregroundStyle(.secondary)
                            Text("IN  \(summary.firstIn)")
                            Text("OUT  \(summary.lastOut)")
                        }.font(.subheadline.monospacedDigit().bold())
                    }
                    if family == .systemMedium {
                        Spacer(minLength: 0)
                        Link(destination: URL(string: "nibmone://leave")!) {
                            metric("Leave pending", value: summary.pendingLeave, icon: "doc.text")
                        }
                        Link(destination: URL(string: "nibmone://tickets")!) {
                            metric("Open tickets", value: summary.openTickets, icon: "wrench.and.screwdriver")
                        }
                    }
                }.privacySensitive()
                Text("Updated \(summary.updatedAt, style: .time)").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Open the app to sign in and refresh today’s summary.").font(.subheadline)
                Text("Attendance · Leave · Tickets").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "nibmone://attendance"))
    }
    private func metric(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon)
            Text(value.formatted()).font(.title2.bold())
            Text(title).font(.caption2)
        }
    }
}

@main
struct NIBMOneWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSummary.kind, provider: SummaryProvider()) { SummaryWidgetView(entry: $0) }
            .configurationDisplayName("NIBM ONE summary")
            .description("Today’s first IN and last OUT, pending leave and open tickets. Updated when you refresh the app.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
