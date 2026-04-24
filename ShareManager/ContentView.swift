import SwiftUI
import WebKit
import QuickLook

// MARK: - Data model

/// Entrée persistante pour une URL, un fichier ou du texte partagé.
/// Stocké sous forme de JSON dans l'UserDefaults du groupe d'app.
struct SharedItem: Codable, Identifiable, Hashable {
    let id: String
    /// Pour `kind == "url"` : la chaîne URL web.
    /// Pour `kind == "file"` : la chaîne `file://…` du fichier copié.
    /// Pour `kind == "text"` : le texte brut partagé.
    let url: String
    var title: String?
    var sourceApp: String?
    var folder: String
    let timestamp: Double
    /// "url", "file" ou "text". Optionnel pour compat avec d'anciens items :
    /// s'il est absent, `effectiveKind` le déduit à partir du schéma de `url`.
    var kind: String?
    /// Date de dernière modification (secondes epoch). Pour un fichier :
    /// la date d'attribut POSIX ; pour un texte : le moment du partage ;
    /// pour une URL : le `Last-Modified` HTTP une fois récupéré.
    /// Nil pour une URL pas encore interrogée.
    var modifiedAt: Double?

    var effectiveKind: String {
        if let k = kind { return k }
        if let u = URL(string: url) {
            if u.scheme == "http" || u.scheme == "https" { return "url" }
            if u.isFileURL { return "file" }
        }
        return "url"
    }
}

/// Identifiants de clés UserDefaults et valeurs réservées.
enum StoreKeys {
    static let items = "items"
    static let folders = "folders"
    static let selectedFolder = "selectedFolder"
    /// Identifiant interne du folder par défaut. Son nom d'affichage
    /// est localisé via `displayName(forFolder:)`.
    static let defaultFolder = "Default"
}

/// Renvoie le nom à afficher pour un folder. Le folder système « Default »
/// est localisé ; les folders créés par l'utilisateur gardent leur nom.
func displayName(forFolder name: String) -> String {
    if name == StoreKeys.defaultFolder {
        return String(localized: "Default")
    }
    return name
}

func colorSchemeName(_ value: Int) -> String {
    switch value {
    case 1: return String(localized: "Dark")
    case 2: return String(localized: "Light")
    default: return String(localized: "Automatic")
    }
}

// MARK: - Main View

struct ContentView: View {
    @State private var items: [SharedItem] = []
    @State private var folders: [String] = [StoreKeys.defaultFolder]
    @State private var selectedFolder: String? = StoreKeys.defaultFolder

    @State private var safariFullScreenURL: URL? = nil
    @State private var previewFileURL: URL? = nil
    @State private var textToPreview: TextPreviewPayload? = nil
    @State private var showDebugLogs = false
    @State private var debugLogs = ""
    @State private var lastLogSize: Int = 0

    @State private var themeAnnouncement: (old: Int, new: Int)? = nil
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var folderToDelete: String? = nil

    @State private var fetchingDateIDs: Set<String> = []
    @State private var refreshTask: Task<Void, Never>? = nil
    @State private var blinkPhase: Bool = false
    /// Passe à true après le tout premier `loadItems()` afin que l'auto-fetch
    /// ne se déclenche que pour les items apparus APRÈS le démarrage.
    @State private var hasInitialized: Bool = false

    @AppStorage("colorSchemePreference") private var colorSchemePreference: Int = 0
    @AppStorage("debugLogsEnabled", store: UserDefaults(suiteName: "group.net.fenyo.apple.sharemanager")) private var debugLogsEnabled = false
    /// Reflet du toggle de la Settings.bundle (Réglages iOS). Permet de
    /// piloter l'indicateur visuel sans lire UserDefaults à chaque render.
    @AppStorage("simulateDateDelay") private var simulateDateDelay: Bool = false

    let appGroup = "group.net.fenyo.apple.sharemanager"

    private var colorScheme: ColorScheme? {
        switch colorSchemePreference {
        case 1: return .dark
        case 2: return .light
        default: return nil
        }
    }

    private var currentFolder: String {
        selectedFolder ?? StoreKeys.defaultFolder
    }

    private var currentItems: [SharedItem] {
        items.filter { $0.folder == currentFolder }
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                detail
            }
        }
        .preferredColorScheme(colorScheme)
        .fullScreenCover(item: $safariFullScreenURL) { url in
            WebContainerView(url: url)
        }
        .fullScreenCover(item: $previewFileURL) { url in
            QuickLookPreview(url: url, onDismiss: { previewFileURL = nil })
        }
        .sheet(item: $textToPreview) { payload in
            TextPreviewView(text: payload.text, title: payload.title)
        }
        .sheet(isPresented: $showDebugLogs) { debugLogsSheet }
        .overlay(alignment: .top) { themeOverlay }
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") { createFolder() }
        }
        .alert(
            "Delete Folder",
            isPresented: Binding(
                get: { folderToDelete != nil },
                set: { if !$0 { folderToDelete = nil } }
            ),
            presenting: folderToDelete
        ) { name in
            Button("Delete", role: .destructive) { deleteFolder(name) }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Deleting this folder also deletes every item it contains.")
        }
        .onAppear {
            loadFolders()
            loadSelectedFolder()
            loadItems()
            // Lance automatiquement l'actualisation batch des dates URL au
            // démarrage. Le bouton du menu « … » reflète l'état en cours.
            if refreshTask == nil && hasURLItems {
                refreshTask = Task { @MainActor in
                    await refreshAllURLDates()
                    refreshTask = nil
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            loadItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            loadItems()
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            loadItems()
            if debugLogsEnabled { loadDebugLogs() }
        }
        .onReceive(Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()) { _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                blinkPhase.toggle()
            }
        }
        .onChange(of: selectedFolder) { _, newValue in
            if let newValue {
                UserDefaults(suiteName: appGroup)?.set(newValue, forKey: StoreKeys.selectedFolder)
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedFolder) {
            ForEach(folders, id: \.self) { folder in
                HStack {
                    Image(systemName: folder == StoreKeys.defaultFolder ? "tray.fill" : "folder")
                    Text(displayName(forFolder: folder))
                    Spacer()
                    Text("\(items.filter { $0.folder == folder }.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                .tag(folder)
                .contextMenu {
                    if folder != StoreKeys.defaultFolder {
                        Button(role: .destructive) {
                            folderToDelete = folder
                        } label: {
                            Label("Delete Folder", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Folders")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newFolderName = ""
                    showNewFolderAlert = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            if currentItems.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(currentItems) { item in
                        itemRow(item)
                    }
                    .onDelete(perform: deleteItems)
                }
                .refreshable {
                    await pullToRefreshDates()
                }
            }
        }
        .navigationTitle(displayName(forFolder: currentFolder))
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    changeColorSchemePreference()
                } label: {
                    Image(systemName: colorSchemePreference == 1 ? "moon.fill" : colorSchemePreference == 2 ? "sun.max.fill" : "circle.lefthalf.filled")
                }
            }
            if !currentItems.isEmpty {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                settingsMenu
            }
            if !currentItems.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        clearFolder()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "link.circle")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("No shared URLs or items")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("This app stores URLs and items you share from other apps using the Share button")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var hasURLItems: Bool {
        items.contains { $0.effectiveKind == "url" }
    }

    private var settingsMenu: some View {
        Menu {
            if hasURLItems {
                Button {
                    toggleRefreshAllDates()
                } label: {
                    if refreshTask == nil {
                        Label("Refresh dates", systemImage: "arrow.clockwise")
                    } else {
                        Label("Stop refreshing dates", systemImage: "stop.circle")
                    }
                }
                Divider()
            }
            Toggle(isOn: $debugLogsEnabled) {
                Label("Enable Debug Logs", systemImage: "ladybug")
            }
            if debugLogsEnabled {
                Button {
                    loadDebugLogs()
                    showDebugLogs = true
                } label: {
                    Label("View Logs", systemImage: "doc.text.magnifyingglass")
                }
                Button(role: .destructive) {
                    clearDebugLogs()
                } label: {
                    Label("Clear Logs", systemImage: "trash")
                }
                Divider()
            }
            Button {
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL)
                }
            } label: {
                Label("Open iOS Settings", systemImage: "gear")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private func itemRow(_ item: SharedItem) -> some View {
        let kind = item.effectiveKind
        let linkURL = URL(string: item.url)

        VStack(alignment: .leading, spacing: 6) {
            switch kind {
            case "file":
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .foregroundColor(.blue)
                    Text(item.title ?? linkURL?.lastPathComponent ?? item.url)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                }
            case "text":
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .foregroundColor(.orange)
                    Text(item.title ?? String(item.url.prefix(80)))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                }
                Text(textFirstLinePreview(item.url))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            default: // "url"
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "globe")
                        .foregroundColor(Color(red: 0, green: 0.45, blue: 0.2))
                    Text(item.title ?? item.url)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                }
                if item.title != nil {
                    Text(item.url)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            if let sourceApp = item.sourceApp {
                HStack(spacing: 4) {
                    Image(systemName: "app.badge")
                        .font(.caption2)
                    Text("From: \(sourceApp)")
                        .font(.caption2)
                }
                .foregroundColor(.blue)
                .padding(.top, 2)
            }

            dateRow(for: item)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            switch kind {
            case "file":
                if let link = linkURL { previewFileURL = link }
            case "text":
                textToPreview = TextPreviewPayload(text: item.url, title: item.title)
            default:
                if let link = linkURL { safariFullScreenURL = link }
            }
        }
        .contextMenu {
            if kind == "url" {
                Button {
                    UIPasteboard.general.string = item.url
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
            } else if kind == "text" {
                Button {
                    UIPasteboard.general.string = item.url
                } label: {
                    Label("Copy text", systemImage: "doc.on.doc")
                }
            }
            if folders.count > 1 {
                Menu {
                    ForEach(folders, id: \.self) { folder in
                        if folder != item.folder {
                            Button {
                                moveItem(item, to: folder)
                            } label: {
                                Label(displayName(forFolder: folder), systemImage: folder == StoreKeys.defaultFolder ? "tray" : "folder")
                            }
                        }
                    }
                } label: {
                    Label("Move to…", systemImage: "folder")
                }
            }
        }
        .onAppear {
            if kind == "url" {
                fetchTitle(for: item)
            }
        }
    }

    // MARK: - Theme overlay

    @ViewBuilder
    private var themeOverlay: some View {
        if let a = themeAnnouncement {
            HStack(spacing: 10) {
                Text(colorSchemeName(a.old))
                    .foregroundColor(.secondary)
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                Text(colorSchemeName(a.new))
                    .fontWeight(.semibold)
            }
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 12)
            .padding(.top, 20)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func changeColorSchemePreference() {
        let old = colorSchemePreference
        let new = (old + 1) % 3
        colorSchemePreference = new
        withAnimation(.spring(duration: 0.25)) {
            themeAnnouncement = (old, new)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeInOut(duration: 0.3)) {
                themeAnnouncement = nil
            }
        }
    }

    // MARK: - Debug logs sheet

    private var debugLogsSheet: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    if debugLogsEnabled {
                        Button("Clear Logs") {
                            clearDebugLogs()
                            loadDebugLogs()
                        }
                        .buttonStyle(.bordered)
                    }
                    Divider()
                    Group {
                        if debugLogs.isEmpty {
                            if debugLogsEnabled {
                                Text("No debug logs yet.\nShare a URL to see logs appear here.")
                            } else {
                                Text("Debug logs are disabled.")
                            }
                        } else {
                            Text(debugLogs)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("Debug Logs")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showDebugLogs = false }
                }
            }
        }
    }

    // MARK: - Persistence

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    private func loadItems() {
        guard let defaults else { return }

        // Migration unique depuis l'ancien format
        if defaults.data(forKey: StoreKeys.items) == nil,
           let oldURLs = defaults.stringArray(forKey: "sharedURLs"), !oldURLs.isEmpty {
            let oldSources = defaults.dictionary(forKey: "sourceApps") as? [String: String] ?? [:]
            let oldTitles = defaults.dictionary(forKey: "pageTitles") as? [String: String] ?? [:]
            let migrated: [SharedItem] = oldURLs.map { u in
                SharedItem(
                    id: UUID().uuidString,
                    url: u,
                    title: oldTitles[u],
                    sourceApp: oldSources[u],
                    folder: StoreKeys.defaultFolder,
                    timestamp: Date().timeIntervalSince1970
                )
            }
            saveItems(migrated)
            defaults.removeObject(forKey: "sharedURLs")
            defaults.removeObject(forKey: "sourceApps")
            defaults.removeObject(forKey: "pageTitles")
        }

        guard let data = defaults.data(forKey: StoreKeys.items),
              let loaded = try? JSONDecoder().decode([SharedItem].self, from: data) else {
            if !items.isEmpty { items = [] }
            if !hasInitialized { hasInitialized = true }
            return
        }

        let previousIDs = Set(items.map(\.id))

        if loaded != items { items = loaded }

        // Auto-fetch uniquement pour les URLs nouvellement apparues APRÈS le
        // premier chargement (items freshly partagés pendant que l'app tourne).
        // Aucun fetch au tout premier loadItems (= démarrage).
        if hasInitialized {
            for item in loaded where !previousIDs.contains(item.id)
                                     && item.effectiveKind == "url"
                                     && item.modifiedAt == nil
                                     && !fetchingDateIDs.contains(item.id) {
                startFetchLastModified(for: item)
            }
        } else {
            hasInitialized = true
        }
    }

    private func saveItems(_ newItems: [SharedItem]? = nil) {
        let toSave = newItems ?? items
        guard let defaults, let data = try? JSONEncoder().encode(toSave) else { return }
        defaults.set(data, forKey: StoreKeys.items)
    }

    private func loadFolders() {
        let list = defaults?.stringArray(forKey: StoreKeys.folders) ?? []
        let sanitized = list.isEmpty ? [StoreKeys.defaultFolder] : list
        let final = sanitized.contains(StoreKeys.defaultFolder) ? sanitized : [StoreKeys.defaultFolder] + sanitized
        if final != folders { folders = final }
    }

    private func saveFolders() {
        defaults?.set(folders, forKey: StoreKeys.folders)
    }

    private func loadSelectedFolder() {
        if let saved = defaults?.string(forKey: StoreKeys.selectedFolder), folders.contains(saved) {
            selectedFolder = saved
        } else {
            selectedFolder = StoreKeys.defaultFolder
        }
    }

    // MARK: - Folder CRUD

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !trimmed.isEmpty else { return }
        guard trimmed != StoreKeys.defaultFolder else { return }
        guard !folders.contains(trimmed) else { return }
        folders.append(trimmed)
        saveFolders()
        selectedFolder = trimmed
    }

    private func deleteFolder(_ name: String) {
        guard name != StoreKeys.defaultFolder else { return }
        // Supprime les items de ce folder (et les fichiers sur disque le cas échéant)
        let removed = items.filter { $0.folder == name }
        removed.forEach { removeFileIfLocal($0.url) }
        items.removeAll { $0.folder == name }
        folders.removeAll { $0 == name }
        saveItems()
        saveFolders()
        if selectedFolder == name {
            selectedFolder = StoreKeys.defaultFolder
        }
    }

    // MARK: - Item CRUD

    private func deleteItems(at offsets: IndexSet) {
        let removedItems = offsets.map { currentItems[$0] }
        removedItems.forEach { removeFileIfLocal($0.url) }
        let removedIDs = Set(removedItems.map(\.id))
        items.removeAll { removedIDs.contains($0.id) }
        saveItems()
    }

    private func clearFolder() {
        let removedItems = items.filter { $0.folder == currentFolder }
        removedItems.forEach { removeFileIfLocal($0.url) }
        items.removeAll { $0.folder == currentFolder }
        saveItems()
    }

    private func moveItem(_ item: SharedItem, to folder: String) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].folder = folder
        saveItems()
    }

    private func removeFileIfLocal(_ urlString: String) {
        guard let url = URL(string: urlString), url.isFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Renvoie la première ligne d'un texte, suffixée par "…" si le texte
    /// original contient plus d'une ligne. La troncature horizontale reste
    /// gérée par SwiftUI via `lineLimit(1) + truncationMode(.tail)`.
    private func textFirstLinePreview(_ text: String) -> String {
        if let nlIndex = text.firstIndex(where: { $0.isNewline }) {
            return String(text[..<nlIndex]) + "…"
        }
        return text
    }

    // MARK: - Date row & modification date fetching

    @ViewBuilder
    private func dateRow(for item: SharedItem) -> some View {
        let fetching = fetchingDateIDs.contains(item.id)
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.caption2)
            if simulateDateDelay && item.effectiveKind == "url" {
                Image(systemName: "hourglass")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            if fetching {
                Text("Fetching date…")
                    .font(.caption2)
                    .opacity(blinkPhase ? 1.0 : 0.35)
            } else if let d = item.modifiedAt {
                Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: d)))
                    .font(.caption2)
            } else {
                // URL jamais interrogée et pas en cours : on affiche quand même
                // une ligne (placeholder clignotant) pour garder un layout stable.
                Text("Fetching date…")
                    .font(.caption2)
                    .opacity(blinkPhase ? 1.0 : 0.35)
            }
        }
        .foregroundColor(.secondary)
    }

    static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }()

    private func startFetchLastModified(for item: SharedItem) {
        fetchingDateIDs.insert(item.id)
        let id = item.id
        let urlString = item.url
        let shareTimestamp = item.timestamp
        Task.detached(priority: .utility) {
            let date = await Self.fetchLastModified(urlString: urlString)
            await MainActor.run {
                fetchingDateIDs.remove(id)
                if let date {
                    updateItemModifiedAt(id: id, to: date)
                } else {
                    // Échec du fetch initial (timeout, 4xx/5xx, pas de header
                    // Last-Modified) : on se rabat sur la date de partage pour
                    // stopper le clignotement. L'utilisateur peut retenter via
                    // « Refresh dates » dans le menu …
                    updateItemModifiedAt(id: id, to: Date(timeIntervalSince1970: shareTimestamp))
                }
            }
        }
    }

    private func updateItemModifiedAt(id: String, to date: Date) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].modifiedAt = date.timeIntervalSince1970
        saveItems()
    }

    static func fetchLastModified(urlString: String) async -> Date? {
        guard let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https" else { return nil }

        let timeout: TimeInterval = 10
        let start = Date()

        // Option debug (iOS Settings → app → Simulate random date fetch delays)
        // Tire un délai dans [0, 2*timeout]. Si > timeout → on simule un
        // timeout (on attend timeout puis on abandonne). Sinon on dort ce
        // délai puis on lance la requête avec le reliquat comme timeout.
        if UserDefaults.standard.bool(forKey: "simulateDateDelay") {
            let randomDelay = Double.random(in: 0...(2 * timeout))
            if randomDelay > timeout {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            try? await Task.sleep(nanoseconds: UInt64(randomDelay * 1_000_000_000))
        }

        if Task.isCancelled { return nil }

        let elapsed = Date().timeIntervalSince(start)
        let remaining = timeout - elapsed
        if remaining <= 0 { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = remaining
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  let lastMod = http.value(forHTTPHeaderField: "Last-Modified") else {
                return nil
            }
            return parseHTTPDate(lastMod)
        } catch {
            return nil
        }
    }

    static func parseHTTPDate(_ s: String) -> Date? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",  // RFC 7231
            "EEEE, dd-MMM-yy HH:mm:ss zzz",   // RFC 850
            "EEE MMM d HH:mm:ss yyyy",        // asctime
        ]
        for fmt in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "GMT")
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    // MARK: - Batch refresh

    /// Handler pour le pull-to-refresh de la liste. Se comporte comme le
    /// bouton « Refresh dates » du menu : lance un batch refresh si aucun
    /// n'est en cours, sinon attend celui en cours. Dans les deux cas le
    /// spinner de pull-to-refresh reste affiché jusqu'à la fin.
    @MainActor
    private func pullToRefreshDates() async {
        if let existing = refreshTask {
            await existing.value
            return
        }
        guard hasURLItems else { return }
        let task = Task { @MainActor in
            await refreshAllURLDates()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func toggleRefreshAllDates() {
        if let task = refreshTask {
            task.cancel()
            refreshTask = nil
            // Nettoyer les marqueurs fetching restants
            fetchingDateIDs.removeAll()
        } else {
            refreshTask = Task { @MainActor in
                await refreshAllURLDates()
                refreshTask = nil
            }
        }
    }

    @MainActor
    private func refreshAllURLDates() async {
        // Snapshot des URLs au moment du lancement.
        let urlItems = items.filter { $0.effectiveKind == "url" }
        for chunk in urlItems.chunked(into: 4) {
            if Task.isCancelled { break }
            // Marque tout le chunk comme « en cours »
            for it in chunk { fetchingDateIDs.insert(it.id) }
            await withTaskGroup(of: (String, Date?).self) { group in
                for it in chunk {
                    let id = it.id
                    let urlString = it.url
                    group.addTask {
                        let d = await Self.fetchLastModified(urlString: urlString)
                        return (id, d)
                    }
                }
                for await (id, maybeDate) in group {
                    fetchingDateIDs.remove(id)
                    if let maybeDate {
                        updateItemModifiedAt(id: id, to: maybeDate)
                    }
                    // Échec → on laisse l'ancienne valeur (modifiedAt inchangé)
                }
            }
        }
    }

    // MARK: - Title fetching

    private func fetchTitle(for item: SharedItem) {
        guard item.title == nil || item.title?.isEmpty == true,
              let url = URL(string: item.url),
              url.scheme == "http" || url.scheme == "https" else { return }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let html = String(data: data, encoding: .utf8),
                  let match = html.range(of: "<title[^>]*>([^<]+)</title>", options: .regularExpression) else { return }
            let tag = html[match]
            guard let start = tag.firstIndex(of: ">"), let end = tag.range(of: "</title>") else { return }
            let title = tag[tag.index(after: start)..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                DispatchQueue.main.async {
                    updateItemTitle(id: item.id, to: String(title))
                }
            }
        }.resume()
    }

    private func updateItemTitle(id: String, to title: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].title = title
        saveItems()
    }

    // MARK: - Debug logs

    private func loadDebugLogs() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            debugLogs = "❌ Cannot access app group container"
            return
        }
        let logFileURL = containerURL.appendingPathComponent("extension_debug.log")

        guard let data = try? Data(contentsOf: logFileURL) else {
            debugLogs = debugLogsEnabled
                ? String(localized: "No logs found yet.\nShare a URL from YouTube to generate logs.")
                : String(localized: "Debug logs are disabled.")
            lastLogSize = 0
            return
        }

        if data.count > lastLogSize {
            let newBytes = data.subdata(in: lastLogSize..<data.count)
            if let newString = String(data: newBytes, encoding: .utf8) {
                print(newString, terminator: "")
            }
        } else if data.count < lastLogSize {
            if let allString = String(data: data, encoding: .utf8) {
                print(allString, terminator: "")
            }
        }
        lastLogSize = data.count

        if let allString = String(data: data, encoding: .utf8) {
            debugLogs = allString
        }
    }

    private func clearDebugLogs() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return }
        let logFileURL = containerURL.appendingPathComponent("extension_debug.log")
        try? FileManager.default.removeItem(at: logFileURL)
        lastLogSize = 0
    }
}

// MARK: - Web view container

class WebViewStore: ObservableObject {
    var webView: WKWebView?
    func reload() { webView?.reload() }
}

struct WebContainerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var store = WebViewStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                }
                Spacer()
                Button {
                    openURL(url)
                    dismiss()
                } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .accessibilityLabel(Text("Open in Safari"))
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

extension Array {
    /// Découpe le tableau en sous-tableaux de taille `size` maximum.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

/// Payload pour la feuille de prévisualisation texte.
struct TextPreviewPayload: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let title: String?
}

/// Feuille modale affichant le contenu texte brut, avec bouton « Copier ».
struct TextPreviewView: View {
    let text: String
    let title: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(title ?? String(localized: "Text"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel(Text("Copy text"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Prévisualisation iOS (QuickLook) encapsulée pour SwiftUI.
/// Bouton « Done » en haut à droite qui déclenche `onDismiss`.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.doneTapped)
        )
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let parent: QuickLookPreview
        init(_ parent: QuickLookPreview) { self.parent = parent }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            parent.url as NSURL
        }

        @objc func doneTapped() { parent.onDismiss() }
    }
}
