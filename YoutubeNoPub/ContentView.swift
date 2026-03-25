import SwiftUI
import WebKit

struct ContentView: View {
    @State private var urls: [String] = []
    @State private var safariFullScreenURL: URL? = nil
    @State private var titles: [String: String] = [:]
    @AppStorage("colorSchemePreference") private var colorSchemePreference: Int = 0

    private var colorScheme: ColorScheme? {
        switch colorSchemePreference {
        case 1: return .dark
        case 2: return .light
        default: return nil
        }
    }

    let appGroup = "group.net.fenyo.apple.youtubenopub"

    var body: some View {
        NavigationView {
            Group {
                if urls.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "link.circle")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        Text("No shared URLs")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("Share a URL from YouTube or any app using the Share button")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else {
                    List {
                        ForEach(urls, id: \.self) { url in
                            VStack(alignment: .leading, spacing: 6) {
                                if let title = titles[url] {
                                    Text(title)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .lineLimit(2)
                                }
                                Text(url)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                if let link = URL(string: url) {
                                    Button("Open in Safari") {
                                        safariFullScreenURL = link
                                    }
                                    .font(.caption2)
                                }
                            }
                            .padding(.vertical, 4)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = url
                                } label: {
                                    Label("Copy URL", systemImage: "doc.on.doc")
                                }
                            }
                            .onAppear { fetchTitle(for: url) }
                        }
                        .onDelete(perform: deleteURLs)
                    }
                }
            }
            .navigationTitle("Shared URLs")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        colorSchemePreference = (colorSchemePreference + 1) % 3
                    } label: {
                        Image(systemName: colorSchemePreference == 1 ? "moon.fill" : colorSchemePreference == 2 ? "sun.max.fill" : "circle.lefthalf.filled")
                    }
                }
                if !urls.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        EditButton()
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Clear all", role: .destructive) {
                            clearAll()
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(colorScheme)
        .fullScreenCover(item: $safariFullScreenURL) { url in
            WebContainerView(url: url)
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

    private func fetchTitle(for urlString: String) {
        guard titles[urlString] == nil else { return }
        let youtubeURL = urlString.replacingOccurrences(of: "yout-ube.com", with: "youtube.com")
        guard let encoded = youtubeURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let oembedURL = URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json") else { return }
        URLSession.shared.dataTask(with: oembedURL) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = json["title"] as? String else { return }
            DispatchQueue.main.async { titles[urlString] = title }
        }.resume()
    }
}


class WebViewStore: ObservableObject {
    var webView: WKWebView?

    func reload() {
        webView?.reload()
    }
}

struct WebContainerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = WebViewStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                }
                Spacer()
                Button { store.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
            Divider()
            WebView(url: url, store: store)
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    let store: WebViewStore

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        store.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
