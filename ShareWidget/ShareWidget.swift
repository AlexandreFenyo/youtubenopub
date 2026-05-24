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
    /// Nom du folder de rangement de l'item (côté app principale).
    let folder: String?
    /// Dernière date de modification que l'utilisateur a "vue" — sert
    /// au calcul de l'état non-lu, identique à l'app principale.
    let lastSeenModifiedAt: Double?

    var displayTitle: String {
        title ?? URL(string: url)?.lastPathComponent ?? url
    }

    /// Reproduit la même logique que `isUnread(_:)` côté app
    /// principale : un item (de N'IMPORTE QUEL type) est non-lu si on
    /// a une `modifiedAt` connue et soit `lastSeenModifiedAt` nil, soit
    /// `modifiedAt` strictement plus récent que la dernière vue.
    var isUnread: Bool {
        guard let mod = modifiedAt else { return false }
        guard let seen = lastSeenModifiedAt else { return true }
        return mod > seen
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
        // 1. Le store partagé (ordre manuel de l'app, le plus récent en tête).
        var storeItems: [WidgetItem] = []
        if let defaults = UserDefaults(suiteName: appGroup),
           let data = defaults.data(forKey: "items"),
           let items = try? JSONDecoder().decode([WidgetItem].self, from: data) {
            storeItems = items
        }
        // 2. Les partages déposés par l'extension dans inbox/ mais pas encore
        //    drainés par l'app. L'extension n'écrit plus le store directement,
        //    donc sans cette lecture un partage frais n'apparaîtrait qu'après
        //    l'ouverture de l'app. On les place en tête (plus récents d'abord),
        //    comme le faisait l'ancien insert-at-0. Lecture tolérante : un
        //    fichier illisible / disparu (drain concurrent) est ignoré — l'item
        //    est alors déjà dans le store.
        var inboxItems: [WidgetItem] = []
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            let dir = container.appendingPathComponent("inbox", isDirectory: true)
            if let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) {
                for u in urls where u.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: u),
                          let item = try? JSONDecoder().decode(WidgetItem.self, from: data) else { continue }
                    inboxItems.append(item)
                }
            }
        }
        inboxItems.sort { $0.timestamp > $1.timestamp }

        // 3. Fusion inbox (en tête) + store, dédup par id (fenêtre de
        //    recouvrement pendant un drain), puis filtre « non lus » et cap 30.
        var seen = Set<String>()
        var merged: [WidgetItem] = []
        for it in inboxItems + storeItems where !seen.contains(it.id) {
            seen.insert(it.id)
            merged.append(it)
        }
        return Array(merged.filter { $0.isUnread }.prefix(30))
    }

    private func stubItems() -> [WidgetItem] {
        let now = Date().timeIntervalSince1970
        return [
            WidgetItem(id: "1", title: "Apple Newsroom", url: "https://www.apple.com/newsroom/",
                       kind: "url", timestamp: now, modifiedAt: now,
                       folder: "Default", lastSeenModifiedAt: nil),
            WidgetItem(id: "2", title: "Swift Blog", url: "https://swift.org/blog/",
                       kind: "url", timestamp: now, modifiedAt: now,
                       folder: "Default", lastSeenModifiedAt: nil),
            WidgetItem(id: "3", title: "WWDC", url: "https://developer.apple.com/wwdc/",
                       kind: "url", timestamp: now, modifiedAt: now,
                       folder: "Default", lastSeenModifiedAt: nil),
        ]
    }
}

// MARK: - Vue

struct ShareWidgetEntryView: View {
    let entry: ShareEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        // ZStack avec header EN OVERLAY au-dessus de la liste : le
        // header n'est plus jamais poussé hors écran par les items
        // (avec un VStack classique, SwiftUI dans un widget peut
        // compresser/déborder le premier enfant quand les suivants
        // demandent trop de place). La liste a son propre cadre, est
        // clippée, et démarre sous le header grâce à un padding-top
        // explicite équivalent à la hauteur du header.
        ZStack(alignment: .top) {
            // Couche items (en dessous, démarre sous la zone du header)
            Group {
                if entry.items.isEmpty {
                    VStack {
                        Spacer()
                        Text("No unread items")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                        Spacer()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
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
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity,
                           maxHeight: .infinity,
                           alignment: .topLeading)
                }
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()

            // Couche header (en haut, toujours visible)
            HStack {
                Image(systemName: "tray.full")
                    .foregroundColor(.blue)
                Text("Captured")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(entry.items.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .padding(10)
    }

    private var maxRows: Int {
        switch family {
        case .systemSmall:  return 3
        case .systemMedium: return 4
        case .systemLarge:  return 30
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
        .configurationDisplayName("Captured")
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
