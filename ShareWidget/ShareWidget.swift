import WidgetKit
import SwiftUI

// MARK: - Décodeur partiel

/// Sous-ensemble de SharedItem suffisant pour l'affichage du widget. On
/// décode uniquement ce qu'on affiche pour rester léger.
struct WidgetItem: Decodable, Identifiable {
    let id: String
    let title: String?
    let url: String
    let kind: String?
    let timestamp: Double
    let modifiedAt: Double?

    var displayTitle: String {
        title ?? URL(string: url)?.lastPathComponent ?? url
    }

    var effectiveKind: String {
        if let k = kind { return k }
        if let u = URL(string: url) {
            if u.scheme == "http" || u.scheme == "https" { return "url" }
            if u.isFileURL { return "file" }
        }
        return "url"
    }
}

// MARK: - Provider

private let appGroup = "group.net.fenyo.apple.sharemanager"

struct ShareEntry: TimelineEntry {
    let date: Date
    let items: [WidgetItem]
}

struct ShareTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShareEntry {
        ShareEntry(date: Date(), items: stubItems())
    }

    func getSnapshot(in context: Context, completion: @escaping (ShareEntry) -> Void) {
        completion(ShareEntry(date: Date(), items: loadRecentItems()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ShareEntry>) -> Void) {
        let entry = ShareEntry(date: Date(), items: loadRecentItems())
        // Refresh toutes les 15 minutes (iOS peut espacer plus loin selon
        // les budgets WidgetKit).
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadRecentItems() -> [WidgetItem] {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = defaults.data(forKey: "items"),
              let items = try? JSONDecoder().decode([WidgetItem].self, from: data) else {
            return []
        }
        return Array(items.prefix(8))
    }

    private func stubItems() -> [WidgetItem] {
        [
            WidgetItem(id: "1", title: "Apple", url: "https://www.apple.com", kind: "url",
                       timestamp: Date().timeIntervalSince1970, modifiedAt: nil),
            WidgetItem(id: "2", title: "vacation.jpg", url: "file:///tmp/vacation.jpg",
                       kind: "photo", timestamp: Date().timeIntervalSince1970, modifiedAt: nil),
            WidgetItem(id: "3", title: "Quick note", url: "Lorem ipsum", kind: "text",
                       timestamp: Date().timeIntervalSince1970, modifiedAt: nil),
        ]
    }
}

// MARK: - Vue

struct ShareWidgetEntryView: View {
    let entry: ShareEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "tray.full")
                    .foregroundColor(.blue)
                Text("ShareManager")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(entry.items.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            if entry.items.isEmpty {
                Spacer()
                Text("No shared items")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ForEach(entry.items.prefix(maxRows)) { item in
                    HStack(spacing: 6) {
                        Image(systemName: icon(item.effectiveKind))
                            .foregroundColor(color(item.effectiveKind))
                            .font(.caption2)
                        Text(item.displayTitle)
                            .font(.caption2)
                            .lineLimit(1)
                        Spacer()
                    }
                }
                Spacer()
            }
        }
        .padding(10)
    }

    private var maxRows: Int {
        switch family {
        case .systemSmall:  return 3
        case .systemMedium: return 4
        case .systemLarge:  return 8
        default:            return 3
        }
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "file":  return "doc.fill"
        case "photo": return "photo.fill"
        case "video": return "video.fill"
        case "audio": return "waveform"
        case "text":  return "text.alignleft"
        default:      return "globe"
        }
    }

    private func color(_ kind: String) -> Color {
        switch kind {
        case "file":  return .blue
        case "photo": return .indigo
        case "video": return .red
        case "audio": return .teal
        case "text":  return .orange
        default:      return .green
        }
    }
}

// MARK: - Widget definition

struct ShareWidget: Widget {
    let kind: String = "ShareWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ShareTimelineProvider()) { entry in
            ShareWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("ShareManager")
        .description("Recent shared items")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct ShareWidgetBundle: WidgetBundle {
    var body: some Widget {
        ShareWidget()
    }
}
