import SwiftUI
import WebKit
import QuickLook
import CoreLocation
import Vision
import UniformTypeIdentifiers
import CoreSpotlight
#if canImport(Translation)
import Translation
#endif

// MARK: - Data model

/// Entrée persistante pour une URL, un fichier ou du texte partagé.
/// Stocké sous forme de JSON dans l'UserDefaults du groupe d'app.
struct SharedItem: Codable, Identifiable, Hashable {
    let id: String
    /// Pour `kind == "url"` : la chaîne URL web.
    /// Pour `kind == "file"` : la chaîne `file://…` du fichier copié.
    /// Pour `kind == "text"` : le texte brut partagé.
    var url: String
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
    /// Métadonnées GPS EXIF (photos uniquement).
    var latitude: Double?
    var longitude: Double?
    /// Nom de lieu résolu via CLGeocoder. Nil tant que la résolution n'a
    /// pas eu lieu. "" (vide) indique une résolution tentée sans succès.
    var placeName: String?
    /// Vrai si une tentative de description IA de la photo a été faite
    /// (succès ou échec). Bloque les retentatives automatiques.
    var aiDescribed: Bool?
    /// Dernière valeur de `modifiedAt` que l'utilisateur a "vu" (= a
    /// ouvert après cette date). Permet de mettre le titre en gras tant que
    /// `modifiedAt > lastSeenModifiedAt` (ou que `lastSeenModifiedAt` est nil
    /// et qu'on a déjà une date). S'applique aux URLs uniquement.
    var lastSeenModifiedAt: Double?
    /// URL telle que partagée par l'utilisateur, avant toute transformation
    /// (ex. youtube.com → yout-ube.com pour la lecture sans pub). Nil si
    /// aucune transformation n'a été appliquée. Affichage = `originalURL ?? url`,
    /// ouverture = `url`.
    var originalURL: String?
    /// Note libre saisie par l'utilisateur (édition via menu contextuel).
    var note: String?
    /// Vrai si une tentative d'OCR a été effectuée sur la photo (succès
    /// ou échec). Bloque les retentatives automatiques.
    var ocrDone: Bool?

    var effectiveKind: String {
        if let k = kind { return k }
        if let u = URL(string: url) {
            if u.scheme == "http" || u.scheme == "https" { return "url" }
            if u.isFileURL { return "file" }
        }
        return "url"
    }
}

/// Format d'export/import complet de l'app : items, folders, settings,
/// et binaires des fichiers/photos/vidéos en base64. Auto-suffisant pour
/// restaurer l'état sur un autre appareil.
struct BackupBundle: Codable {
    let schemaVersion: Int
    let exportedAt: Double
    var settings: Settings
    var folders: [String]
    var items: [SharedItem]
    /// Binaires des items file/photo/video, indexés par `SharedItem.id`.
    var files: [String: FileBlob]

    struct Settings: Codable {
        var colorSchemePreference: Int
        var debugLogsEnabled: Bool
        var describeImagesEnabled: Bool
        var describeImagesProvider: String
        var describeImagesAPIKey: String
        var describeImagesModel: String
        var simulateDateDelay: Bool
        var selectedFolder: String
    }

    struct FileBlob: Codable {
        let filename: String
        let base64: String
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
    @State private var geocodingIDs: Set<String> = []
    @State private var describingIDs: Set<String> = []
    @State private var editingItem: SharedItem? = nil
    @State private var pendingLabelTranslations: [LabelTranslationJob] = []

    @State private var backupShareURL: URL? = nil
    @State private var showBackupImporter: Bool = false
    @State private var pendingImport: BackupBundle? = nil
    @State private var importErrorMessage: String? = nil
    @State private var showClearConfirmation: Bool = false

    @State private var searchQuery: String = ""
    @State private var typeFilter: String = "all"
    @State private var sortOrder: SortOrder = .insertion
    @State private var selection: Set<String> = []
    @State private var clipboardCandidate: URL? = nil
    @State private var clipboardLastChangeCount: Int = 0
    @State private var editingNoteItem: SharedItem? = nil
    @State private var smartFolder: SmartFolder? = nil

    enum SortOrder: String, CaseIterable, Identifiable {
        case insertion, dateNewest, dateOldest, titleAZ, sourceAZ
        var id: String { rawValue }
        var label: String {
            switch self {
            case .insertion:  return String(localized: "Manual order")
            case .dateNewest: return String(localized: "Newest first")
            case .dateOldest: return String(localized: "Oldest first")
            case .titleAZ:    return String(localized: "Title A→Z")
            case .sourceAZ:   return String(localized: "Source A→Z")
            }
        }
    }

    enum SmartFolder: String, CaseIterable, Identifiable {
        case all, recent7days, unreadURLs, withLocation, photosOnly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:          return String(localized: "All items")
            case .recent7days:  return String(localized: "Recent (7 days)")
            case .unreadURLs:   return String(localized: "Unread URLs")
            case .withLocation: return String(localized: "With location")
            case .photosOnly:   return String(localized: "Photos only")
            }
        }
        var systemImage: String {
            switch self {
            case .all:          return "tray.full"
            case .recent7days:  return "clock.arrow.circlepath"
            case .unreadURLs:   return "circle.fill"
            case .withLocation: return "mappin.and.ellipse"
            case .photosOnly:   return "photo"
            }
        }
    }
    /// Passe à true après le tout premier `loadItems()` afin que l'auto-fetch
    /// ne se déclenche que pour les items apparus APRÈS le démarrage.
    @State private var hasInitialized: Bool = false

    @AppStorage("colorSchemePreference") private var colorSchemePreference: Int = 0
    @AppStorage("debugLogsEnabled", store: UserDefaults(suiteName: "group.net.fenyo.apple.sharemanager")) private var debugLogsEnabled = false

    /// Lit *à chaque render* la valeur écrite par la Settings.bundle dans
    /// UserDefaults.standard. On évite `@AppStorage` qui peut conserver une
    /// valeur stale quand la modif vient d'un autre process (Réglages iOS).
    /// Le timer à 100 ms fournit une re-évaluation suffisamment fréquente.
    private var simulateDateDelay: Bool {
        UserDefaults.standard.bool(forKey: "simulateDateDelay")
    }

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

    /// Lit la sélection sidebar pour distinguer smart folder vs folder normal.
    private func resolveSelection(_ raw: String?) -> (smart: SmartFolder?, folder: String?) {
        guard let raw else { return (nil, nil) }
        if raw.hasPrefix("smart:") {
            let key = String(raw.dropFirst("smart:".count))
            return (SmartFolder(rawValue: key), nil)
        }
        return (nil, raw)
    }

    private var currentItems: [SharedItem] {
        var result: [SharedItem]
        // 1. Smart folder ou folder utilisateur
        if let sf = smartFolder {
            switch sf {
            case .all:
                result = items
            case .recent7days:
                let cutoff = Date().timeIntervalSince1970 - 7 * 86400
                result = items.filter { $0.timestamp >= cutoff }
            case .unreadURLs:
                result = items.filter { isUnread($0) }
            case .withLocation:
                result = items.filter { $0.latitude != nil && $0.longitude != nil }
            case .photosOnly:
                result = items.filter { $0.effectiveKind == "photo" }
            }
        } else {
            result = items.filter { $0.folder == currentFolder }
        }
        // 2. Filtre par type d'item
        if typeFilter != "all" {
            result = result.filter { $0.effectiveKind == typeFilter }
        }
        // 3. Recherche full-text
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter { item in
                let bag = [
                    item.title,
                    item.url,
                    item.originalURL,
                    item.sourceApp,
                    item.placeName,
                    item.note,
                ].compactMap { $0 }.joined(separator: "\n").lowercased()
                return bag.contains(query)
            }
        }
        // 4. Tri
        switch sortOrder {
        case .insertion:
            break
        case .dateNewest:
            result.sort { ($0.modifiedAt ?? $0.timestamp) > ($1.modifiedAt ?? $1.timestamp) }
        case .dateOldest:
            result.sort { ($0.modifiedAt ?? $0.timestamp) < ($1.modifiedAt ?? $1.timestamp) }
        case .titleAZ:
            result.sort { ($0.title ?? $0.url).localizedCaseInsensitiveCompare($1.title ?? $1.url) == .orderedAscending }
        case .sourceAZ:
            result.sort { ($0.sourceApp ?? "").localizedCaseInsensitiveCompare($1.sourceApp ?? "") == .orderedAscending }
        }
        return result
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
        .sheet(item: $editingItem) { item in
            EditTitleView(initialTitle: item.title ?? "") { newTitle in
                updateItemTitle(id: item.id, to: newTitle)
            }
        }
        .sheet(item: $editingNoteItem) { item in
            EditNoteView(initialNote: item.note ?? "") { newNote in
                updateItemNote(id: item.id, to: newNote)
            }
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
            checkClipboardForURL()
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
            checkClipboardForURL()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            loadItems()
            checkClipboardForURL()
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
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
               let item = items.first(where: { $0.id == id }) {
                selectedFolder = item.folder
                switch item.effectiveKind {
                case "file", "photo", "video", "audio":
                    if let u = URL(string: item.url) { previewFileURL = u }
                case "text":
                    textToPreview = TextPreviewPayload(text: item.url, title: item.title)
                default:
                    if let u = URL(string: item.url) { safariFullScreenURL = u }
                }
            }
        }
        .onChange(of: selectedFolder) { _, newValue in
            let resolved = resolveSelection(newValue)
            smartFolder = resolved.smart
            if let newValue {
                UserDefaults(suiteName: appGroup)?.set(newValue, forKey: StoreKeys.selectedFolder)
            }
            selection.removeAll()
        }
        .background(labelTranslatorHost)
        .sheet(item: $backupShareURL) { url in
            BackupShareSheet(url: url)
        }
        .fileImporter(isPresented: $showBackupImporter,
                      allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                handlePickedBackup(at: url)
            case .failure(let err):
                importErrorMessage = err.localizedDescription
            }
        }
        .alert(
            "Restore data?",
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }
            ),
            presenting: pendingImport
        ) { bundle in
            Button("Replace", role: .destructive) {
                applyBackup(bundle, mode: .replace)
                pendingImport = nil
            }
            Button("Merge") {
                applyBackup(bundle, mode: .merge)
                pendingImport = nil
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: { _ in
            Text("Replace deletes everything before restoring. Merge keeps your current items, folders and settings, and adds the imported ones.")
        }
        .alert(
            "Empty this folder?",
            isPresented: $showClearConfirmation
        ) {
            Button("Empty", role: .destructive) { clearFolder() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All items in this folder will be permanently deleted.")
        }
        .alert(
            "Could not import backup",
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if !$0 { importErrorMessage = nil } }
            ),
            presenting: importErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { importErrorMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    /// Host invisible qui exécute la traduction on-device des labels Vision
    /// sur iOS 18+. Inutile (no-op) sur les versions antérieures.
    @ViewBuilder
    private var labelTranslatorHost: some View {
        if #available(iOS 18.0, *) {
            LabelTranslator(pending: $pendingLabelTranslations) { id, translated in
                updateItemTitle(id: id, to: translated)
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedFolder) {
            Section("Smart") {
                ForEach(SmartFolder.allCases) { sf in
                    HStack {
                        Image(systemName: sf.systemImage)
                        Text(sf.label)
                        Spacer()
                        Text("\(smartCount(sf))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    .tag("smart:\(sf.rawValue)")
                }
            }
            Section("Folders") {
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

    private func smartCount(_ sf: SmartFolder) -> Int {
        switch sf {
        case .all:          return items.count
        case .recent7days:  let c = Date().timeIntervalSince1970 - 7 * 86400; return items.filter { $0.timestamp >= c }.count
        case .unreadURLs:   return items.filter { isUnread($0) }.count
        case .withLocation: return items.filter { $0.latitude != nil && $0.longitude != nil }.count
        case .photosOnly:   return items.filter { $0.effectiveKind == "photo" }.count
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            VStack(spacing: 0) {
                clipboardBanner
                filterBanner
                if currentItems.isEmpty {
                    Spacer(minLength: 0)
                    emptyState
                    Spacer(minLength: 0)
                } else {
                    List(selection: $selection) {
                        ForEach(currentItems) { item in
                            itemRow(item)
                                .tag(item.id)
                        }
                        .onDelete(perform: deleteItems)
                        .onMove(perform: moveItems)
                    }
                    .refreshable {
                        await pullToRefreshDates()
                    }
                }
            }
        }
        .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(detailTitle)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    changeColorSchemePreference()
                } label: {
                    Image(systemName: colorSchemePreference == 1 ? "moon.fill" : colorSchemePreference == 2 ? "sun.max.fill" : "circle.lefthalf.filled")
                }
            }
            if !items.isEmpty {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                filterSortMenu
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                settingsMenu
            }
            if !currentItems.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            // Bottom bar pour les opérations en lot quand selection non vide
            ToolbarItemGroup(placement: .bottomBar) {
                if !selection.isEmpty {
                    Menu {
                        ForEach(folders, id: \.self) { folder in
                            Button {
                                moveSelected(to: folder)
                            } label: {
                                Label(displayName(forFolder: folder),
                                      systemImage: folder == StoreKeys.defaultFolder ? "tray" : "folder")
                            }
                        }
                    } label: {
                        Label("Move", systemImage: "folder")
                    }
                    Spacer()
                    Text("\(selection.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }

    private var detailTitle: String {
        if let sf = smartFolder { return sf.label }
        return displayName(forFolder: currentFolder)
    }

    private var filterIsActive: Bool {
        typeFilter != "all" || sortOrder != .insertion || !searchQuery.isEmpty
    }

    /// Menu unifié filtre + tri. L'icône passe en .fill + tint bleu quand
    /// au moins un filtre/tri/recherche est actif → indice visuel
    /// permanent dans la toolbar.
    private var filterSortMenu: some View {
        Menu {
            Picker("Filter", selection: $typeFilter) {
                Label("All", systemImage: "rectangle.grid.2x2").tag("all")
                Label("URLs", systemImage: "globe").tag("url")
                Label("Files", systemImage: "doc").tag("file")
                Label("Photos", systemImage: "photo").tag("photo")
                Label("Videos", systemImage: "video").tag("video")
                Label("Audio", systemImage: "waveform").tag("audio")
                Label("Text", systemImage: "text.alignleft").tag("text")
            }
            Divider()
            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { o in
                    Text(o.label).tag(o)
                }
            }
            if filterIsActive {
                Divider()
                Button(role: .destructive) {
                    typeFilter = "all"
                    sortOrder = .insertion
                    searchQuery = ""
                } label: {
                    Label("Clear filters", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: filterIsActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .foregroundColor(filterIsActive ? .blue : .accentColor)
        }
    }

    /// Bandeau récapitulatif des filtres/tris actifs, juste sous la liste
    /// quand au moins une condition est appliquée. Permet de comprendre
    /// d'un coup d'œil pourquoi la liste affichée est incomplète.
    @ViewBuilder
    private var filterBanner: some View {
        if filterIsActive {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundColor(.blue)
                if typeFilter != "all" {
                    chip(text: typeFilterLabel) { typeFilter = "all" }
                }
                if sortOrder != .insertion {
                    chip(text: sortOrder.label) { sortOrder = .insertion }
                }
                if !searchQuery.isEmpty {
                    chip(text: "“\(searchQuery)”") { searchQuery = "" }
                }
                Spacer()
                Button("Clear filters") {
                    typeFilter = "all"
                    sortOrder = .insertion
                    searchQuery = ""
                }
                .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.10))
        }
    }

    private var typeFilterLabel: String {
        switch typeFilter {
        case "url":   return String(localized: "URLs")
        case "file":  return String(localized: "Files")
        case "photo": return String(localized: "Photos")
        case "video": return String(localized: "Videos")
        case "audio": return String(localized: "Audio")
        case "text":  return String(localized: "Text")
        default:      return String(localized: "All")
        }
    }

    @ViewBuilder
    private func chip(text: String, onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption)
                .lineLimit(1)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.blue.opacity(0.15))
        .clipShape(Capsule())
    }

    /// Bandeau présentant l'URL trouvée dans le presse-papiers au lancement.
    @ViewBuilder
    private var clipboardBanner: some View {
        if let url = clipboardCandidate {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add this link from clipboard?")
                        .font(.subheadline).fontWeight(.medium)
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Add") {
                    addItemFromClipboard(url)
                    clipboardCandidate = nil
                }
                .buttonStyle(.borderedProminent)
                Button {
                    clipboardCandidate = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isAnyConstraintActive {
            // Vide à cause d'un filtre / smart folder / recherche.
            VStack(spacing: 16) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary)
                Text("No items match the current filter")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                if let label = activeConstraintsSummary {
                    Text("(\(label))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Button("Clear filters") {
                    typeFilter = "all"
                    sortOrder = .insertion
                    searchQuery = ""
                    smartFolder = nil
                    selectedFolder = StoreKeys.defaultFolder
                }
                .buttonStyle(.bordered)
            }
        } else {
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
    }

    /// Vrai si AU MOINS UN critère restreint la liste affichée (filtre type,
    /// recherche, tri non manuel, smart folder spécifique). Le folder par
    /// défaut sans rien ne compte pas comme "contrainte".
    private var isAnyConstraintActive: Bool {
        typeFilter != "all"
            || !searchQuery.isEmpty
            || sortOrder != .insertion
            || smartFolder != nil
    }

    /// Résumé textuel des contraintes actives, à afficher entre parenthèses
    /// dans l'écran vide. Renvoie nil si rien à afficher.
    private var activeConstraintsSummary: String? {
        var parts: [String] = []
        if let sf = smartFolder { parts.append(sf.label) }
        if typeFilter != "all" { parts.append(typeFilterLabel) }
        if !searchQuery.isEmpty { parts.append("“\(searchQuery)”") }
        if sortOrder != .insertion { parts.append(sortOrder.label) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            Button {
                if let url = makeBackupFile() {
                    backupShareURL = url
                }
            } label: {
                Label("Backup app data", systemImage: "square.and.arrow.up")
            }
            Button {
                showBackupImporter = true
            } label: {
                Label("Restore app data", systemImage: "square.and.arrow.down")
            }
            Divider()
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
            case "photo":
                HStack(spacing: 8) {
                    Image(systemName: "photo.fill")
                        .foregroundColor(.indigo)
                    if describingIDs.contains(item.id) {
                        Text("Describing image…")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .opacity(blinkPhase ? 1.0 : 0.35)
                    } else {
                        Text(item.title ?? linkURL?.lastPathComponent ?? item.url)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(2)
                    }
                }
            case "video":
                HStack(spacing: 8) {
                    Image(systemName: "video.fill")
                        .foregroundColor(.red)
                    Text(item.title ?? linkURL?.lastPathComponent ?? item.url)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                }
            case "audio":
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundColor(.teal)
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
                let unread = isUnread(item)
                let displayURL = item.originalURL ?? item.url
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "globe")
                        .foregroundColor(.urlAccent)
                    Text(item.title ?? displayURL)
                        .font(.subheadline)
                        .fontWeight(unread ? .bold : .medium)
                        .foregroundColor(unread ? .unreadBordeaux : .primary)
                        .lineLimit(2)
                }
                if item.title != nil {
                    Text(displayURL)
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
            placeRow(for: item)
            noteRow(for: item)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            switch kind {
            case "file", "photo", "video", "audio":
                if let link = linkURL { previewFileURL = link }
            case "text":
                textToPreview = TextPreviewPayload(text: item.url, title: item.title)
            default:
                markAsSeen(itemID: item.id)
                if let link = linkURL { safariFullScreenURL = link }
            }
        }
        .contextMenu {
            Button {
                editingItem = item
            } label: {
                Label("Edit title", systemImage: "pencil")
            }
            Button {
                editingNoteItem = item
            } label: {
                Label("Edit note", systemImage: "note.text")
            }
            if kind == "url" {
                Button {
                    UIPasteboard.general.string = item.originalURL ?? item.url
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
                if !isUnread(item) {
                    Button {
                        markAsUnread(itemID: item.id)
                    } label: {
                        Label("Mark as unread", systemImage: "circle.inset.filled")
                    }
                }
            } else if kind == "text" {
                Button {
                    UIPasteboard.general.string = item.url
                } label: {
                    Label("Copy text", systemImage: "doc.on.doc")
                }
            }
            // Re-partage via la feuille système iOS
            shareLinkForItem(item)
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
            if kind == "photo",
               item.latitude != nil,
               item.longitude != nil,
               item.placeName == nil,
               !geocodingIDs.contains(item.id) {
                startReverseGeocode(for: item)
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

        // Description IA : photos dont `aiDescribed` n'est pas à true et
        // pour lesquelles la config autorise l'appel. Une seule tentative
        // par item (succès ou échec) pour éviter tout spam API.
        triggerPendingAIDescriptions()
        triggerPendingOCR()
        Spotlight.index(items)
    }

    private func triggerPendingAIDescriptions() {
        guard UserDefaults.standard.bool(forKey: "describeImagesEnabled") else { return }
        let provider = UserDefaults.standard.string(forKey: "describeImagesProvider") ?? "anthropic"
        let apiKey = (UserDefaults.standard.string(forKey: "describeImagesAPIKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let customModel = (UserDefaults.standard.string(forKey: "describeImagesModel") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Apple Intelligence (on-device Vision) n'a pas besoin de clé.
        if provider != "apple" && apiKey.isEmpty { return }

        for item in items where item.effectiveKind == "photo"
                                && item.aiDescribed != true
                                && !describingIDs.contains(item.id) {
            startAIDescribe(item: item, provider: provider, apiKey: apiKey, customModel: customModel)
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

    /// Réordonne les items du folder courant. Les items des autres folders
    /// gardent leur position relative dans le tableau global.
    private func moveItems(from source: IndexSet, to destination: Int) {
        // 1. Extraire l'ordre actuel des items du folder courant.
        var folderItems = currentItems
        folderItems.move(fromOffsets: source, toOffset: destination)

        // 2. Reconstruire `items` : aux positions des items du folder courant,
        //    injecter la nouvelle séquence ; ailleurs, conserver tel quel.
        var newItems: [SharedItem] = []
        newItems.reserveCapacity(items.count)
        var iter = folderItems.makeIterator()
        for existing in items {
            if existing.folder == currentFolder {
                if let next = iter.next() {
                    newItems.append(next)
                }
            } else {
                newItems.append(existing)
            }
        }
        items = newItems
        saveItems()
    }

    private func deleteItems(at offsets: IndexSet) {
        let removedItems = offsets.map { currentItems[$0] }
        removedItems.forEach { removeFileIfLocal($0.url) }
        let removedIDs = Set(removedItems.map(\.id))
        items.removeAll { removedIDs.contains($0.id) }
        Spotlight.deindex(Array(removedIDs))
        saveItems()
    }

    private func clearFolder() {
        // Supprime ce qui est ACTUELLEMENT affiché : compatible avec les
        // smart folders, les filtres par type et la recherche. L'ancienne
        // version filtrait par `folder == currentFolder`, ce qui ne matchait
        // rien quand on était dans un smart folder (clé "smart:…").
        let removedItems = currentItems
        let removedIDs = Set(removedItems.map(\.id))
        removedItems.forEach { removeFileIfLocal($0.url) }
        Spotlight.deindex(removedItems.map(\.id))
        items.removeAll { removedIDs.contains($0.id) }
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

    // MARK: - Note row + edit

    @ViewBuilder
    private func noteRow(for item: SharedItem) -> some View {
        if let note = item.note, !note.isEmpty {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "note.text")
                    .font(.caption2)
                Text(note)
                    .font(.caption2)
                    .italic()
                    .lineLimit(3)
            }
            .foregroundColor(.secondary)
        }
    }

    private func updateItemNote(id: String, to note: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].note = note.isEmpty ? nil : note
        saveItems()
    }

    // MARK: - Re-share from app

    @ViewBuilder
    private func shareLinkForItem(_ item: SharedItem) -> some View {
        let kind = item.effectiveKind
        if kind == "text" {
            ShareLink(item: item.url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } else if let url = URL(string: item.originalURL ?? item.url) {
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    // MARK: - Batch operations

    private func deleteSelected() {
        let ids = selection
        let removed = items.filter { ids.contains($0.id) }
        removed.forEach { removeFileIfLocal($0.url) }
        items.removeAll { ids.contains($0.id) }
        Spotlight.deindex(Array(ids))
        saveItems()
        selection.removeAll()
    }

    private func moveSelected(to folder: String) {
        let ids = selection
        for i in 0..<items.count {
            if ids.contains(items[i].id) {
                items[i].folder = folder
            }
        }
        saveItems()
        selection.removeAll()
    }

    // MARK: - Clipboard capture

    private func checkClipboardForURL() {
        let pb = UIPasteboard.general
        // Évite la lecture répétée du même contenu
        guard pb.changeCount != clipboardLastChangeCount else { return }
        clipboardLastChangeCount = pb.changeCount

        let candidate: URL? = {
            if let url = pb.url, url.scheme == "http" || url.scheme == "https" {
                return url
            }
            if let s = pb.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: s),
               url.scheme == "http" || url.scheme == "https" {
                return url
            }
            return nil
        }()
        guard let url = candidate else { return }
        // Skip si déjà présent
        if items.contains(where: { ($0.originalURL ?? $0.url) == url.absoluteString }) {
            return
        }
        clipboardCandidate = url
    }

    private func addItemFromClipboard(_ url: URL) {
        let now = Date().timeIntervalSince1970
        let item = SharedItem(
            id: UUID().uuidString,
            url: url.absoluteString,
            title: nil,
            sourceApp: "Clipboard",
            folder: smartFolder == nil ? currentFolder : StoreKeys.defaultFolder,
            timestamp: now,
            kind: "url",
            modifiedAt: nil,
            latitude: nil,
            longitude: nil,
            placeName: nil,
            aiDescribed: nil,
            lastSeenModifiedAt: nil,
            originalURL: nil,
            note: nil,
            ocrDone: nil
        )
        items.insert(item, at: 0)
        saveItems()
    }

    // MARK: - OCR (photos)

    private func triggerPendingOCR() {
        for item in items where item.effectiveKind == "photo"
                                && item.ocrDone != true
                                // On laisse l'IA finir avant l'OCR pour bien
                                // appender le texte OCR derrière la description.
                                && (item.aiDescribed == true || !UserDefaults.standard.bool(forKey: "describeImagesEnabled")) {
            startOCR(for: item)
        }
    }

    private func startOCR(for item: SharedItem) {
        // Marqueur immédiat pour éviter les doubles déclenchements.
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].ocrDone = true
        let id = item.id
        let urlString = item.url
        Task.detached(priority: .utility) {
            let text = await Self.recognizeText(in: urlString)
            await MainActor.run {
                appendOCRResult(id: id, ocrText: text)
            }
        }
    }

    private func appendOCRResult(id: String, ocrText: String?) {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              let text = ocrText, !text.isEmpty else { return }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return }
        let prefix = items[idx].title ?? URL(string: items[idx].url)?.lastPathComponent ?? items[idx].url
        items[idx].title = "\(prefix) — \(collapsed)"
        saveItems()
    }

    static func recognizeText(in urlString: String) async -> String? {
        guard let url = URL(string: urlString), url.isFileURL,
              let data = try? Data(contentsOf: url),
              let cgImage = UIImage(data: data)?.cgImage else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let request = VNRecognizeTextRequest { req, _ in
                guard let observations = req.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil); return
                }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Backup / restore

    private func makeBackupFile() -> URL? {
        let appDefaults = UserDefaults.standard
        let bundle = BackupBundle(
            schemaVersion: 1,
            exportedAt: Date().timeIntervalSince1970,
            settings: BackupBundle.Settings(
                colorSchemePreference: colorSchemePreference,
                debugLogsEnabled: debugLogsEnabled,
                describeImagesEnabled: appDefaults.bool(forKey: "describeImagesEnabled"),
                describeImagesProvider: appDefaults.string(forKey: "describeImagesProvider") ?? "apple",
                // SÉCURITÉ : la clé d'API n'est jamais incluse dans la
                // sauvegarde (elle reste sur l'appareil source uniquement).
                describeImagesAPIKey: "",
                describeImagesModel: appDefaults.string(forKey: "describeImagesModel") ?? "",
                simulateDateDelay: appDefaults.bool(forKey: "simulateDateDelay"),
                selectedFolder: selectedFolder ?? StoreKeys.defaultFolder
            ),
            folders: folders,
            items: items,
            files: collectFileBlobs()
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(bundle)
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd-HHmmss"
            let filename = "ShareManager-backup-\(df.string(from: Date())).json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("Backup error: \(error)")
            return nil
        }
    }

    private func collectFileBlobs() -> [String: BackupBundle.FileBlob] {
        var blobs: [String: BackupBundle.FileBlob] = [:]
        for item in items {
            let kind = item.effectiveKind
            guard kind == "file" || kind == "photo" || kind == "video" || kind == "audio" else { continue }
            guard let url = URL(string: item.url), url.isFileURL,
                  let data = try? Data(contentsOf: url) else { continue }
            blobs[item.id] = BackupBundle.FileBlob(
                filename: url.lastPathComponent,
                base64: data.base64EncodedString()
            )
        }
        return blobs
    }

    private func handlePickedBackup(at url: URL) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let bundle = try JSONDecoder().decode(BackupBundle.self, from: data)
            pendingImport = bundle
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    enum RestoreMode { case replace, merge }

    private func applyBackup(_ bundle: BackupBundle, mode: RestoreMode) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            importErrorMessage = "App Group container unavailable."
            return
        }
        let dir = containerURL.appendingPathComponent("SharedFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // ===== Mode REPLACE =====
        if mode == .replace {
            // Supprime les anciens fichiers du container.
            for item in items { removeFileIfLocal(item.url) }

            // Réglages applicatifs.
            let appDefaults = UserDefaults.standard
            colorSchemePreference = bundle.settings.colorSchemePreference
            debugLogsEnabled = bundle.settings.debugLogsEnabled
            appDefaults.set(bundle.settings.describeImagesEnabled, forKey: "describeImagesEnabled")
            appDefaults.set(bundle.settings.describeImagesProvider, forKey: "describeImagesProvider")
            // SÉCURITÉ : on ne réécrit la clé d'API que si la sauvegarde
            // en contient une non vide (ce ne sera jamais le cas avec
            // les sauvegardes produites par cette app, qui blanchissent
            // toujours le champ). On préserve donc la clé déjà saisie.
            if !bundle.settings.describeImagesAPIKey.isEmpty {
                appDefaults.set(bundle.settings.describeImagesAPIKey, forKey: "describeImagesAPIKey")
            }
            appDefaults.set(bundle.settings.describeImagesModel, forKey: "describeImagesModel")
            appDefaults.set(bundle.settings.simulateDateDelay, forKey: "simulateDateDelay")

            var newFolders = bundle.folders
            if !newFolders.contains(StoreKeys.defaultFolder) {
                newFolders.insert(StoreKeys.defaultFolder, at: 0)
            }
            folders = newFolders
            saveFolders()

            items = restoreItems(bundle.items, files: bundle.files, into: dir, regenerateIDs: false)
            saveItems()

            if folders.contains(bundle.settings.selectedFolder) {
                selectedFolder = bundle.settings.selectedFolder
            } else {
                selectedFolder = StoreKeys.defaultFolder
            }
            UserDefaults(suiteName: appGroup)?.set(selectedFolder, forKey: StoreKeys.selectedFolder)
            return
        }

        // ===== Mode MERGE =====
        // - Réglages : on conserve les valeurs courantes (rien d'écrasé).
        // - Folders : union (les folders nouveaux sont ajoutés à la fin).
        // - Items : append. On régénère les IDs pour éviter toute collision
        //   avec des items existants ; les fichiers binaires sont récupérés
        //   par l'ancien ID puis restaurés sous un nouveau nom.
        for f in bundle.folders where !folders.contains(f) {
            folders.append(f)
        }
        saveFolders()

        let merged = restoreItems(bundle.items, files: bundle.files, into: dir, regenerateIDs: true)
        items.append(contentsOf: merged)
        saveItems()
    }

    /// Écrit les binaires de `files` dans `dir` et retourne la liste d'items
    /// avec leur `url` pointant sur le nouveau chemin App Group. Si
    /// `regenerateIDs` est vrai, chaque item reçoit un nouvel UUID (pour
    /// éviter les collisions avec des items existants en mode merge).
    private func restoreItems(_ source: [SharedItem],
                              files: [String: BackupBundle.FileBlob],
                              into dir: URL,
                              regenerateIDs: Bool) -> [SharedItem] {
        var result = source
        let now = Int(Date().timeIntervalSince1970 * 1000)
        for i in 0..<result.count {
            let item = result[i]
            // ID de référence pour retrouver le blob (avant régénération).
            let blob = files[item.id]
            if regenerateIDs {
                let copy = SharedItem(
                    id: UUID().uuidString,
                    url: item.url,
                    title: item.title,
                    sourceApp: item.sourceApp,
                    folder: item.folder,
                    timestamp: item.timestamp,
                    kind: item.kind,
                    modifiedAt: item.modifiedAt,
                    latitude: item.latitude,
                    longitude: item.longitude,
                    placeName: item.placeName,
                    aiDescribed: item.aiDescribed,
                    lastSeenModifiedAt: item.lastSeenModifiedAt,
                    originalURL: item.originalURL,
                    note: item.note,
                    ocrDone: item.ocrDone
                )
                result[i] = copy
            }
            guard let blob = blob, let data = Data(base64Encoded: blob.base64) else { continue }
            let safeName = "\(now)-\(i)_\(blob.filename)"
            let dest = dir.appendingPathComponent(safeName)
            do {
                try data.write(to: dest, options: .atomic)
                result[i].url = dest.absoluteString
            } catch {
                print("Restore file write error: \(error)")
            }
        }
        return result
    }

    // MARK: - Unread state (URL items)

    /// Un item URL est "non lu" (titre en gras) si :
    /// - il a une `modifiedAt` connue (première récupération réussie), ET
    /// - soit `lastSeenModifiedAt` est nil (jamais ouvert depuis qu'on a
    ///   la date), soit `modifiedAt > lastSeenModifiedAt` (la page a une
    ///   version plus récente que lors de la dernière ouverture).
    private func isUnread(_ item: SharedItem) -> Bool {
        guard item.effectiveKind == "url",
              let mod = item.modifiedAt else { return false }
        guard let seen = item.lastSeenModifiedAt else { return true }
        return mod > seen
    }

    /// Appelé quand l'utilisateur ouvre une URL : on mémorise la date vue
    /// pour ne plus marquer l'item comme "nouveau" jusqu'à la prochaine
    /// modification remotelement détectée.
    private func markAsSeen(itemID: String) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }),
              let mod = items[idx].modifiedAt else { return }
        if items[idx].lastSeenModifiedAt != mod {
            items[idx].lastSeenModifiedAt = mod
            saveItems()
        }
    }

    /// Force le retour à l'état "non lu" : efface la date vue → si
    /// `modifiedAt` est connu, l'item redevient en gras et bordeaux.
    private func markAsUnread(itemID: String) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        if items[idx].lastSeenModifiedAt != nil {
            items[idx].lastSeenModifiedAt = nil
            saveItems()
        }
    }

    // MARK: - AI image description

    private func startAIDescribe(item: SharedItem, provider: String, apiKey: String, customModel: String) {
        describingIDs.insert(item.id)
        let id = item.id
        let urlString = item.url
        Task.detached(priority: .utility) {
            let description = await Self.describeImage(urlString: urlString,
                                                       provider: provider,
                                                       apiKey: apiKey,
                                                       customModel: customModel)
            await MainActor.run {
                describingIDs.remove(id)
                updateItemAfterAIDescribe(id: id, description: description, provider: provider)
            }
        }
    }

    private func updateItemAfterAIDescribe(id: String, description: String?, provider: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let description, !description.isEmpty {
            items[idx].title = description
            items[idx].aiDescribed = true
            saveItems()
            // Si la langue de l'app n'est pas l'anglais et que les labels
            // viennent d'Apple Vision (anglais), enfiler pour traduction
            // on-device (iOS 18+).
            if provider == "apple" {
                let lang = Locale.current.language.languageCode?.identifier ?? "en"
                if lang != "en", #available(iOS 18.0, *) {
                    pendingLabelTranslations.append(LabelTranslationJob(id: id, sourceText: description))
                }
            }
        } else {
            items[idx].aiDescribed = true
            saveItems()
        }
    }

    /// Charge l'image, la convertit en JPEG (max 1568 px sur le plus grand
    /// côté) puis appelle le provider choisi. Renvoie la description texte
    /// ou nil en cas d'échec.
    static func describeImage(urlString: String, provider: String, apiKey: String, customModel: String) async -> String? {
        guard let url = URL(string: urlString), url.isFileURL,
              let raw = try? Data(contentsOf: url) else { return nil }

        // Apple Intelligence (on-device Vision) : pas d'appel réseau,
        // pas besoin de compression JPEG ni de clé.
        if provider == "apple" {
            return await describeViaApple(imageData: raw)
        }

        guard let (jpeg, mediaType) = prepareImageForAI(data: raw) else { return nil }
        let base64 = jpeg.base64EncodedString()

        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let prompt = "Describe this image in rich, visual detail: subjects, objects, colors, composition, lighting, mood, and any notable elements. Respond in the language with BCP-47 code \"\(lang)\". Return only the description itself, with no preamble, no quotes, no labels."

        switch provider {
        case "openai":
            let model = customModel.isEmpty ? "gpt-4o" : customModel
            return await describeViaOpenAI(apiKey: apiKey, base64: base64, mediaType: mediaType, prompt: prompt, model: model)
        default:
            let model = customModel.isEmpty ? "claude-sonnet-4-5" : customModel
            return await describeViaAnthropic(apiKey: apiKey, base64: base64, mediaType: mediaType, prompt: prompt, model: model)
        }
    }

    /// Classification on-device via Vision (`VNClassifyImageRequest`).
    /// Retourne la liste des labels au-dessus d'un seuil de confiance,
    /// joints par des virgules. Aucun appel réseau.
    static func describeViaApple(imageData: Data) async -> String? {
        guard let cgImage = UIImage(data: imageData)?.cgImage else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let request = VNClassifyImageRequest { req, error in
                if let error {
                    print("Vision error: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                guard let observations = req.results as? [VNClassificationObservation] else {
                    continuation.resume(returning: nil)
                    return
                }
                // Seuil de confiance + top 15 labels max. On garde l'ordre
                // natif (déjà trié par confiance décroissante).
                let labels = observations
                    .filter { $0.confidence > 0.3 }
                    .prefix(15)
                    .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
                if labels.isEmpty {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: labels.joined(separator: ", "))
                }
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("Vision perform error: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            }
        }
    }

    /// Normalise l'image en JPEG redimensionné. Accepte HEIC/PNG/JPEG et
    /// tout ce que `UIImage(data:)` sait décoder.
    static func prepareImageForAI(data: Data) -> (Data, String)? {
        guard var image = UIImage(data: data) else { return nil }
        let maxDim: CGFloat = 1568
        let w = image.size.width, h = image.size.height
        if max(w, h) > maxDim {
            let scale = maxDim / max(w, h)
            let newSize = CGSize(width: w * scale, height: h * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            image = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        return (jpeg, "image/jpeg")
    }

    static func describeViaAnthropic(apiKey: String, base64: String, mediaType: String, prompt: String, model: String) async -> String? {
        guard let endpoint = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64",
                                "media_type": mediaType,
                                "data": base64]],
                    ["type": "text", "text": prompt],
                ],
            ]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                if let s = String(data: data, encoding: .utf8) {
                    print("Anthropic HTTP error body: \(s.prefix(300))")
                }
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let first = content.first(where: { ($0["type"] as? String) == "text" }),
                  let text = first["text"] as? String else {
                return nil
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("Anthropic error: \(error.localizedDescription)")
            return nil
        }
    }

    static func describeViaOpenAI(apiKey: String, base64: String, mediaType: String, prompt: String, model: String) async -> String? {
        guard let endpoint = URL(string: "https://api.openai.com/v1/chat/completions") else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url",
                     "image_url": ["url": "data:\(mediaType);base64,\(base64)"]],
                ],
            ]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                if let s = String(data: data, encoding: .utf8) {
                    print("OpenAI HTTP error body: \(s.prefix(300))")
                }
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return nil
            }
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("OpenAI error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Place row & reverse geocoding (photos)

    @ViewBuilder
    private func placeRow(for item: SharedItem) -> some View {
        if item.effectiveKind == "photo",
           item.latitude != nil,
           item.longitude != nil {
            let resolving = geocodingIDs.contains(item.id)
            HStack(spacing: 4) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.caption2)
                if let place = item.placeName, !place.isEmpty {
                    Text(place)
                        .font(.caption2)
                } else if resolving || item.placeName == nil {
                    Text("Fetching location…")
                        .font(.caption2)
                        .opacity(blinkPhase ? 1.0 : 0.35)
                }
                // Si placeName == "" : échec définitif, on n'affiche rien
                // après l'icône (ligne reste mais vide). On peut aussi la
                // cacher — ici on garde l'icône comme repère visuel discret.
            }
            .foregroundColor(.secondary)
        }
    }

    private func startReverseGeocode(for item: SharedItem) {
        guard let lat = item.latitude, let lon = item.longitude else { return }
        geocodingIDs.insert(item.id)
        let id = item.id
        let loc = CLLocation(latitude: lat, longitude: lon)
        Task.detached(priority: .utility) {
            let geocoder = CLGeocoder()
            let placemarks = try? await geocoder.reverseGeocodeLocation(loc)
            let name: String = {
                guard let p = placemarks?.first else { return "" }
                // Priorité : ville, sinon sous-localité, sinon nom, sinon région.
                if let locality = p.locality, !locality.isEmpty {
                    if let country = p.country, !country.isEmpty {
                        return "\(locality), \(country)"
                    }
                    return locality
                }
                if let sub = p.subLocality, !sub.isEmpty { return sub }
                if let n = p.name, !n.isEmpty { return n }
                if let admin = p.administrativeArea, !admin.isEmpty { return admin }
                return ""
            }()
            await MainActor.run {
                geocodingIDs.remove(id)
                updateItemPlaceName(id: id, to: name)
            }
        }
    }

    private func updateItemPlaceName(id: String, to place: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].placeName = place
        saveItems()
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
                    } else if let item = items.first(where: { $0.id == id }),
                              item.modifiedAt == nil {
                        // Échec + aucune valeur antérieure : on évite un
                        // placeholder clignotant permanent en retombant sur
                        // la date de partage (comme `startFetchLastModified`).
                        updateItemModifiedAt(id: id, to: Date(timeIntervalSince1970: item.timestamp))
                    }
                    // Sinon (échec avec ancienne valeur) : on conserve.
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

extension Color {
    /// Vert foncé de l'icône globe (URL). Plus clair en mode sombre pour
    /// rester lisible sur fond sombre.
    static let urlAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.45, green: 0.85, blue: 0.55, alpha: 1)
            : UIColor(red: 0.0,  green: 0.45, blue: 0.20, alpha: 1)
    })

    /// Bordeaux pour les titres d'URL "non lus" (page modifiée depuis la
    /// dernière ouverture). Variante plus claire en mode sombre.
    static let unreadBordeaux = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.55, blue: 0.60, alpha: 1)
            : UIColor(red: 0.55, green: 0.00, blue: 0.15, alpha: 1)
    })
}

extension Array {
    /// Découpe le tableau en sous-tableaux de taille `size` maximum.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

/// Indexation Spotlight des items pour qu'ils soient retrouvés depuis la
/// recherche système iOS. L'ID Spotlight est le SharedItem.id.
enum Spotlight {
    static let domain = "net.fenyo.apple.sharemanager.items"

    static func index(_ items: [SharedItem]) {
        let searchableItems = items.map { item -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: .item)
            attrs.title = item.title ?? URL(string: item.url)?.lastPathComponent ?? item.url
            attrs.contentDescription = [item.note, item.placeName, item.sourceApp]
                .compactMap { $0 }.joined(separator: " · ")
            attrs.keywords = [item.effectiveKind, item.folder, item.sourceApp].compactMap { $0 }
            return CSSearchableItem(uniqueIdentifier: item.id,
                                    domainIdentifier: domain,
                                    attributeSet: attrs)
        }
        CSSearchableIndex.default().indexSearchableItems(searchableItems) { _ in }
    }

    static func deindex(_ ids: [String]) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids) { _ in }
    }
}

/// Présente la feuille de partage iOS pour un fichier (export du backup).
struct BackupShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Job de traduction d'un titre d'item (labels Vision anglais → langue user).
struct LabelTranslationJob: Identifiable, Equatable {
    let id: String   // ID du SharedItem ciblé
    let sourceText: String
}

#if canImport(Translation)
/// Host invisible (iOS 18+) qui draine la file `pending` via le framework
/// Translation d'Apple : traduction on-device de l'anglais vers la langue
/// de l'appareil. Appelle `onTranslated` pour chaque item.
@available(iOS 18.0, *)
struct LabelTranslator: View {
    @Binding var pending: [LabelTranslationJob]
    let onTranslated: (_ id: String, _ translated: String) -> Void

    @State private var config: TranslationSession.Configuration? = nil

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { ensureConfig() }
            .onChange(of: pending.count) { _, newCount in
                if newCount > 0 { ensureConfig() }
            }
            .translationTask(config) { session in
                await drain(session: session)
            }
    }

    private func ensureConfig() {
        if config == nil {
            config = TranslationSession.Configuration(
                source: Locale.Language(identifier: "en"),
                target: Locale.current.language
            )
        } else {
            // Forcer la relance de .translationTask en ré-instanciant
            config = TranslationSession.Configuration(
                source: Locale.Language(identifier: "en"),
                target: Locale.current.language
            )
        }
    }

    private func drain(session: TranslationSession) async {
        while !pending.isEmpty {
            let job = pending.removeFirst()
            do {
                let response = try await session.translate(job.sourceText)
                await MainActor.run {
                    onTranslated(job.id, response.targetText)
                }
            } catch {
                print("Translation error: \(error.localizedDescription)")
            }
        }
    }
}
#endif

/// Feuille modale pour éditer la note (texte libre) d'un item.
struct EditNoteView: View {
    let initialNote: String
    let onSave: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                TextField("Note", text: $text, axis: .vertical)
                    .lineLimit(3...12)
                    .focused($focused)
            }
            .navigationTitle("Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        onSave(text)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                text = initialNote
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true }
            }
        }
    }
}

/// Feuille modale pour éditer le titre (première ligne affichée) d'un item.
struct EditTitleView: View {
    let initialTitle: String
    let onSave: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                TextField("Title", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
            }
            .navigationTitle("Edit title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                text = initialTitle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focused = true
                }
            }
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
