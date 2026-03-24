import SwiftUI
import SafariServices

struct ContentView: View {
    @State private var urls: [String] = []
    @State private var safariURL: URL? = nil

    let appGroup = "group.net.fenyo.apple.youtubenopub"

    var body: some View {
        NavigationView {
            Group {
                if urls.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "link.circle")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        Text("Aucune URL partagée")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("Partagez une URL depuis YouTube ou n'importe quelle app via le bouton Partager")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else {
                    List {
                        ForEach(urls, id: \.self) { url in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(url)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                    .lineLimit(3)
                                if let link = URL(string: url) {
                                    Button("Open in Safari") {
                                        safariURL = link
                                    }
                                    .font(.caption2)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete(perform: deleteURLs)
                    }
                }
            }
            .navigationTitle("URLs partagées")
            .toolbar {
                if !urls.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        EditButton()
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Tout effacer", role: .destructive) {
                            clearAll()
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(item: $safariURL) { url in
            SafariView(url: url)
        }
        .onAppear(perform: loadURLs)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            loadURLs()
        }
    }

    private func loadURLs() {
        let defaults = UserDefaults(suiteName: appGroup)
        urls = defaults?.stringArray(forKey: "sharedURLs") ?? []
    }

    private func deleteURLs(at offsets: IndexSet) {
        urls.remove(atOffsets: offsets)
        saveURLs()
    }

    private func clearAll() {
        urls = []
        saveURLs()
    }

    private func saveURLs() {
        let defaults = UserDefaults(suiteName: appGroup)
        defaults?.set(urls, forKey: "sharedURLs")
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
