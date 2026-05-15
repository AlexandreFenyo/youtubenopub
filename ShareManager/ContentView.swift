import SwiftUI
import WebKit
import QuickLook
import QuickLookThumbnailing
import CoreLocation
import Vision
import AVFoundation
import Speech
import StoreKit
import UniformTypeIdentifiers
import CoreSpotlight
import WidgetKit
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
    /// Nom de fichier (à l'intérieur du sous-dossier `previews/` du
    /// container App Group) de l'aperçu PNG 320x200. Nil tant que la
    /// génération n'a pas eu lieu, "" si l'on a essayé sans succès
    /// OU si l'utilisateur a effacé l'aperçu via « Clear previews ».
    /// Dans les deux cas, le pull-to-refresh / 1B retentera la
    /// génération.
    var previewPath: String?
    /// Nombre d'appels IA cloud (OpenAI / Anthropic) déjà effectués pour
    /// cet item. Plafonné à 5 ; au-delà, l'app n'invoque plus l'IA pour
    /// cet item — l'utilisateur peut le réinitialiser via le menu
    /// contextuel de la ligne. Persistant dans le JSON de sauvegarde.
    var aiCallsCount: Int?
    /// Vrai si la traduction des labels Vision (Apple Translation) a
    /// été tentée pour cet item — succès ou échec. Bloque les
    /// re-soumissions auto. Reset à `nil` quand on regénère le titre IA.
    var translationDone: Bool?
    /// Vrai si la dernière tentative d'OCR a échoué (Vision a renvoyé
    /// nil, image illisible, Task cancellée). Sert à bloquer les
    /// retries auto via `triggerPendingOCR` tout en permettant aux
    /// refresh globaux (1A/1B) de remettre à zéro pour retenter
    /// l'OCR sans coût.
    var ocrFailed: Bool?
    /// Vrai si la dernière tentative de fetch du <title> HTML d'une
    /// URL a échoué (HTTP 4xx/5xx, parsing fail, page sans balise
    /// title, timeout). Bloque les re-fetches auto à chaque
    /// `.onAppear` ; les refresh globaux 1A/1B remettent à nil pour
    /// retenter.
    var titleFetchFailed: Bool?
    /// Vrai si la dernière tentative IA (description photo/video ou
    /// transcription audio) a échoué. Distinct de `aiDescribed`
    /// (qui veut juste dire « tentée, succès ou échec »). Sert à
    /// afficher un avertissement dans la ligne et à permettre à
    /// l'utilisateur de retenter via le menu contextuel.
    var aiFailed: Bool?
    /// Vrai si l'utilisateur a verrouillé la preview de cet item
    /// (uniquement pour les URLs). Quand verrouillée :
    ///   - `triggerPendingPreviews` saute l'item (pas d'auto-régénération),
    ///   - `regeneratePreview*` refuse de re-générer,
    ///   - `clearPreviewsForCurrent` saute l'item,
    ///   - le pipeline de pull-to-refresh / « Refresh previews and URL
    ///     dates » ignore aussi cet item.
    /// Un cadenas est dessiné en surimpression sur l'aperçu.
    var previewLocked: Bool?
    /// Vrai si l'utilisateur a zoomé l'aperçu de cet item. Le zoom
    /// est purement visuel : l'image PNG stockée dans `previews/` est
    /// inchangée, et `previewPath` aussi. On applique simplement un
    /// `scaleEffect(2)` centré au moment du rendu — la taille occupée
    /// dans l'UI ne change pas, mais on voit 2x plus gros le centre
    /// de l'image. Indépendant du verrou et du recadrage automatique :
    /// c'est l'image finale (post-recadrage si applicable) qui est
    /// zoomée. Persisté en local + cloud (champ scalaire du `Item`
    /// record CloudKit).
    var previewZoomed: Bool?

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
    /// Aperçus PNG (320×200 logique, ×3 pixels) en base64, indexés par
    /// `SharedItem.id`. Optionnel pour rétro-compat avec d'anciennes
    /// sauvegardes.
    var previews: [String: String]?

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
/// Compteurs persistants d'utilisation des providers IA cloud.
/// Stockés dans `UserDefaults.standard` (donc préservés entre les
/// lancements de l'app). Apple Intelligence n'est PAS instrumenté.
/// Remis à zéro automatiquement quand l'utilisateur désactive l'IA via
/// Réglages iOS.
enum AICounters {
    /// Enregistre une requête avec les VRAIS comptes de tokens, lus
    /// depuis le champ `usage` de la réponse JSON (OpenAI / Anthropic).
    /// Le `provider` correspond aux valeurs internes "openai" / "anthropic".
    /// `model` est mémorisé pour pouvoir l'afficher dans le panneau de
    /// statistiques (dernier modèle utilisé pour ce provider).
    static func record(provider: String, model: String, tokensIn: Int, tokensOut: Int) {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: requestsKey(provider)) + 1,
              forKey: requestsKey(provider))
        d.set(d.integer(forKey: tokensInKey(provider)) + max(0, tokensIn),
              forKey: tokensInKey(provider))
        d.set(d.integer(forKey: tokensOutKey(provider)) + max(0, tokensOut),
              forKey: tokensOutKey(provider))
        d.set(model, forKey: modelKey(provider))
    }

    static func read(provider: String) -> (requests: Int, tokensIn: Int, tokensOut: Int, model: String?) {
        let d = UserDefaults.standard
        return (d.integer(forKey: requestsKey(provider)),
                d.integer(forKey: tokensInKey(provider)),
                d.integer(forKey: tokensOutKey(provider)),
                d.string(forKey: modelKey(provider)))
    }

    /// Remet à zéro tous les compteurs (tous providers).
    static func resetAll() {
        let d = UserDefaults.standard
        for p in ["openai", "anthropic"] {
            d.removeObject(forKey: requestsKey(p))
            d.removeObject(forKey: tokensInKey(p))
            d.removeObject(forKey: tokensOutKey(p))
            d.removeObject(forKey: modelKey(p))
        }
    }

    /// Liste des providers ayant au moins une requête enregistrée.
    static func providersWithCalls() -> [String] {
        ["openai", "anthropic"].filter {
            UserDefaults.standard.integer(forKey: requestsKey($0)) > 0
        }
    }

    static func displayName(_ provider: String) -> String {
        switch provider {
        case "openai":    return "OpenAI"
        case "anthropic": return "Anthropic"
        default:          return provider.capitalized
        }
    }

    private static func requestsKey(_ p: String)  -> String { "ai.\(p).requests" }
    private static func tokensInKey(_ p: String)  -> String { "ai.\(p).tokensIn" }
    private static func tokensOutKey(_ p: String) -> String { "ai.\(p).tokensOut" }
    private static func modelKey(_ p: String)     -> String { "ai.\(p).model" }
}

/// Payload utilisé pour le drag-and-drop d'items depuis la liste de droite
/// vers un folder de la sidebar (iPad uniquement). Type dédié — pas un
/// simple String — pour ne pas accepter par erreur un drop d'origine
/// externe.
struct ItemDragPayload: Codable, Transferable {
    let ids: [String]
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .itemDragPayload)
    }
}

extension UTType {
    static let itemDragPayload = UTType(exportedAs: "fr.fenyo.sharemanager.itemdrag")
}

/// Active le drag sur une ligne d'item uniquement sur iPad. Sur iPhone,
/// la sidebar n'est pas visible en même temps que la liste, donc le
/// drag-vers-folder n'a aucun sens : on ne pose pas le modifier. Si
/// l'item fait partie d'une multi-sélection (mode Edit), le payload
/// embarque tous les ids sélectionnés ; sinon, juste celui-ci.
struct ItemDragModifier: ViewModifier {
    let item: SharedItem
    let selection: Set<String>

    private var payloadIds: [String] {
        selection.contains(item.id) && selection.count > 1
            ? Array(selection)
            : [item.id]
    }

    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.draggable(ItemDragPayload(ids: payloadIds)) {
                let count = payloadIds.count
                Label(count > 1
                      ? String(localized: "\(count) items")
                      : (item.title ?? URL(string: item.url)?.lastPathComponent ?? item.url),
                      systemImage: count > 1 ? "square.stack.fill" : "doc")
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            content
        }
    }
}

enum StoreKeys {
    static let items = "items"
    static let folders = "folders"
    static let selectedFolder = "selectedFolder"
    /// Identifiant interne du folder par défaut. Son nom d'affichage
    /// est localisé via `displayName(forFolder:)`.
    static let defaultFolder = "Default"
    /// Token d'opaque server-side CloudKit pour `CKFetchDatabaseChangesOperation` :
    /// permet de ne tirer que le delta depuis la dernière fetch.
    static let cloudKitDBChangeToken = "cloudKitDBChangeToken"
}

/// Représentation locale d'un dossier. Conserve son nom (qui sert
/// d'identifiant utilisateur ET d'identifiant CloudKit), un drapeau
/// indiquant si l'utilisateur a activé la synchronisation iCloud pour
/// ce dossier, et un index numérique préservant l'ordre du
/// drag-to-reorder de la sidebar. `iCloudSynced` est false par défaut :
/// un dossier reste local-only tant que l'utilisateur ne demande pas
/// explicitement la sync via le menu contextuel.
struct Folder: Codable, Hashable, Identifiable {
    var name: String
    var iCloudSynced: Bool
    var sortIndex: Double
    var id: String { name }

    /// Helper pour le `Default` system folder : jamais synced, sortIndex 0.
    static func systemDefault() -> Folder {
        Folder(name: StoreKeys.defaultFolder, iCloudSynced: false, sortIndex: 0)
    }
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
    @State private var folders: [Folder] = [Folder.systemDefault()]
    @State private var selectedFolder: String? = StoreKeys.defaultFolder

    @State private var safariFullScreenURL: URL? = nil
    @State private var previewFileURL: URL? = nil
    @State private var textToPreview: TextPreviewPayload? = nil
    @State private var showDebugLogs = false
    @State private var debugLogs = ""
    @State private var lastLogSize: Int = 0
    /// Bouton « Resync iCloud » : ouvre une confirmation avant de
    /// déclencher `CloudSync.resyncReconcile()`, qui peut écrire et
    /// supprimer dans iCloud.
    @State private var showResyncConfirm = false
    /// URLs détectées dans le presse-papiers en attente de confirmation
    /// utilisateur. Non vide ⇔ le dialog `showPasteMultipleConfirm` est
    /// affiché (cas où le presse-papiers contient ≥ 2 URLs).
    @State private var pendingPasteURLs: [String] = []
    @State private var showPasteMultipleConfirm = false
    @State private var isResyncing = false
    /// Confirmation pour « Delete local data » : action destructive
    /// qui efface le contenu des folders non synchronisés + le
    /// contenu du folder Default, mais préserve les folders synced
    /// et leur contenu (cloud-backed).
    @State private var showDeleteLocalConfirm = false

    @State private var themeAnnouncement: (old: Int, new: Int)? = nil
    /// Annonce overlay pull-to-refresh (mêmes style/durée que themeOverlay).
    @State private var refreshAnnouncement: Bool = false
    /// Sous-titre affiché sous « Refreshing » dans l'overlay. Permet de
    /// distinguer un pull-to-refresh de la liste des items (texte par
    /// défaut) d'un pull-to-refresh de la sidebar (texte iCloud resync).
    @State private var refreshAnnouncementSubtitle: LocalizedStringKey = "Updating missing previews and URL dates"
    /// Horodatages des appels IA (OpenAI/Anthropic uniquement, jamais
    /// Apple Intelligence). Volontairement non persisté — repart de zéro
    /// au lancement de l'app.
    @State private var aiCallTimestamps: [Date] = []
    /// Alerte avertissement quand l'utilisateur dépasse le seuil de 20
    /// appels IA en 5 minutes glissantes.
    @State private var showAIRateWarning: Bool = false
    /// Dernière valeur connue de `describeImagesEnabled` — sert à détecter
    /// la transition true → false (l'utilisateur vient de désactiver l'IA
    /// via Réglages iOS) → reset des compteurs.
    @State private var lastSeenAIEnabled: Bool = UserDefaults.standard.bool(forKey: "describeImagesEnabled")
    /// Dernier provider connu (apple/openai/anthropic). Si l'utilisateur
    /// le change dans Réglages iOS → reset des compteurs (le nom du
    /// modèle entre parenthèses dans le panneau latéral n'aurait plus de
    /// rapport avec les chiffres affichés).
    @State private var lastSeenAIProvider: String =
        UserDefaults.standard.string(forKey: "describeImagesProvider") ?? "apple"
    /// Dernier modèle custom connu. Idem : un changement de modèle
    /// invalide les compteurs.
    @State private var lastSeenAIModel: String =
        UserDefaults.standard.string(forKey: "describeImagesModel") ?? ""
    // (appDataBytes, statsTick, appDataComputing déplacés dans
    // StatsPanelView pour que leurs mutations ne fassent re-rendre que
    // le panneau de statistiques — pas la toolbar avec ses Menus.)
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var folderToDelete: String? = nil

    @State private var fetchingDateIDs: Set<String> = []
    @State private var refreshTask: Task<Void, Never>? = nil
    // (Anciennement `@State blinkPhase: Bool` toggled par un Timer ; voir
    // l'extension `View.blinking()` plus bas.)
    @State private var geocodingIDs: Set<String> = []
    @State private var describingIDs: Set<String> = []
    @State private var generatingPreviewIDs: Set<String> = []
    /// Handles vers les Tasks en vol pour la génération d'aperçus,
    /// indexés par item.id. Permet de les annuler explicitement quand
    /// l'utilisateur fait « Clear previews of these URLs » → la roue
    /// disparaît immédiatement même si la capture WKWebView était
    /// suspendue depuis longtemps.
    @State private var previewTasks: [String: Task<Void, Never>] = [:]
    /// Handles vers les Tasks de description IA / transcription audio.
    @State private var aiTasks: [String: Task<Void, Never>] = [:]
    /// Handles vers les Tasks de fetch Last-Modified URL.
    @State private var dateFetchTasks: [String: Task<Void, Never>] = [:]
    /// Handles vers les Tasks de reverse-geocoding photos.
    @State private var geocodeTasks: [String: Task<Void, Never>] = [:]
    /// Handles vers les Tasks de fetch du <title> HTML d'une URL.
    @State private var titleFetchTasks: [String: Task<Void, Never>] = [:]
    /// Handles vers les Tasks d'OCR Vision (post-IA).
    @State private var ocrTasks: [String: Task<Void, Never>] = [:]
    /// Met en pause les auto-triggers (génération d'aperçus, IA, OCR,
    /// transcription audio) après un « Stop refreshing » : sans cette
    /// pause, le timer 100 ms relancerait immédiatement une nouvelle
    /// génération pour les items dont `previewPath == nil` etc., et
    /// la roue dentée réapparaîtrait. Le flag est remis à false dès
    /// qu'on relance un refresh explicite (pull-to-refresh, menu …,
    /// menu contextuel).
    @State private var autoTriggersPaused: Bool = false
    @State private var showPreviewsSheet: Bool = false
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
    /// Lecture du mode d'édition pour distinguer un tap "ouvrir l'item"
    /// d'un tap "modifier la sélection" — sans ça, iOS 17 garde le mode
    /// selection actif tant que la `selection` Set n'est pas vide, ce
    /// qui empêche `.onTapGesture` d'ouvrir une URL après une sortie
    /// d'edit mode laissant des items cochés.
    /// EditMode possédé par ContentView (et non pas fourni par SwiftUI
    /// via l'environnement). C'est obligatoire pour pouvoir le muter
    /// programmatiquement après une opération de batch (déplacement /
    /// suppression) : avec l'editMode système, l'écriture n'est pas
    /// honorée. Le binding est injecté dans l'environnement plus bas via
    /// `.environment(\.editMode, $editMode)`, ce qui fait que l'EditButton
    /// et le `List(selection:)` du detail view utilisent bien notre état.
    @State private var editMode: EditMode = .inactive
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass
    @State private var editingNoteItem: SharedItem? = nil
    @State private var smartFolder: SmartFolder? = nil
    @AppStorage("smartFoldersExpanded") private var smartFoldersExpanded: Bool = true
    /// Active la détection automatique de bordure monochrome dans les
    /// aperçus d'URL : si la capture WKWebView a une grosse bordure
    /// uniforme (ex. fond noir entourant un lecteur vidéo centré), on
    /// recadre sur la zone d'intérêt avant le `scaleAspectFit` final, ce
    /// qui agrandit visuellement le contenu utile dans l'aperçu
    /// 320×200. Activé par défaut — l'utilisateur peut décocher via le
    /// menu « ... » pour revenir au comportement historique.
    @AppStorage("autoCropMonochromePreviews") private var autoCropMonochromePreviews: Bool = true

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
        case all, recent7days, unreadURLs, withLocation, withAIOrOCR
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:          return String(localized: "All items")
            case .recent7days:  return String(localized: "Recent (7 days)")
            case .unreadURLs:   return String(localized: "Unread")
            case .withLocation: return String(localized: "With location")
            case .withAIOrOCR:  return String(localized: "With AI or OCR")
            }
        }
        var systemImage: String {
            switch self {
            case .all:          return "tray.full"
            case .recent7days:  return "clock.arrow.circlepath"
            case .unreadURLs:   return "circle.fill"
            case .withLocation: return "mappin.and.ellipse"
            case .withAIOrOCR:  return "sparkles"
            }
        }
    }
    /// Passe à true après le tout premier `loadItems()` afin que l'auto-fetch
    /// ne se déclenche que pour les items apparus APRÈS le démarrage.
    @State private var hasInitialized: Bool = false
    /// Cache des bytes JSON UserDefaults lus la dernière fois — sert à
    /// éviter le décode de tout le tableau d'items à chaque tick du
    /// timer 100 ms quand rien n'a changé. Cause majeure de CPU élevé
    /// après les opérations massives (clear AI generated text, etc.).
    @State private var lastLoadedItemsData: Data? = nil
    /// Dernier total de partages observé : sert à détecter les
    /// nouveaux partages (depuis le Share Extension) pendant que l'app
    /// est lancée pour proposer la fenêtre « Noter cette app » à chaque
    /// multiple de 10. Initialisé à la valeur courante au démarrage —
    /// donc jamais de prompt pour les partages déjà comptabilisés
    /// AVANT que l'utilisateur n'ouvre l'app.
    @State private var lastSeenShareCount: Int =
        UserDefaults(suiteName: "group.net.fenyo.apple.sharemanager")?
            .integer(forKey: "totalShareCount") ?? 0
    /// API SwiftUI standard pour proposer à l'utilisateur de noter
    /// l'app dans l'App Store (iOS 16+). iOS gère lui-même le
    /// throttling (max ~3 prompts par an). Pas de garantie d'affichage.
    @Environment(\.requestReview) private var requestReview

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
            case .withAIOrOCR:
                result = items.filter {
                    let k = $0.effectiveKind
                    guard k == "photo" || k == "video" else { return false }
                    return $0.aiDescribed == true || $0.ocrDone == true
                }
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
        .fullScreenCover(isPresented: $showPreviewsSheet) {
            PreviewsSheet(items: currentItems) { selected in
                showPreviewsSheet = false
                // Petit délai pour que le fullScreenCover ait fini de se
                // refermer avant de présenter la prochaine sheet (Safari /
                // QuickLook), sinon iOS peut rejeter la nouvelle modale.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    openItem(selected)
                }
            }
        }
        .overlay(alignment: .top) { themeOverlay }
        .overlay(alignment: .top) { refreshOverlay }
        .alert("Many AI calls", isPresented: $showAIRateWarning) {
            Button("Got it", role: .cancel) { }
        } message: {
            Text("You've made more than \(Self.aiRateLimitMaxCalls) AI requests in the last \(Self.aiRateLimitWindowMinutes) minutes. Each call costs API credits — please make sure this is intended. The counter has been reset.")
        }
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
            // Filet de sécurité défensif : un item dont le `folder` ne
            // correspond plus à aucun folder local est supprimé.
            // Normalement ne doit jamais arriver (deleteFolder retire
            // bien ses items, applyPulledChanges crée le folder avant
            // les items du cloud), mais en cas de bug le cleanup
            // évite des items « invisibles » bloqués dans une vue.
            cleanupOrphanItems()
            // Plus de refresh automatique au démarrage : l'utilisateur
            // doit explicitement tirer la liste vers le bas, ou choisir
            // « Refresh previews and URL dates » dans le menu …, ou
            // utiliser une entrée de menu contextuel sur une ligne.
            // CloudSync : on raffraichit le statut compte iCloud et on
            // tire le delta éventuel. Aucun trafic si l'utilisateur n'a
            // marqué aucun folder synced (refreshAccountStatus est gratuit ;
            // pullChanges ne fait rien tant que la zone n'a pas été créée).
            Task {
                await CloudSync.shared.refreshAccountStatus()
                await CloudSync.shared.pullChanges()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            loadItems()
            Task { await CloudSync.shared.pullChanges() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            loadItems()
            Task { await CloudSync.shared.pullChanges() }
        }
        // Poll iCloud toutes les 10 s tant que l'app est au premier
        // plan. Sans ce poll, les modifs faites sur un autre appareil
        // n'arrivent que via push silencieuse APNs (best-effort,
        // parfois 1 min de délai observé) ou via didBecomeActive.
        // PAS de gate « au moins un folder synced localement » : ça
        // créait un chicken-and-egg côté appareil receveur qui ne
        // connaissait jamais les folders synced d'un autre appareil
        // tant qu'il n'avait pas activé une sync lui-même. Une
        // requête CloudKit vide (token à jour) est triviale ; et
        // `pullChanges` se gate déjà sur `accountState == .available`
        // pour ne rien faire si iCloud n'est pas configuré.
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            Task { await CloudSync.shared.pullChanges() }
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            loadItems()
            // Recharge aussi la liste des dossiers depuis UserDefaults
            // App Group : CloudSync écrit directement dans cet espace
            // partagé quand il reçoit des Folder records via pull, sans
            // notifier ContentView. Sans ce reload périodique, l'@State
            // `folders` resterait obsolète et le folder pull-é depuis
            // un autre appareil n'apparaîtrait pas dans la sidebar.
            // loadFolders fait déjà `if loaded != folders` donc pas de
            // mutation @State inutile à chaque tick.
            loadFolders()
            if debugLogsEnabled { loadDebugLogs() }
            checkAIEnabledTransition()
            checkShareCountForReview()
        }
        // Recalcul de la taille du container App Group : SEULEMENT toutes
        // les 2 s. Avant on était à 100 ms, ce qui sur un container
        // contenant beaucoup de PNG/photos/vidéos lançait une traversée
        // récursive 10×/s — cause majeure de CPU constant en background,
        // particulièrement visible après « Clear AI-generated text » qui
        // multiplie les écritures dans le container. 2 s suffit largement
        // pour refléter un changement à l'œil nu.
        // Le timer du panneau de stats est désormais interne à
        // StatsPanelView (cf. plus bas). On ne le pose plus ici, car ses
        // mutations @State faisaient re-rendre tout ContentView (donc
        // les Menus de la toolbar) toutes les 2 s.
        // Note : on n'utilise PLUS de Timer.publish toggling un @State
        // blinkPhase global, parce que ça forçait l'ensemble du body de
        // ContentView à se ré-évaluer toutes les 600 ms — la toolbar et
        // ses Menus se reconstruisaient alors en permanence (« le menu
        // clignote »). Le clignotement des textes (« Describing… »,
        // « Fetching date… ») est désormais géré par `.blinking()` via
        // un TimelineView local à chaque texte concerné.
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
        .confirmationDialog(
            "Resync iCloud — confirm",
            isPresented: $showResyncConfirm,
            titleVisibility: .visible
        ) {
            Button("Resync iCloud") { runResyncReconcile() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Resync iCloud — body")
        }
        .confirmationDialog(
            "Delete local data — confirm",
            isPresented: $showDeleteLocalConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete only local data", role: .destructive) { deleteLocalData() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Delete local data — body")
        }
        .confirmationDialog(
            "Paste multiple URLs — confirm",
            isPresented: $showPasteMultipleConfirm,
            titleVisibility: .visible
        ) {
            Button("Paste all") {
                let urls = pendingPasteURLs
                pendingPasteURLs = []
                insertPastedURLs(urls)
            }
            Button("Cancel", role: .cancel) {
                pendingPasteURLs = []
            }
        } message: {
            Text("\(pendingPasteURLs.count) URLs were found in the clipboard.")
        }
    }

    /// Host invisible qui exécute la traduction on-device des labels Vision
    /// sur iOS 18+. Inutile (no-op) sur les versions antérieures.
    @ViewBuilder
    private var labelTranslatorHost: some View {
        if #available(iOS 18.0, *) {
            LabelTranslator(pending: $pendingLabelTranslations,
                            onTranslated: { id, translated in
                                updateItemTitle(id: id, to: translated)
                                markTranslationDone(id: id)
                                updateBackgroundTasksCount()
                            },
                            onFailed: { id in
                                // Échec de la traduction : on marque
                                // quand même `translationDone = true`
                                // pour ne pas retry indéfiniment au
                                // prochain refresh. L'utilisateur peut
                                // forcer via 1J / 1D.
                                markTranslationDone(id: id)
                                updateBackgroundTasksCount()
                            })
        }
    }

    private func markTranslationDone(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].translationDone = true
        saveItems()
    }

    // MARK: - AI counters & app data size

    /// Surveille le compteur global de partages (clé `totalShareCount`
    /// dans le UserDefaults App Group). Quand un nouveau partage arrive
    /// pendant que l'app tourne ET que le total franchit un multiple de
    /// 10, demande à iOS d'afficher la feuille « Noter cette app ».
    /// iOS throttle l'affichage (~3 fois max par an), donc l'appel peut
    /// être no-op silencieusement.
    private func checkShareCountForReview() {
        guard let d = UserDefaults(suiteName: appGroup) else { return }
        let current = d.integer(forKey: "totalShareCount")
        guard current > lastSeenShareCount else { return }
        // Pour être robuste si plusieurs partages arrivent entre deux
        // ticks (rare mais possible), on regarde si AU MOINS un
        // multiple de 10 est franchi entre lastSeen+1 et current.
        let crossed = (lastSeenShareCount / 10) != (current / 10) && current > 0
        lastSeenShareCount = current
        if crossed {
            // Légère attente pour laisser SwiftUI finir son cycle
            // avant de déclencher la modale système.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                requestReview()
            }
        }
    }

    /// Détecte trois types de changements faits depuis Réglages iOS qui
    /// invalident les compteurs IA et déclenchent un reset :
    /// 1. `describeImagesEnabled` passe à false (IA désactivée).
    /// 2. `describeImagesProvider` change (OpenAI ↔ Anthropic ↔ Apple).
    /// 3. `describeImagesModel` change (nouveau modèle custom).
    /// Sans (2) et (3), le panneau latéral afficherait des compteurs
    /// agrégés sur des modèles différents avec un seul nom de modèle
    /// entre parenthèses → trompeur.
    private func checkAIEnabledTransition() {
        let d = UserDefaults.standard
        let nowEnabled = d.bool(forKey: "describeImagesEnabled")
        let nowProvider = d.string(forKey: "describeImagesProvider") ?? "apple"
        let nowModel = d.string(forKey: "describeImagesModel") ?? ""

        let toggledOff = lastSeenAIEnabled && !nowEnabled
        let providerChanged = (lastSeenAIProvider != nowProvider)
        let modelChanged = (lastSeenAIModel != nowModel)

        if toggledOff || providerChanged || modelChanged {
            AICounters.resetAll()
        }
        if lastSeenAIEnabled != nowEnabled { lastSeenAIEnabled = nowEnabled }
        if lastSeenAIProvider != nowProvider { lastSeenAIProvider = nowProvider }
        if lastSeenAIModel != nowModel { lastSeenAIModel = nowModel }
    }

    // (recomputeAppDataBytes a été déplacé dans StatsPanelView, qui
    // possède son propre @State et son propre timer. Cela isole les
    // mutations @State liées aux stats du body de ContentView, qui
    // n'est donc plus re-rendu toutes les 2 s.)

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 12) {
            sidebarList
            statsPanel
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background(Color(.systemGroupedBackground))
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

    @ViewBuilder
    private var sidebarList: some View {
        List(selection: $selectedFolder) {
            Section {
                Button {
                    smartFoldersExpanded.toggle()
                } label: {
                    HStack {
                        Label("Smart Views", systemImage: "sparkles")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(smartFoldersExpanded ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if smartFoldersExpanded {
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
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            Section("Folders") {
                ForEach(folders) { folder in
                    HStack {
                        Image(systemName: folderRowIcon(for: folder))
                        Text(displayName(forFolder: folder.name))
                        Spacer()
                        Text("\(items.filter { $0.folder == folder.name }.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    .tag(folder.name)
                    .contextMenu {
                        if folder.name != StoreKeys.defaultFolder {
                            if folder.iCloudSynced {
                                Button {
                                    stopICloudSync(forFolder: folder.name)
                                } label: {
                                    Label("Stop iCloud sync", systemImage: "icloud.slash")
                                }
                            } else {
                                Button {
                                    startICloudSync(forFolder: folder.name)
                                } label: {
                                    Label("Sync to iCloud", systemImage: "icloud.and.arrow.up")
                                }
                            }
                            Button(role: .destructive) {
                                folderToDelete = folder.name
                            } label: {
                                Label("Delete Folder", systemImage: "trash")
                            }
                        }
                    }
                    // Cible de drop pour les items glissés depuis la
                    // liste de droite (iPad uniquement). Les Smart Views
                    // ne sont pas concernées (elles ne sont pas dans ce
                    // ForEach).
                    .dropDestination(for: ItemDragPayload.self) { payloads, _ in
                        guard UIDevice.current.userInterfaceIdiom == .pad,
                              let payload = payloads.first else { return false }
                        moveItemsToFolder(ids: payload.ids, to: folder.name)
                        return true
                    }
                }
                .onMove(perform: moveFolders)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: smartFoldersExpanded)
        .refreshable {
            await pullToRefreshICloud()
        }
    }

    // MARK: - Stats panel (sidebar bottom)

    @ViewBuilder
    private var statsPanel: some View {
        // Délégation à `StatsPanelView` qui possède son propre @State :
        // ses re-renders périodiques (timer toutes les 2 s pour la taille
        // du container et les compteurs IA) restent confinés à ce
        // sous-arbre et ne déclenchent PAS de re-render de la toolbar de
        // ContentView (donc plus de clignotement des Menus).
        StatsPanelView(
            appGroup: appGroup,
            onDeleteLocalData: { showDeleteLocalConfirm = true },
            onResyncICloud: { showResyncConfirm = true },
            onResetAICounters: {
                AICounters.resetAll()
                resetPerItemAICallLimits()
            }
        )
    }

    private func smartCount(_ sf: SmartFolder) -> Int {
        switch sf {
        case .all:          return items.count
        case .recent7days:  let c = Date().timeIntervalSince1970 - 7 * 86400; return items.filter { $0.timestamp >= c }.count
        case .unreadURLs:   return items.filter { isUnread($0) }.count
        case .withLocation: return items.filter { $0.latitude != nil && $0.longitude != nil }.count
        case .withAIOrOCR:
            return items.filter {
                let k = $0.effectiveKind
                guard k == "photo" || k == "video" else { return false }
                return $0.aiDescribed == true || $0.ocrDone == true
            }.count
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            VStack(spacing: 0) {
                filterBanner
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.5), value: filterIsActive)
                ZStack {
                    if currentItems.isEmpty {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            emptyState
                            Spacer(minLength: 0)
                        }
                        .transition(.opacity)
                    } else {
                        List(selection: $selection) {
                            ForEach(currentItems) { item in
                                itemRow(item)
                                    .tag(item.id)
                                    .modifier(ItemDragModifier(item: item, selection: selection))
                            }
                            .onDelete(perform: deleteItems)
                            // Le drag-to-move n'a de sens que dans le
                            // tri « ordre manuel » (= insertion) :
                            // dans tous les autres tris (date, titre,
                            // source), réordonner ne donne aucun
                            // effet visible puisque le tri se réapplique
                            // immédiatement. Disponible aussi bien
                            // dans les vues intelligentes que dans les
                            // dossiers, tant que le tri est manuel.
                            .onMove(perform: sortOrder == .insertion ? moveItems : nil)
                        }
                        .environment(\.editMode, $editMode)
                        .animation(.easeInOut(duration: 0.5), value: typeFilter)
                        .animation(.easeInOut(duration: 0.5), value: currentItems.count)
                        .refreshable {
                            await pullToRefreshDates()
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.5), value: currentItems.isEmpty)
            }
        }
        .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always))
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .navigationTitle(detailTitle)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(FilterToolbarBackground(active: filterIsActiveExcludingSearch))
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    changeColorSchemePreference()
                } label: {
                    Image(systemName: colorSchemePreference == 1 ? "moon.fill" : colorSchemePreference == 2 ? "sun.max.fill" : "circle.lefthalf.filled")
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                // Bouton Edit custom — pilote directement notre @State
                // `editMode`. On n'utilise PAS `EditButton()` car celui-ci
                // est rendu dans la couche toolbar de SwiftUI, hors de la
                // hiérarchie d'environnement classique, et ignore parfois
                // un `.environment(\.editMode, $...)` posé plus haut →
                // impossible alors de sortir du mode Edit programma-
                // tiquement après une opération de batch.
                Button {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                    if !editMode.isEditing { selection.removeAll() }
                } label: {
                    Text(editMode.isEditing ? "Done" : "Edit")
                }
                .disabled(items.isEmpty)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                filterSortMenu
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                settingsMenu
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        clearPreviewsForCurrent()
                    } label: {
                        Label("Clear previews of these URLs", systemImage: "rectangle.dashed")
                    }
                    Button {
                        clearAITextForCurrent()
                    } label: {
                        Label("Clear AI-generated text of these items", systemImage: "text.badge.xmark")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("Delete these items", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(currentItems.isEmpty)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                // Sur iPhone portrait, on retire ce bouton de la toolbar
                // pour libérer de la place : l'action est dupliquée dans
                // le menu « … ». Sur iPad ou iPhone paysage il reste
                // visible. Pour permettre une déclaration conditionnelle
                // sans casser la structure du toolbar, on remplace le
                // bouton par un EmptyView quand on est en iPhone portrait.
                if isIPhonePortrait {
                    EmptyView()
                } else {
                    Button {
                        showPreviewsSheet = true
                    } label: {
                        Image(systemName: "rectangle.grid.2x2")
                    }
                    .disabled(items.isEmpty)
                }
            }
            // Bottom bar pour les opérations en lot quand selection non vide
            ToolbarItemGroup(placement: .bottomBar) {
                if !selection.isEmpty {
                    Menu {
                        ForEach(folders) { folder in
                            Button {
                                moveSelected(to: folder.name)
                            } label: {
                                Label(displayName(forFolder: folder.name),
                                      systemImage: folderRowIcon(for: folder))
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

    /// Variante n'incluant PAS la recherche : utilisée pour conditionner
    /// le fond de la toolbar. Toute mutation de la toolbar pendant que la
    /// barre de recherche a le focus la fait perdre le focus (iOS interprète
    /// alors la fin d'édition comme un Enter), donc on ne touche pas au
    /// fond quand l'utilisateur tape juste dans la recherche.
    private var filterIsActiveExcludingSearch: Bool {
        typeFilter != "all" || sortOrder != .insertion
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
            .padding(.top, 8)
            .padding(.bottom, 28)
            .background(
                LinearGradient(
                    colors: [Color.blue.opacity(0.16), Color(.systemGroupedBackground)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
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
                    Text(label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Button("Reset view") {
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

    /// Vrai si la liste actuellement affichée contient au moins un
    /// item passible d'IA (photo / video → description, audio →
    /// transcription). Sert à n'afficher l'entrée « Refresh AI text »
    /// du menu … que quand elle a du sens.
    private var hasAIItems: Bool {
        currentItems.contains {
            let k = $0.effectiveKind
            return k == "photo" || k == "video" || k == "audio"
        }
    }

    /// iPhone en mode portrait : la toolbar n'a plus de place pour le
    /// bouton « gallery » indépendant, donc on déplace l'action dans le
    /// menu « … ». Sur iPad ou iPhone paysage, on garde le bouton
    /// dédié dans la toolbar.
    private var isIPhonePortrait: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
            && vSizeClass == .regular
    }

    private var settingsMenu: some View {
        Menu {
            Button {
                pasteAsItem()
            } label: {
                Label("Paste URL from clipboard", systemImage: "doc.on.clipboard")
            }
            Divider()
            if isIPhonePortrait {
                Button {
                    showPreviewsSheet = true
                } label: {
                    Label("Preview gallery", systemImage: "rectangle.grid.2x2")
                }
                .disabled(items.isEmpty)
                Divider()
            }
            if hasURLItems {
                Button {
                    toggleRefreshAllDates()
                } label: {
                    if hasAnyActiveRefresh {
                        Label("Stop refreshing previews and URL dates", systemImage: "stop.circle")
                    } else {
                        Label("Refresh previews and URL dates", systemImage: "arrow.clockwise")
                    }
                }
            }
            if hasAIItems {
                Button {
                    refreshAITextForCurrent()
                } label: {
                    Label("Refresh AI text", systemImage: "sparkles")
                }
            }
            if hasURLItems || hasAIItems {
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
            Button(role: .destructive) {
                showDeleteLocalConfirm = true
            } label: {
                Label("Delete only local data", systemImage: "trash")
            }
            if !AICounters.providersWithCalls().isEmpty {
                Divider()
                Button(role: .destructive) {
                    AICounters.resetAll()
                    resetPerItemAICallLimits()
                } label: {
                    Label("Reset AI counters", systemImage: "gauge.with.dots.needle.0percent")
                }
            }
            Divider()
            Toggle(isOn: $autoCropMonochromePreviews) {
                Label("Auto-crop URL previews", systemImage: "viewfinder")
            }
            if hasUnlockedURLInCurrent {
                Button {
                    lockPreviewsForCurrent()
                } label: {
                    Label("Lock previews of these URLs", systemImage: "lock")
                }
            }
            if hasLockedURLInCurrent {
                Button {
                    unlockPreviewsForCurrent()
                } label: {
                    Label("Unlock previews of these URLs", systemImage: "lock.open")
                }
            }
            if hasURLItemsInCurrent {
                Button {
                    zoomPreviewsForCurrent()
                } label: {
                    Label("Zoom previews of these URLs", systemImage: "plus.magnifyingglass")
                }
                Button {
                    unzoomPreviewsForCurrent()
                } label: {
                    Label("Unzoom previews of these URLs", systemImage: "minus.magnifyingglass")
                }
            }
            Divider()
            // « Resync iCloud » : remède utilisateur en cas
            // d'incohérence local/cloud (token corrompu, items
            // orphelins, folder absent d'un côté, etc.). Toujours
            // visible : l'opération est globale, pas spécifique à un
            // folder. Si aucun folder n'est synchronisé, la resync
            // se contente de nettoyer d'éventuels orphelins cloud
            // et de réimporter ce que le cloud contient.
            // Contrairement à « Reset iCloud sync state » (réservé
            // au debug), cette opération ne détruit pas le contenu :
            // elle réconcilie en gardant le maximum.
            Button {
                showResyncConfirm = true
            } label: {
                Label("Resync iCloud", systemImage: "arrow.triangle.2.circlepath.icloud")
            }
            .disabled(isResyncing)
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
                // Reset complet de l'état CloudKit pour repartir
                // from-scratch en debug : supprime la zone côté serveur
                // (cascade-delete des records) + efface tokens et
                // drapeaux locaux. Met aussi tous les folders locaux en
                // local-only (drapeau `iCloudSynced = false`).
                Button(role: .destructive) {
                    resetICloudSyncState()
                } label: {
                    Label("Reset iCloud sync state", systemImage: "icloud.slash.fill")
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

    /// Vrai si l'item a un aperçu généré et exploitable
    /// (`previewPath` non nil ET non vide).
    private func hasUsablePreview(_ item: SharedItem) -> Bool {
        if let p = item.previewPath, !p.isEmpty { return true }
        return false
    }

    /// Vrai si une « regénération d'aperçu » a un sens pour cet item :
    /// les types audio et texte n'ont rien d'utile à recapturer.
    private func canRegeneratePreview(_ item: SharedItem) -> Bool {
        let k = item.effectiveKind
        return k != "audio" && k != "text"
    }

    /// Vrai si on génère un texte via IA pour cet item (description IA
    /// pour photo/video, transcription pour audio).
    private func hasAIGeneratedText(_ item: SharedItem) -> Bool {
        let k = item.effectiveKind
        return k == "photo" || k == "video" || k == "audio"
    }

    /// Vrai si une opération asynchrone est en cours pour cet item :
    /// description IA, OCR (qui partage `describingIDs` via le pipeline
    /// audio aussi), génération d'aperçu, fetch de date URL, ou
    /// reverse geocoding photo. Sert à faire clignoter l'icône de la
    /// ligne tant que ça travaille.
    private func isItemBusy(_ item: SharedItem) -> Bool {
        return describingIDs.contains(item.id)
            || generatingPreviewIDs.contains(item.id)
            || fetchingDateIDs.contains(item.id)
            || geocodingIDs.contains(item.id)
    }

    @ViewBuilder
    private func itemRow(_ item: SharedItem) -> some View {
        let kind = item.effectiveKind
        let linkURL = URL(string: item.url)

        VStack(alignment: .leading, spacing: 6) {
            switch kind {
            case "file":
                HStack(spacing: 8) {
                    if isItemBusy(item) {
                        SpinningGear(color: .blue)
                    } else {
                        Image(systemName: "doc.fill")
                            .foregroundColor(.blue)
                    }
                    let unread = isUnread(item)
                    Text(item.title ?? linkURL?.lastPathComponent ?? item.url)
                        .font(.subheadline)
                        .fontWeight(unread ? .bold : .medium)
                        .foregroundColor(unread ? .unreadBordeaux : .primary)
                        .lineLimit(2)
                }
            case "photo":
                HStack(spacing: 8) {
                    if isItemBusy(item) {
                        SpinningGear(color: .indigo)
                    } else {
                        Image(systemName: "photo.fill")
                            .foregroundColor(.indigo)
                    }
                    if describingIDs.contains(item.id) {
                        Text("Describing image…")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .blinking()
                    } else {
                        let unread = isUnread(item)
                        Text(item.title ?? linkURL?.lastPathComponent ?? item.url)
                            .font(.subheadline)
                            .fontWeight(unread ? .bold : .medium)
                            .foregroundColor(unread ? .unreadBordeaux : .primary)
                            .lineLimit(2)
                    }
                }
            case "video":
                HStack(spacing: 8) {
                    if isItemBusy(item) {
                        SpinningGear(color: .red)
                    } else {
                        Image(systemName: "video.fill")
                            .foregroundColor(.red)
                    }
                    if describingIDs.contains(item.id) {
                        Text("Describing video…")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .blinking()
                    } else {
                        let unread = isUnread(item)
                        Text(item.title ?? linkURL?.lastPathComponent ?? item.url)
                            .font(.subheadline)
                            .fontWeight(unread ? .bold : .medium)
                            .foregroundColor(unread ? .unreadBordeaux : .primary)
                            .lineLimit(2)
                    }
                }
            case "audio":
                HStack(spacing: 8) {
                    if isItemBusy(item) {
                        SpinningGear(color: .teal)
                    } else {
                        Image(systemName: "waveform")
                            .foregroundColor(.teal)
                    }
                    if describingIDs.contains(item.id) {
                        Text("Transcribing audio…")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .blinking()
                    } else {
                        let unread = isUnread(item)
                        Text(item.title ?? linkURL?.lastPathComponent ?? item.url)
                            .font(.subheadline)
                            .fontWeight(unread ? .bold : .medium)
                            .foregroundColor(unread ? .unreadBordeaux : .primary)
                            .lineLimit(2)
                    }
                }
            case "text":
                HStack(alignment: .top, spacing: 8) {
                    if isItemBusy(item) {
                        SpinningGear(color: .orange)
                    } else {
                        Image(systemName: "text.alignleft")
                            .foregroundColor(.orange)
                    }
                    let unread = isUnread(item)
                    Text(item.title ?? String(item.url.prefix(80)))
                        .font(.subheadline)
                        .fontWeight(unread ? .bold : .medium)
                        .foregroundColor(unread ? .unreadBordeaux : .primary)
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
                    if isItemBusy(item) {
                        SpinningGear(color: .urlAccent)
                    } else {
                        Image(systemName: "globe")
                            .foregroundColor(.urlAccent)
                    }
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

            // Quand l'utilisateur a sélectionné une vue intelligente
            // (smartFolder != nil), les items affichés peuvent venir
            // de n'importe quel dossier — on indique donc le dossier
            // d'appartenance à droite du « From: ... ».
            if item.sourceApp != nil || smartFolder != nil {
                HStack(spacing: 8) {
                    if let sourceApp = item.sourceApp {
                        HStack(spacing: 4) {
                            Image(systemName: "app.badge")
                                .font(.caption2)
                            Text("From: \(sourceApp)")
                                .font(.caption2)
                        }
                    }
                    if smartFolder != nil {
                        HStack(spacing: 4) {
                            Image(systemName: folderRowIcon(forName: item.folder))
                                .font(.caption2)
                            Text(displayName(forFolder: item.folder))
                                .font(.caption2)
                        }
                    }
                }
                .foregroundColor(.blue)
                .padding(.top, 2)
            }

            dateRow(for: item)
            placeRow(for: item)
            noteRow(for: item)
            if aiCallsHardCapped(item) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("Limit of \(Self.aiCallsLimit) AI calls reached for this item — no further AI invocations.")
                        .font(.caption2)
                        .lineLimit(2)
                }
                .foregroundColor(.orange)
                .padding(.top, 2)
            } else if item.aiFailed == true {
                // Indicateur d'échec IA distinct du cas « cap atteint ».
                // L'utilisateur peut retenter via le menu contextuel
                // « Regenerate AI text ».
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                    Text("AI text generation failed — use the context menu to retry.")
                        .font(.caption2)
                        .lineLimit(2)
                }
                .foregroundColor(.orange)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        // Réserve à droite pour que le texte ne passe jamais sous la
        // aperçu : largeur fixe + écart standard de respiration.
        .padding(.trailing, hasUsablePreview(item) ? 128 : 0)
        // On force toutes les lignes (qui ont un aperçu) à une hauteur
        // minimale qui correspond à celle de l'aperçu + un écart
        // standard de 6 pt en haut et en bas → tous les aperçus
        // mesurent la MÊME hauteur, et celle-ci est aussi grande que le
        // raisonnable sans pour autant déborder sur la ligne suivante.
        .frame(maxWidth: .infinity,
               minHeight: hasUsablePreview(item) ? 84 : 0,
               alignment: .leading)
        // Aperçu à droite, TAILLE FIXE 112×70 (ratio 320/200 = 1.6).
        // L'overlay ne participe pas au layout du parent et le minHeight
        // ci-dessus garantit qu'il y a au moins 70 + 14 = 84 pt de
        // hauteur disponible.
        .overlay(alignment: .trailing) {
            if hasUsablePreview(item) {
                RowThumbnail(item: item)
                    .frame(width: 112, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
                    )
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            openItem(item)
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
            } else if kind == "text" {
                Button {
                    UIPasteboard.general.string = item.url
                } label: {
                    Label("Copy text", systemImage: "doc.on.doc")
                }
            }
            // « Mark as unread » disponible pour TOUS les types
            // d'objets (l'état non-lu n'est plus réservé aux URL).
            // Exposé seulement quand l'item est actuellement « lu » et
            // qu'on a une `modifiedAt` connue (sinon le clic
            // resterait sans effet visible).
            if !isUnread(item) && item.modifiedAt != nil {
                Button {
                    markAsUnread(itemID: item.id)
                } label: {
                    Label("Mark as unread", systemImage: "circle.inset.filled")
                }
            }
            // Re-partage via la feuille système iOS
            shareLinkForItem(item)
            if folders.count > 1 {
                Menu {
                    ForEach(folders) { folder in
                        if folder.name != item.folder {
                            Button {
                                moveItem(item, to: folder.name)
                            } label: {
                                Label(displayName(forFolder: folder.name),
                                      systemImage: folderRowIcon(for: folder))
                            }
                        }
                    }
                } label: {
                    Label("Move to…", systemImage: "folder")
                }
            }
            if aiCallsHardCapped(item) {
                Button {
                    resetItemAICalls(item)
                } label: {
                    Label("Reset AI call limit", systemImage: "arrow.counterclockwise")
                }
            }
            // Verrouillage de la preview, réservé aux URLs (pour les
            // autres types, l'aperçu est triviale à régénérer et
            // n'a pas besoin d'être protégée). Affiche UNIQUEMENT
            // l'action utile : « Lock » si non verrouillée, sinon
            // « Unlock ».
            if item.effectiveKind == "url" {
                Button {
                    togglePreviewLock(for: item)
                } label: {
                    if item.previewLocked == true {
                        Label("Unlock preview", systemImage: "lock.open")
                    } else {
                        Label("Lock preview", systemImage: "lock")
                    }
                }
                Button {
                    togglePreviewZoom(for: item)
                } label: {
                    if item.previewZoomed == true {
                        Label("Unzoom preview", systemImage: "minus.magnifyingglass")
                    } else {
                        Label("Zoom preview", systemImage: "plus.magnifyingglass")
                    }
                }
            }
            // « Regénérer l'aperçu » au sens large : générer s'il n'y
            // en a pas encore, regénérer s'il y en a déjà une. Toujours
            // proposé pour les types qui supportent un aperçu
            // (canRegeneratePreview = pas audio, pas texte). Désactivé
            // quand la preview est verrouillée.
            if canRegeneratePreview(item) && item.previewLocked != true {
                Button {
                    regeneratePreview(for: item)
                } label: {
                    if item.effectiveKind == "url" {
                        Label("Regenerate preview and date", systemImage: "rectangle.dashed")
                    } else {
                        Label("Regenerate preview", systemImage: "rectangle.dashed")
                    }
                }
            }
            // « Regénérer le texte IA » : disponible pour les types qui
            // passent par une IA (photo/video → description, audio →
            // transcription). Compteur per-item respecté ensuite.
            if hasAIGeneratedText(item) {
                Button {
                    regenerateAIText(for: item)
                } label: {
                    Label("Regenerate AI text", systemImage: "text.badge.xmark")
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

    // MARK: - AI rate-limit guard

    /// Seuil global d'appels IA cloud (toutes invocations confondues)
    /// au-delà duquel l'app prévient l'utilisateur. Window glissante de
    /// `aiRateLimitWindowMinutes` minutes.
    static let aiRateLimitMaxCalls: Int = 20
    static let aiRateLimitWindowMinutes: Int = 5

    /// Décode les entités HTML (`&amp;`, `&quot;`, `&#39;`, `&#x27;`,
    /// etc.) dans une chaîne. Utilisé pour les titres `<title>`
    /// extraits du HTML brut côté `fetchTitle` ainsi qu'à la migration
    /// initiale des titres déjà stockés (entités résiduelles d'avant
    /// l'ajout du décodage). Léger : pas de WebKit, juste un parser
    /// linéaire sur les noms d'entités courants et les références
    /// numériques `&#NNN;` / `&#xNN;`.
    static func decodeHTMLEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: String] = [
            "amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">",
            "nbsp": "\u{00A0}", "hellip": "…", "mdash": "—", "ndash": "–",
            "laquo": "«", "raquo": "»", "copy": "©", "reg": "®", "trade": "™",
            "ldquo": "\u{201C}", "rdquo": "\u{201D}",
            "lsquo": "\u{2018}", "rsquo": "\u{2019}",
            "bull": "•", "middot": "·", "deg": "°",
            "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
            "times": "×", "divide": "÷", "plusmn": "±",
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        ]
        var result = ""
        result.reserveCapacity(s.count)
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if ch == "&",
               let semi = s[idx...].prefix(20).firstIndex(of: ";") {
                let entity = String(s[s.index(after: idx)..<semi])
                if entity.hasPrefix("#") {
                    let numPart = entity.dropFirst()
                    let scalar: Unicode.Scalar?
                    if numPart.first == "x" || numPart.first == "X" {
                        let hex = String(numPart.dropFirst())
                        scalar = UInt32(hex, radix: 16).flatMap { Unicode.Scalar($0) }
                    } else {
                        scalar = UInt32(numPart).flatMap { Unicode.Scalar($0) }
                    }
                    if let scalar {
                        result.append(Character(scalar))
                        idx = s.index(after: semi)
                        continue
                    }
                } else if let replacement = named[entity] {
                    result.append(replacement)
                    idx = s.index(after: semi)
                    continue
                }
            }
            result.append(ch)
            idx = s.index(after: idx)
        }
        return result
    }

    /// Enregistre un appel IA cloud, purge la fenêtre glissante et
    /// déclenche l'alerte (en remettant le compteur à zéro) si on dépasse
    /// le seuil.
    private func recordAICall() {
        let now = Date()
        let window = TimeInterval(Self.aiRateLimitWindowMinutes * 60)
        let cutoff = now.addingTimeInterval(-window)
        aiCallTimestamps.removeAll(where: { $0 < cutoff })
        aiCallTimestamps.append(now)
        if aiCallTimestamps.count > Self.aiRateLimitMaxCalls {
            aiCallTimestamps.removeAll()
            showAIRateWarning = true
        }
    }

    // MARK: - Pull-to-refresh announcement overlay

    /// Déclenche l'overlay « Refreshing » avec auto-disparition (mêmes
    /// timings que themeOverlay → 1,6 s avant fade out). Le paramètre
    /// `subtitleKey` permet de différencier le pull-to-refresh items
    /// (texte par défaut) du pull-to-refresh sidebar (texte iCloud).
    private func showRefreshAnnouncement(
        subtitleKey: LocalizedStringKey = "Updating missing previews and URL dates"
    ) {
        refreshAnnouncementSubtitle = subtitleKey
        withAnimation(.spring(duration: 0.25)) {
            refreshAnnouncement = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeInOut(duration: 0.3)) {
                refreshAnnouncement = false
            }
        }
    }

    @ViewBuilder
    private var refreshOverlay: some View {
        if refreshAnnouncement {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Refreshing")
                        .fontWeight(.semibold)
                }
                Text(refreshAnnouncementSubtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
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
                        HStack(spacing: 8) {
                            Button("Clear Logs") {
                                clearDebugLogs()
                                loadDebugLogs()
                            }
                            .buttonStyle(.bordered)
                            Button {
                                UIPasteboard.general.string = debugLogs
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .disabled(debugLogs.isEmpty)
                        }
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
                            // `TextEditor` (lecture seule via .disabled
                            // sur le binding) permet la sélection
                            // native iOS + le menu Copy. Hauteur calée
                            // sur le contenu via .scrollDisabled pour
                            // garder le scroll global de la ScrollView
                            // englobante.
                            TextEditor(text: .constant(debugLogs))
                                .scrollDisabled(true)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 200)
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

        // Migration one-shot : décode les entités HTML (`&amp;`,
        // `&quot;`, etc.) qui ont pu être stockées dans les titres
        // d'items récupérés avant l'ajout du décodage côté
        // `fetchTitle`. Idempotent (décoder une chaîne déjà décodée
        // est un no-op), mais on gate sur un drapeau pour éviter
        // de re-décoder tous les items à chaque démarrage.
        if !defaults.bool(forKey: "htmlEntitiesTitleMigrationDone"),
           let data = defaults.data(forKey: StoreKeys.items),
           var arr = try? JSONDecoder().decode([SharedItem].self, from: data) {
            var changed = false
            for i in arr.indices {
                if let t = arr[i].title, t.contains("&") {
                    let decoded = Self.decodeHTMLEntities(t)
                    if decoded != t { arr[i].title = decoded; changed = true }
                }
            }
            if changed, let newData = try? JSONEncoder().encode(arr) {
                defaults.set(newData, forKey: StoreKeys.items)
            }
            defaults.set(true, forKey: "htmlEntitiesTitleMigrationDone")
        }

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

        guard let data = defaults.data(forKey: StoreKeys.items) else {
            if !items.isEmpty { items = [] }
            if !hasInitialized { hasInitialized = true }
            return
        }

        // Skip décode JSON quand les bytes du UserDefaults sont
        // identiques à la dernière lecture. Sans ce shortcut on
        // décodait l'ENTIER tableau d'items 10 fois par seconde, ce qui
        // sur des collections riches (titres IA, ocrDone, previewPath…)
        // peut prendre plusieurs ms par tick → CPU constant en fond.
        let dataChanged = (data != lastLoadedItemsData)
        let previousIDs = Set(items.map(\.id))
        let didChange: Bool
        let loaded: [SharedItem]

        if dataChanged {
            guard let decoded = try? JSONDecoder().decode([SharedItem].self, from: data) else {
                if !hasInitialized { hasInitialized = true }
                return
            }
            loaded = decoded
            lastLoadedItemsData = data
            didChange = (loaded != items)
            if didChange { items = loaded }
        } else {
            // Bytes inchangés → la liste est déjà à jour, on ne décode
            // pas. On passe quand même par les triggers (ils ne font rien
            // si tout est déjà traité, mais détectent par exemple les
            // tâches en cours qui terminent).
            loaded = items
            didChange = false
        }

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
        triggerPendingAudioTranscriptions()
        triggerPendingPreviews()
        // Spotlight : on ne ré-indexe QUE si les items ont effectivement
        // changé. Sans cette garde, le timer 100 ms hammerait
        // CSSearchableIndex 10 fois par seconde → CPU constant en
        // background.
        if didChange { Spotlight.index(items) }
    }

    private func triggerPendingAIDescriptions() {
        guard !autoTriggersPaused else { return }
        guard UserDefaults.standard.bool(forKey: "describeImagesEnabled") else { return }
        let provider = UserDefaults.standard.string(forKey: "describeImagesProvider") ?? "anthropic"
        let apiKey = (UserDefaults.standard.string(forKey: "describeImagesAPIKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let customModel = (UserDefaults.standard.string(forKey: "describeImagesModel") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Apple Intelligence (on-device Vision) n'a pas besoin de clé.
        if provider != "apple" && apiKey.isEmpty { return }

        for item in items where (item.effectiveKind == "photo" || item.effectiveKind == "video")
                                && item.aiDescribed != true
                                && !describingIDs.contains(item.id)
                                && !aiCallsCapped(item, provider: provider) {
            startAIDescribe(item: item, provider: provider, apiKey: apiKey, customModel: customModel)
        }
    }

    private func saveItems(_ newItems: [SharedItem]? = nil) {
        let toSave = newItems ?? items
        guard let defaults, let data = try? JSONEncoder().encode(toSave) else { return }
        defaults.set(data, forKey: StoreKeys.items)
        // Coalesce les reloads widget : pendant un re-traitement IA on
        // pouvait appeler `reloadAllTimelines()` des dizaines de fois par
        // seconde, ce qui sature WidgetKit côté système. On planifie au
        // plus un reload toutes les 2 s.
        scheduleWidgetReload()
        // Notifie CloudSync : il calculera le diff vs son snapshot
        // interne et pushera (1 s de debouncing) ; aucun trafic
        // CloudKit tant qu'aucun folder n'est marqué synced.
        let foldersSnap = folders
        let itemsSnap = toSave
        Task { await CloudSync.shared.snapshotChanged(folders: foldersSnap, items: itemsSnap) }
    }

    private func scheduleWidgetReload() {
        WidgetReloadCoordinator.shared.schedule()
    }

    /// Charge la liste des dossiers depuis `UserDefaults`. Gère deux
    /// formats pour la rétro-compatibilité :
    ///   1. Nouveau (`Data` encodant `[Folder]`) — depuis l'ajout de
    ///      la sync iCloud par-dossier.
    ///   2. Legacy (`[String]` simple) — utilisé avant l'ajout de
    ///      `Folder`. Migré en `[Folder]` avec `iCloudSynced = false`.
    private func loadFolders() {
        guard let defaults else { return }
        var loaded: [Folder] = []
        if let data = defaults.data(forKey: StoreKeys.folders),
           let decoded = try? JSONDecoder().decode([Folder].self, from: data) {
            loaded = decoded
        } else if let legacy = defaults.stringArray(forKey: StoreKeys.folders) {
            // Migration depuis l'ancien format [String].
            loaded = legacy.enumerated().map { idx, name in
                Folder(name: name, iCloudSynced: false, sortIndex: Double(idx))
            }
        }
        // S'assure que `Default` est présent et figure en tête.
        if !loaded.contains(where: { $0.name == StoreKeys.defaultFolder }) {
            loaded.insert(Folder.systemDefault(), at: 0)
        }
        if loaded.isEmpty {
            loaded = [Folder.systemDefault()]
        }
        if loaded != folders { folders = loaded }
    }

    private func saveFolders() {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(folders) {
            defaults.set(data, forKey: StoreKeys.folders)
        }
        // CloudSync : snapshot pour détecter les folders à push/delete
        // (icone synced/unsynced changée, ordre, etc.).
        let foldersSnap = folders
        let itemsSnap = items
        Task { await CloudSync.shared.snapshotChanged(folders: foldersSnap, items: itemsSnap) }
    }

    private func loadSelectedFolder() {
        if let saved = defaults?.string(forKey: StoreKeys.selectedFolder),
           folders.contains(where: { $0.name == saved }) {
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
        guard !folders.contains(where: { $0.name == trimmed }) else { return }
        let nextIndex = (folders.map(\.sortIndex).max() ?? 0) + 1
        folders.append(Folder(name: trimmed, iCloudSynced: false, sortIndex: nextIndex))
        saveFolders()
        selectedFolder = trimmed
    }

    /// Réordonne la liste des folders. L'ordre est persisté dans
    /// `UserDefaults` (App Group) via `saveFolders()` et apparaît tel
    /// quel dans les sauvegardes (`BackupBundle.folders`), donc il est
    /// restauré à l'identique lors d'un import. Met à jour aussi
    /// `sortIndex` pour préserver l'ordre côté CloudKit.
    private func moveFolders(from source: IndexSet, to destination: Int) {
        folders.move(fromOffsets: source, toOffset: destination)
        // Re-numérote `sortIndex` 0, 1, 2... pour refléter le nouvel ordre.
        for i in folders.indices { folders[i].sortIndex = Double(i) }
        saveFolders()
    }

    /// Icône SF Symbol à afficher pour la ligne d'un dossier, selon son
    /// statut iCloud. Le dossier « Default » (inbox) garde son icône
    /// `tray.fill` historique. Les autres dossiers affichent `folder`
    /// quand local-only, `icloud.fill` quand l'utilisateur a activé la
    /// sync iCloud.
    private func folderRowIcon(for folder: Folder) -> String {
        if folder.name == StoreKeys.defaultFolder { return "tray.fill" }
        return folder.iCloudSynced ? "icloud.fill" : "folder"
    }

    /// Variante par nom : utilisée par les rendus qui n'ont que le
    /// nom à disposition (item.folder, badge dans une smart view, etc.).
    private func folderRowIcon(forName name: String) -> String {
        if name == StoreKeys.defaultFolder { return "tray.fill" }
        let synced = folders.first(where: { $0.name == name })?.iCloudSynced ?? false
        return synced ? "icloud.fill" : "folder"
    }

    // MARK: - iCloud sync (per-folder)

    /// Active la sync iCloud pour un dossier donné. Met à jour le
    /// drapeau local immédiatement (l'UI réagit), puis délègue à
    /// `CloudSync` pour publier le folder record + tous ses items
    /// vers la base privée. Le `Default` folder est exclu : il reste
    /// toujours local-only.
    private func startICloudSync(forFolder name: String) {
        guard name != StoreKeys.defaultFolder else { return }
        guard let idx = folders.firstIndex(where: { $0.name == name }) else { return }
        guard !folders[idx].iCloudSynced else { return }
        folders[idx].iCloudSynced = true
        saveFolders()
        let snapshot = folders[idx]
        let snapshotItems = items
        Task {
            await CloudSync.shared.startSync(folder: snapshot, items: snapshotItems)
        }
    }

    /// Reset complet de la sync iCloud (réservé au debug). Côté
    /// serveur : supprime la `CapturedZone` → cascade-delete de tous
    /// les Folder/Item records et de leurs assets. Côté local : tous
    /// les folders repassent en `iCloudSynced = false`, et CloudSync
    /// efface ses tokens / drapeaux / snapshot mémoire.
    private func resetICloudSyncState() {
        for i in folders.indices where folders[i].iCloudSynced {
            folders[i].iCloudSynced = false
        }
        saveFolders()
        Task { await CloudSync.shared.resetState() }
    }

    /// Lance `resyncReconcile` côté CloudSync. Marque `isResyncing`
    /// pendant l'exécution pour griser le bouton dans le menu et
    /// éviter une double déclenche pendant que l'opération est en
    /// cours. À la fin, recharge `folders` + `items` depuis l'App
    /// Group UserDefaults : la resync a pu ajouter des folders
    /// importés du cloud ou mettre à jour des items.
    private func runResyncReconcile() {
        guard !isResyncing else { return }
        isResyncing = true
        Task {
            await CloudSync.shared.resyncReconcile()
            await MainActor.run {
                reloadFoldersAndItemsFromAppGroup()
                isResyncing = false
            }
        }
    }

    /// Relit `folders` + `items` depuis l'App Group UserDefaults.
    /// Utilisé après une opération CloudSync qui peut avoir écrit en
    /// arrière-plan dans ces clés (resync, pull). Re-déclenche l'UI.
    private func reloadFoldersAndItemsFromAppGroup() {
        guard let d = UserDefaults(suiteName: appGroup) else { return }
        if let data = d.data(forKey: "folders"),
           let arr = try? JSONDecoder().decode([Folder].self, from: data) {
            folders = arr
        }
        if let data = d.data(forKey: "items"),
           let arr = try? JSONDecoder().decode([SharedItem].self, from: data) {
            items = arr
        }
    }

    /// Désactive la sync iCloud pour un dossier. Le record CloudKit
    /// + ses items sont supprimés du cloud (cascade-delete côté Apple
    /// via la `parent` reference). Les items restent en local.
    ///
    /// **Comportement à connaître** : sur les AUTRES appareils du même
    /// Apple ID, ce stop sync est interprété par `applyPulledChanges`
    /// comme une suppression normale : le folder et ses items
    /// **disparaissent** de leur sidebar/liste — y compris des items
    /// qui avaient une origine locale chez eux mais avaient été pushés
    /// dans le cloud entre-temps. L'appareil qui décide « Stop » est le
    /// seul à conserver les données.
    ///
    /// **Auto-rejoin** : si un appareil tiers réactive ensuite « Sync to
    /// iCloud » sur un folder du même nom, tous les appareils ayant
    /// localement un folder homonyme verront leur drapeau `iCloudSynced`
    /// repasser à `true` au prochain pull. C'est volontaire — pour
    /// rester local-only, il faut renommer son folder localement avant
    /// que la sync ne soit relancée ailleurs.
    private func stopICloudSync(forFolder name: String) {
        guard name != StoreKeys.defaultFolder else { return }
        guard let idx = folders.firstIndex(where: { $0.name == name }) else { return }
        guard folders[idx].iCloudSynced else { return }
        folders[idx].iCloudSynced = false
        let itemIDs = items.filter { $0.folder == name }.map(\.id)
        saveFolders()
        Task {
            await CloudSync.shared.stopSync(folderName: name, itemIDs: itemIDs)
        }
    }

    private func deleteFolder(_ name: String) {
        guard name != StoreKeys.defaultFolder else { return }
        // Capture l'état pré-mutation pour propager la suppression au
        // cloud + autres devices. Un folder synced déclenche le
        // mécanisme de tombstone (vraie suppression cross-cluster),
        // contrairement à un simple `stopSync` qui ne supprime que la
        // sync mais préserve les copies locales sur les autres devices.
        let wasSynced = folders.first(where: { $0.name == name })?.iCloudSynced == true
        let syncedItemIDs = wasSynced ? items.filter { $0.folder == name }.map(\.id) : []
        // Supprime les items de ce folder (et les fichiers sur disque le cas échéant)
        let removed = items.filter { $0.folder == name }
        removed.forEach {
            removeFileIfLocal($0.url)
            removePreviewIfAny($0)
        }
        items.removeAll { $0.folder == name }
        folders.removeAll { $0.name == name }
        saveItems()
        saveFolders()
        if selectedFolder == name {
            selectedFolder = StoreKeys.defaultFolder
        }
        if wasSynced {
            let nameSnap = name
            let idsSnap = syncedItemIDs
            Task {
                await CloudSync.shared.deleteSyncedFolder(folderName: nameSnap, itemIDs: idsSnap)
            }
        }
    }

    /// Supprime toutes les données purement locales :
    ///   - tous les folders non synchronisés sauf `Default` (qui doit
    ///     toujours exister), avec leur contenu (items + binaires +
    ///     previews sur disque).
    ///   - le contenu du folder `Default` (items + binaires + previews
    ///     sur disque). Le folder lui-même reste, vide.
    /// Préserve intégralement les folders `iCloudSynced=true` et leur
    /// contenu — ils sont cloud-backed et la suppression locale serait
    /// incohérente.
    private func deleteLocalData() {
        // Set des noms à conserver : Default + folders synced.
        let keepFolderNames: Set<String> = Set(
            [StoreKeys.defaultFolder] +
            folders.filter { $0.iCloudSynced }.map(\.name)
        )
        // Set des noms dont on doit VIDER le contenu : Default (toujours)
        // + tous les non-synced supprimés (leurs items vont disparaitre
        // de toute façon, mais on profite de la passe pour nettoyer
        // les binaires/previews disque associés).
        let wipeContentFolderNames: Set<String> = Set(
            folders.filter { !$0.iCloudSynced }.map(\.name)
        ).union([StoreKeys.defaultFolder])
        // Nettoyage disque des items concernés.
        for item in items where wipeContentFolderNames.contains(item.folder) {
            removeFileIfLocal(item.url)
            removePreviewIfAny(item)
        }
        // Filtrage des arrays.
        items.removeAll { wipeContentFolderNames.contains($0.folder) }
        folders.removeAll { !keepFolderNames.contains($0.name) }
        // Garantit que Default est toujours en tête (au cas où il aurait
        // été retiré par erreur).
        if !folders.contains(where: { $0.name == StoreKeys.defaultFolder }) {
            folders.insert(Folder.systemDefault(), at: 0)
        }
        // Si la sélection courante a disparu, repli sur Default.
        if let sel = selectedFolder, !folders.contains(where: { $0.name == sel }) {
            selectedFolder = StoreKeys.defaultFolder
        }
        saveItems()
        saveFolders()
    }

    /// Supprime les items dont le `folder` ne correspond à aucun
    /// folder local existant. Appelé une fois au démarrage de l'app
    /// (cf. `onAppear`). Idempotent : si tous les items pointent vers
    /// un folder valide, no-op silencieux.
    ///
    /// Les binaires et previews associés sont aussi nettoyés du disque
    /// pour éviter qu'ils restent comptés dans la taille « Local data ».
    /// La suppression n'est pas propagée à CloudKit : si l'item était
    /// dans un folder synced, il a déjà été supprimé du cloud lors de
    /// la disparition du folder ; sinon il n'a jamais été poussé.
    private func cleanupOrphanItems() {
        let validNames = Set(folders.map(\.name))
        let orphans = items.filter { !validNames.contains($0.folder) }
        guard !orphans.isEmpty else { return }
        for o in orphans {
            removeFileIfLocal(o.url)
            removePreviewIfAny(o)
        }
        items.removeAll { !validNames.contains($0.folder) }
        saveItems()
        print("[cleanupOrphanItems] removed \(orphans.count) orphan item(s)")
    }

    // MARK: - Item CRUD

    /// Réordonne les items actuellement affichés dans la liste
    /// principale (`currentItems`). Fonctionne aussi bien dans un
    /// dossier réel que dans une vue intelligente : on identifie les
    /// items visibles par leur id, et on remplace leurs positions
    /// dans le tableau global `items` selon le nouvel ordre. Les
    /// items hors `currentItems` (autres dossiers / hors filtre)
    /// gardent leur position relative.
    private func moveItems(from source: IndexSet, to destination: Int) {
        // 1. Calcule le nouvel ordre des items visibles.
        var visible = currentItems
        visible.move(fromOffsets: source, toOffset: destination)
        let visibleIDs = Set(visible.map(\.id))

        // 2. Reconstruit `items` : aux positions des items visibles,
        //    injecte la nouvelle séquence ; ailleurs, conserve tel quel.
        var newItems: [SharedItem] = []
        newItems.reserveCapacity(items.count)
        var iter = visible.makeIterator()
        for existing in items {
            if visibleIDs.contains(existing.id) {
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
        removedItems.forEach {
            removeFileIfLocal($0.url)
            removePreviewIfAny($0)
        }
        let removedIDs = Set(removedItems.map(\.id))
        items.removeAll { removedIDs.contains($0.id) }
        Spotlight.deindex(Array(removedIDs))
        saveItems()
    }

    /// Efface les aperçus (PNG sur disque + champ `previewPath`) de
    /// tous les items actuellement affichés. Au prochain pull-to-refresh
    /// ou tick du timer 100 ms, `triggerPendingPreviews` les régénère.
    /// Regénère l'aperçu d'un seul item. Pour une URL, regénère
    /// AUSSI la date (Last-Modified) en parallèle — l'utilisateur voit
    /// la roue tourner à la place de l'icône (`isItemBusy` vrai grâce à
    /// `fetchingDateIDs`) ET « Fetching date… » à la place de la date
    /// pendant que la requête HTTP HEAD se fait.
    /// Regénère uniquement l'aperçu d'un item, SANS toucher à la
    /// date Last-Modified — utile pour tous les types y compris les
    /// URLs quand l'utilisateur veut juste rafraîchir le visuel.
    private func regeneratePreviewOnly(for item: SharedItem) {
        // Si la preview de l'item est verrouillée, on refuse — c'est
        // l'objet même du verrou.
        if item.previewLocked == true { return }
        // On NE lève PAS le drapeau global `autoTriggersPaused` : sinon
        // tous les autres items éligibles se mettraient à traiter
        // aussi au prochain tick. À la place, on lance explicitement
        // la génération pour ce seul item.
        removePreviewIfAny(item)
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].previewPath = nil
        saveItems()
        if !generatingPreviewIDs.contains(item.id) {
            startPreviewGeneration(for: items[idx])
        }
    }

    private func regeneratePreview(for item: SharedItem) {
        // Preview verrouillée : refus catégorique (cf. previewLocked).
        if item.previewLocked == true { return }
        // Pas de levée globale de `autoTriggersPaused` — on lance
        // explicitement les tâches pour CET item uniquement.
        removePreviewIfAny(item)
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].previewPath = nil
        if items[idx].effectiveKind == "url" {
            // Reset visuel de la date pour afficher « Fetching date… »
            // pendant le refetch (le set `fetchingDateIDs` ajouté par
            // `startFetchLastModified` suffit déjà à déclencher ce
            // placeholder, mais on remet aussi `modifiedAt` à nil pour
            // que le layout reste cohérent même si l'utilisateur
            // scrolle hors écran et revient avant la fin du fetch).
            items[idx].modifiedAt = nil
            saveItems()
            startFetchLastModified(for: items[idx])
            // Lance aussi la génération de l'aperçu en parallèle, sans
            // attendre la fin du fetch.
            if !generatingPreviewIDs.contains(items[idx].id) {
                startPreviewGeneration(for: items[idx])
            }
        } else {
            saveItems()
            if !generatingPreviewIDs.contains(items[idx].id) {
                startPreviewGeneration(for: items[idx])
            }
        }
    }

    /// Regénère le texte IA d'un seul item : efface le titre IA et les
    /// drapeaux `aiDescribed` / `ocrDone`. Le prochain cycle de
    /// `triggerPendingAIDescriptions` (ou de transcription audio)
    /// relance le pipeline pour cet item, sous réserve du plafond
    /// per-item de 5 appels.
    private func regenerateAIText(for item: SharedItem) {
        // Pas de levée globale de la pause — on lance la tâche pour
        // CET item uniquement (description IA pour photo/video,
        // transcription pour audio).
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].title = nil
        items[idx].aiDescribed = nil
        items[idx].aiFailed = nil
        items[idx].ocrDone = nil
        items[idx].ocrFailed = nil
        items[idx].translationDone = nil
        saveItems()
        let kind = items[idx].effectiveKind
        guard !describingIDs.contains(items[idx].id) else { return }
        if kind == "audio" {
            // Transcription audio (Apple Speech, on-device, pas de cap).
            guard UserDefaults.standard.bool(forKey: "describeImagesEnabled") else { return }
            startAudioTranscription(for: items[idx])
        } else if kind == "photo" || kind == "video" {
            // Description IA cloud ou Apple Vision — respect du toggle
            // global et du plafond per-item.
            guard UserDefaults.standard.bool(forKey: "describeImagesEnabled") else { return }
            let provider = UserDefaults.standard.string(forKey: "describeImagesProvider") ?? "anthropic"
            let apiKey = (UserDefaults.standard.string(forKey: "describeImagesAPIKey") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let customModel = (UserDefaults.standard.string(forKey: "describeImagesModel") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if provider != "apple" && apiKey.isEmpty { return }
            if aiCallsCapped(items[idx], provider: provider) { return }
            startAIDescribe(item: items[idx], provider: provider, apiKey: apiKey, customModel: customModel)
        }
    }

    /// Vide les aperçus des items URL actuellement affichés. NE
    /// touche PAS aux dates et NE relance AUCUNE régénération
    /// automatique : `previewPath` est posé à `""` (sentinelle
    /// « cleared / failed » que `triggerPendingPreviews` ignore).
    /// L'utilisateur peut ensuite régénérer ligne par ligne via le
    /// menu contextuel ou en bulk via le pull-to-refresh / menu …
    /// → « Refresh previews and URL dates ».
    private func clearPreviewsForCurrent() {
        // Les items verrouillés sont explicitement préservés : c'est
        // tout l'intérêt du verrou (cf. previewLocked).
        let snapshot = currentItems.filter { $0.effectiveKind == "url"
                                             && $0.previewLocked != true }
        let ids = Set(snapshot.map(\.id))
        guard !ids.isEmpty else { return }
        // Annule les éventuelles générations d'aperçus en vol pour ces
        // items → la roue disparaît immédiatement, même si la capture
        // WKWebView était bloquée sur le sémaphore ou en attente.
        for id in ids { cancelPreviewTask(for: id) }
        for item in snapshot { removePreviewIfAny(item) }
        var newItems = items
        for idx in newItems.indices where ids.contains(newItems[idx].id) {
            newItems[idx].previewPath = ""
        }
        items = newItems
        saveItems()
    }

    /// Verrouille l'aperçu de tous les items URL actuellement
    /// affichés : leur `previewLocked` passe à `true`, et toute
    /// régénération / effacement ultérieure les laissera intactes
    /// jusqu'à déverrouillage.
    private func lockPreviewsForCurrent() {
        let ids = Set(currentItems.filter { $0.effectiveKind == "url" }.map(\.id))
        guard !ids.isEmpty else { return }
        var newItems = items
        var changed = false
        for idx in newItems.indices where ids.contains(newItems[idx].id)
                                          && newItems[idx].previewLocked != true {
            newItems[idx].previewLocked = true
            changed = true
        }
        if changed { items = newItems; saveItems() }
    }

    /// Supprime le verrouillage pour tous les items URL actuellement
    /// affichés. Leurs previews redeviennent éligibles à régénération
    /// (auto via `triggerPendingPreviews`, ou manuelle).
    private func unlockPreviewsForCurrent() {
        let ids = Set(currentItems.filter { $0.effectiveKind == "url" }.map(\.id))
        guard !ids.isEmpty else { return }
        var newItems = items
        var changed = false
        for idx in newItems.indices where ids.contains(newItems[idx].id)
                                          && newItems[idx].previewLocked == true {
            newItems[idx].previewLocked = nil
            changed = true
        }
        if changed { items = newItems; saveItems() }
    }

    /// Bascule le verrouillage de la preview d'un item (utilisé depuis
    /// le menu contextuel de la ligne).
    private func togglePreviewLock(for item: SharedItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].previewLocked = (items[idx].previewLocked == true) ? nil : true
        saveItems()
    }

    /// Bascule le zoom de la preview d'un item (×2 centré au rendu,
    /// même taille de cadre dans l'UI). Indépendant du verrou et du
    /// recadrage automatique : seul l'état booléen est persisté ;
    /// l'image PNG dans `previews/` reste inchangée.
    private func togglePreviewZoom(for item: SharedItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].previewZoomed = (items[idx].previewZoomed == true) ? nil : true
        saveItems()
    }

    /// Active le zoom ×2 sur toutes les previews URL du folder courant
    /// qui ne le sont pas déjà.
    private func zoomPreviewsForCurrent() {
        let ids = Set(currentItems.filter { $0.effectiveKind == "url" }.map(\.id))
        guard !ids.isEmpty else { return }
        var newItems = items
        var changed = false
        for idx in newItems.indices where ids.contains(newItems[idx].id)
                                          && newItems[idx].previewZoomed != true {
            newItems[idx].previewZoomed = true
            changed = true
        }
        if changed { items = newItems; saveItems() }
    }

    /// Désactive le zoom ×2 sur toutes les previews URL du folder
    /// courant qui le sont. Remet l'aperçu à son rendu standard.
    private func unzoomPreviewsForCurrent() {
        let ids = Set(currentItems.filter { $0.effectiveKind == "url" }.map(\.id))
        guard !ids.isEmpty else { return }
        var newItems = items
        var changed = false
        for idx in newItems.indices where ids.contains(newItems[idx].id)
                                          && newItems[idx].previewZoomed == true {
            newItems[idx].previewZoomed = nil
            changed = true
        }
        if changed { items = newItems; saveItems() }
    }

    /// Indique s'il existe au moins un item URL non verrouillé parmi
    /// ceux affichés (pour conditionner l'entrée de menu « Lock »).
    private var hasUnlockedURLInCurrent: Bool {
        currentItems.contains { $0.effectiveKind == "url" && $0.previewLocked != true }
    }

    /// Indique s'il y a au moins un item URL dans la vue courante.
    /// Sert à conditionner l'affichage simultané des entrées de menu
    /// « Zoom » et « Unzoom » : les deux opérations sont toujours
    /// applicables à TOUS les items URL (zoom = forcer tous à zoomé,
    /// unzoom = forcer tous à non-zoomé), indépendamment de l'état
    /// individuel courant — pas de raison de cacher l'un ou l'autre.
    private var hasURLItemsInCurrent: Bool {
        currentItems.contains { $0.effectiveKind == "url" }
    }

    /// Indique s'il existe au moins un item URL verrouillé parmi ceux
    /// affichés (pour conditionner l'entrée de menu « Unlock »).
    private var hasLockedURLInCurrent: Bool {
        currentItems.contains { $0.effectiveKind == "url" && $0.previewLocked == true }
    }

    /// Efface les textes générés par l'IA (titre IA + drapeaux
    /// `aiDescribed` / `ocrDone`) pour les items actuellement affichés,
    /// uniquement ceux qui ont effectivement été décrits par l'IA.
    /// Au prochain cycle, `triggerPendingAIDescriptions` /
    /// `triggerPendingOCR` / `triggerPendingAudioTranscriptions` les
    /// reconstruisent (sous réserve du plafond per-item de 5 appels et
    /// du toggle global IA).
    /// Reset le texte IA des items photo/video/audio actuellement
    /// affichés ET relance explicitement la génération IA pour chacun
    /// d'eux. Différence clé avec `clearAITextForCurrent` (qui se
    /// contente d'effacer sans relance) : on lance ici les
    /// `startAIDescribe` / `startAudioTranscription` pour tous les
    /// items concernés. Respect du toggle global, du provider, de la
    /// clé API et du plafond per-item de 5.
    private func refreshAITextForCurrent() {
        let snapshot = currentItems.filter {
            let k = $0.effectiveKind
            return k == "photo" || k == "video" || k == "audio"
        }
        let ids = Set(snapshot.map(\.id))
        guard !ids.isEmpty else { return }

        var newItems = items
        for idx in newItems.indices where ids.contains(newItems[idx].id) {
            newItems[idx].title = nil
            newItems[idx].aiDescribed = nil
            newItems[idx].aiFailed = nil
            newItems[idx].ocrDone = nil
            newItems[idx].ocrFailed = nil
            newItems[idx].translationDone = nil
        }
        items = newItems
        saveItems()

        guard UserDefaults.standard.bool(forKey: "describeImagesEnabled") else { return }
        let provider = UserDefaults.standard.string(forKey: "describeImagesProvider") ?? "anthropic"
        let apiKey = (UserDefaults.standard.string(forKey: "describeImagesAPIKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let customModel = (UserDefaults.standard.string(forKey: "describeImagesModel") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let needKey = (provider != "apple")
        if needKey && apiKey.isEmpty { return }

        for it in items where ids.contains(it.id) && !describingIDs.contains(it.id) {
            let kind = it.effectiveKind
            if kind == "audio" {
                startAudioTranscription(for: it)
            } else if kind == "photo" || kind == "video" {
                if aiCallsCapped(it, provider: provider) { continue }
                startAIDescribe(item: it, provider: provider, apiKey: apiKey, customModel: customModel)
            }
        }
    }

    private func clearAITextForCurrent() {
        let ids = Set(currentItems.filter { $0.aiDescribed == true }.map(\.id))
        guard !ids.isEmpty else { return }
        // Efface le titre IA SANS relancer aucune génération : la
        // ligne retombe sur son fallback (nom de fichier pour
        // photo/video/audio) — comme si l'IA n'avait jamais été
        // activée pour cet item. On positionne `aiDescribed = true`
        // pour bloquer toute relance auto par
        // `triggerPendingAIDescriptions` /
        // `triggerPendingAudioTranscriptions`. L'utilisateur peut
        // toujours forcer une regénération via le menu contextuel
        // « Regenerate AI text » d'une ligne précise.
        var newItems = items
        for idx in newItems.indices where ids.contains(newItems[idx].id) {
            newItems[idx].title = nil
            newItems[idx].aiDescribed = true
            // Volontairement « pas d'échec » puisque l'utilisateur a
            // explicitement choisi de ne pas avoir de description IA.
            newItems[idx].aiFailed = false
            newItems[idx].ocrDone = true
            // Pas d'OCR à retenter puisque le titre IA est désactivé.
            newItems[idx].ocrFailed = false
            // Bloque aussi toute traduction auto puisque le titre est
            // maintenant nil — rien à traduire.
            newItems[idx].translationDone = true
        }
        items = newItems
        saveItems()
    }

    private func clearFolder() {
        // Supprime ce qui est ACTUELLEMENT affiché : compatible avec les
        // smart folders, les filtres par type et la recherche. L'ancienne
        // version filtrait par `folder == currentFolder`, ce qui ne matchait
        // rien quand on était dans un smart folder (clé "smart:…").
        let removedItems = currentItems
        let removedIDs = Set(removedItems.map(\.id))
        removedItems.forEach {
            removeFileIfLocal($0.url)
            removePreviewIfAny($0)
        }
        Spotlight.deindex(removedItems.map(\.id))
        items.removeAll { removedIDs.contains($0.id) }
        saveItems()
    }

    private func moveItem(_ item: SharedItem, to folder: String) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].folder = folder
        saveItems()
    }

    /// Action déclenchée par l'entrée « Paste URL from clipboard » du
    /// menu …. Détecte TOUTES les URLs http/https présentes dans le
    /// presse-papiers (URL typée, chaîne unique, ou texte multi-URL).
    /// Cas 0 URL : no-op silencieux. Cas 1 URL : insertion immédiate.
    /// Cas ≥ 2 URLs : popup de confirmation indiquant le nombre.
    private func pasteAsItem() {
        let urls = extractURLsFromClipboard()
        guard !urls.isEmpty else { return }
        if urls.count == 1 {
            insertPastedURLs(urls)
        } else {
            pendingPasteURLs = urls
            showPasteMultipleConfirm = true
        }
    }

    /// Extrait toutes les URLs http/https du presse-papiers, dans l'ordre,
    /// dédupliquées. Trois sources sondées :
    ///   1. `pb.urls` (URLs typées) — priorité 1 ; certaines apps
    ///      écrivent plusieurs URLs typées dans le pasteboard.
    ///   2. Découpage de `pb.string` sur les retours ligne — utile pour
    ///      coller une liste d'URLs séparées par des sauts de ligne.
    ///   3. `NSDataDetector` (.link) sur `pb.string` — capture les URLs
    ///      noyées dans un texte arbitraire.
    /// La lecture de `pb.string` peut déclencher la bannière système
    /// « Captured pasted from… » — c'est l'utilisateur qui a choisi
    /// d'effectuer le collage, donc acceptable.
    private func extractURLsFromClipboard() -> [String] {
        let pb = UIPasteboard.general
        var collected: [String] = []
        let isHTTP: (URL) -> Bool = {
            let s = $0.scheme?.lowercased()
            return s == "http" || s == "https"
        }
        if let typed = pb.urls {
            for u in typed where isHTTP(u) {
                collected.append(u.absoluteString)
            }
        }
        if collected.isEmpty, pb.hasStrings, let raw = pb.string {
            // Tentative 1 : si chaque ligne non vide est une URL http/https,
            // on les prend toutes.
            let lines = raw.split(whereSeparator: { $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let perLine = lines.compactMap { line -> String? in
                guard let u = URL(string: line), isHTTP(u) else { return nil }
                return line
            }
            if perLine.count == lines.count, !perLine.isEmpty {
                collected.append(contentsOf: perLine)
            } else if let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue
            ) {
                // Tentative 2 : extraction des URLs noyées dans du texte.
                let range = NSRange(raw.startIndex..., in: raw)
                detector.enumerateMatches(in: raw, options: [], range: range) { match, _, _ in
                    if let u = match?.url, isHTTP(u) {
                        collected.append(u.absoluteString)
                    }
                }
            }
        }
        var seen: Set<String> = []
        return collected.filter { seen.insert($0).inserted }
    }

    /// Insère un lot d'URLs comme items dans le folder courant (ou
    /// Default si on est sur une smart view). Réutilisée par le chemin
    /// « insertion directe » (1 URL) et le chemin « confirmation » (≥ 2).
    private func insertPastedURLs(_ urls: [String]) {
        guard !urls.isEmpty else { return }
        let targetFolder: String
        if smartFolder == nil,
           let sel = selectedFolder,
           folders.contains(where: { $0.name == sel }) {
            targetFolder = sel
        } else {
            targetFolder = StoreKeys.defaultFolder
        }

        let now = Date().timeIntervalSince1970
        // Décalage de 1 ms par item pour préserver l'ordre de la liste
        // (la première URL du presse-papiers se retrouve tout en haut).
        var newItems: [SharedItem] = []
        for (i, urlString) in urls.enumerated() {
            let it = SharedItem(
                id: UUID().uuidString,
                url: urlString,
                title: nil,
                sourceApp: "Pasteboard",
                folder: targetFolder,
                timestamp: now + Double(urls.count - 1 - i) * 0.001,
                kind: "url"
            )
            newItems.append(it)
        }
        items.insert(contentsOf: newItems, at: 0)
        saveItems()
        // Fetch immédiat de la date Last-Modified pour chaque item.
        // Cf. commentaire détaillé dans l'ancienne version mono-URL :
        // l'auto-fetch de `loadItems()` ne se déclenche pas pour les
        // items déjà connus au tick suivant.
        for it in newItems {
            startFetchLastModified(for: it)
        }
        if let d = defaults {
            d.set(d.integer(forKey: "totalShareCount") + urls.count, forKey: "totalShareCount")
        }
    }

    /// Déplace en bloc les items dont l'id est dans `ids` vers `folder`.
    /// Utilisé par le drag-and-drop iPad depuis la liste de droite vers
    /// la sidebar : un seul item si l'utilisateur n'est pas en mode Edit,
    /// toute la sélection en mode Edit. Vide ensuite la sélection comme
    /// le fait `moveSelected(to:)`.
    private func moveItemsToFolder(ids: [String], to folder: String) {
        guard folders.contains(where: { $0.name == folder }) else { return }
        let idSet = Set(ids)
        var changed = false
        for i in 0..<items.count where idSet.contains(items[i].id) && items[i].folder != folder {
            items[i].folder = folder
            changed = true
        }
        if changed { saveItems() }
        selection.removeAll()
        exitEditModeIfActive()
    }

    private func removeFileIfLocal(_ urlString: String) {
        guard let url = URL(string: urlString), url.isFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Supprime le PNG d'aperçu associé à l'item (si présent dans
    /// `previews/`). À appeler en complément de `removeFileIfLocal` à
    /// chaque suppression d'item, sinon les aperçus orphelins restent
    /// sur disque et la taille des données de l'app ne baisse pas.
    private func removePreviewIfAny(_ item: SharedItem) {
        guard let path = item.previewPath, !path.isEmpty,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroup) else { return }
        let url = container.appendingPathComponent("previews", isDirectory: true)
            .appendingPathComponent(path)
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
        removed.forEach {
            removeFileIfLocal($0.url)
            removePreviewIfAny($0)
        }
        items.removeAll { ids.contains($0.id) }
        Spotlight.deindex(Array(ids))
        saveItems()
        selection.removeAll()
        exitEditModeIfActive()
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
        exitEditModeIfActive()
    }

    /// Sort du mode Edit s'il est actif. Appelé après les opérations de
    /// batch (suppression, déplacement) — l'utilisateur a fait son action,
    /// on retourne en mode normal sans qu'il ait à retoucher « Done ».
    private func exitEditModeIfActive() {
        guard editMode.isEditing else { return }
        withAnimation { editMode = .inactive }
    }

    // MARK: - OCR (photos)

    private func triggerPendingOCR() {
        guard !autoTriggersPaused else { return }
        for item in items where (item.effectiveKind == "photo" || item.effectiveKind == "video")
                                && item.ocrDone != true
                                // Bloque les retries auto en cas
                                // d'échec : seuls 1A/1B (via
                                // `retryFailedOCRsForCurrent`) ou les
                                // actions IA (clear/regenerate)
                                // remettent `ocrFailed` à nil.
                                && item.ocrFailed != true
                                && !ocrTasks.keys.contains(item.id)
                                // On laisse l'IA finir avant l'OCR pour bien
                                // appender le texte OCR derrière la description.
                                && (item.aiDescribed == true || !UserDefaults.standard.bool(forKey: "describeImagesEnabled")) {
            startOCR(for: item)
        }
    }

    private func startOCR(for item: SharedItem) {
        guard items.firstIndex(where: { $0.id == item.id }) != nil else { return }
        let id = item.id
        let urlString = item.url
        let task = Task.detached(priority: .utility) {
            // Timeout 10 s : Vision est rapide mais une image très
            // grande / corrompue pourrait théoriquement bloquer.
            let text = await PreviewGenerator.withTimeout(seconds: 10) {
                await Self.recognizeText(in: urlString)
            }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                ocrTasks.removeValue(forKey: id)
                updateBackgroundTasksCount()
                applyOCRResult(id: id, ocrText: text)
            }
        }
        ocrTasks[id] = task
        updateBackgroundTasksCount()
    }

    /// Applique le résultat d'un OCR : succès → suffixe au titre +
    /// `ocrDone = true`. Échec (Vision a renvoyé nil ou texte vide)
    /// → `ocrDone = true` aussi (pour bloquer triggerPendingOCR) ET
    /// `ocrFailed = true` (pour permettre aux refresh globaux de
    /// retenter ultérieurement sans toucher à la description IA).
    private func applyOCRResult(id: String, ocrText: String?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let text = ocrText, !text.isEmpty {
            let collapsed = text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !collapsed.isEmpty {
                let prefix = items[idx].title ?? URL(string: items[idx].url)?.lastPathComponent ?? items[idx].url
                items[idx].title = "\(prefix) — \(collapsed)"
                items[idx].ocrDone = true
                items[idx].ocrFailed = false
                saveItems()
                return
            }
        }
        // Cas d'échec / texte vide
        items[idx].ocrDone = true
        items[idx].ocrFailed = true
        saveItems()
    }

    /// Helper appelé par 1A et 1B pour retenter l'OCR sur les items
    /// visibles dont la dernière tentative a échoué. Remet
    /// `ocrDone = nil` ET `ocrFailed = nil` → `triggerPendingOCR`
    /// relancera Vision au prochain tick. Ne touche PAS à
    /// `aiDescribed` ni au `title` IA → l'OCR retentera de suffixer
    /// son texte sans relancer la description IA.
    /// Lance la transcription pour chaque audio visible dont
    /// `aiDescribed` est resté à nil (= cancellation par 1C avant
    /// complétion). Sert à boucher le trou : le cycle « audio
    /// cancellé » n'est sinon repris qu'en passant par 1D / 1J. Ne
    /// crée pas de drapeau supplémentaire car les échecs définitifs
    /// (auth Speech refusée, audio illisible) posent déjà
    /// `aiDescribed = true` et ne sont donc pas retentés par ce
    /// helper.
    private func retryPendingAudioTranscriptionsForCurrent() {
        guard UserDefaults.standard.bool(forKey: "describeImagesEnabled") else { return }
        for it in currentItems
            where it.effectiveKind == "audio"
                && it.aiDescribed != true
                && !describingIDs.contains(it.id) {
            startAudioTranscription(for: it)
        }
    }

    private func retryFailedOCRsForCurrent() {
        var newItems = items
        var changed = false
        let visibleIDs = Set(currentItems.map(\.id))
        for idx in newItems.indices
            where (newItems[idx].effectiveKind == "photo" || newItems[idx].effectiveKind == "video")
                && newItems[idx].ocrFailed == true
                && visibleIDs.contains(newItems[idx].id) {
            newItems[idx].ocrDone = nil
            newItems[idx].ocrFailed = nil
            changed = true
        }
        if changed {
            items = newItems
            saveItems()
        }
    }

    // MARK: - Previews (320x200)

    /// Génère lazily un aperçu PNG 320x200 pour chaque item qui n'en a
    /// pas encore. `previewPath == ""` signifie tentative déjà faite et
    /// échouée → on ne réessaie pas.
    /// Race condition iCloud : si un item vient juste d'arriver via
    /// pull CloudKit avec `previewPath = nil`, on attend 30 s avant de
    /// régénérer localement, le temps que l'aperçu poussée par
    /// l'autre appareil arrive elle aussi par pull (cf. CloudSync
    /// `cloudPreviewWaitingItems`). Sans cette attente, l'iPhone
    /// regénérait systématiquement l'aperçu en local en parallèle
    /// du download CK, gaspillant 10-15 s de WKWebView pour finalement
    /// écraser le résultat avec la version cloud.
    private func triggerPendingPreviews() {
        guard !autoTriggersPaused else { return }
        let waiting = (defaults?.dictionary(forKey: "cloudPreviewWaitingItems") as? [String: Double]) ?? [:]
        let now = Date().timeIntervalSince1970
        for item in items where item.previewPath == nil
                                && item.previewLocked != true
                                && !generatingPreviewIDs.contains(item.id) {
            if let receivedAt = waiting[item.id], now - receivedAt < 30 {
                continue // attendre que le cloud livre l'aperçu
            }
            startPreviewGeneration(for: item)
        }
    }

    private func startPreviewGeneration(for item: SharedItem) {
        generatingPreviewIDs.insert(item.id)
        let snapshot = item
        let task = Task.detached(priority: .utility) {
            let filename = await PreviewGenerator.generate(for: snapshot)
            await MainActor.run {
                // Si la tâche a été annulée entretemps (clear preview
                // par l'utilisateur), on ignore le résultat — l'état a
                // déjà été nettoyé par `cancelPreviewTask`.
                guard !Task.isCancelled else { return }
                generatingPreviewIDs.remove(snapshot.id)
                previewTasks.removeValue(forKey: snapshot.id)
                updateBackgroundTasksCount()
                guard let idx = items.firstIndex(where: { $0.id == snapshot.id }) else { return }
                items[idx].previewPath = filename ?? ""
                saveItems()
            }
        }
        previewTasks[item.id] = task
        updateBackgroundTasksCount()
    }

    /// Annule une éventuelle génération d'aperçu en cours pour cet
    /// item et nettoie immédiatement l'état UI (la roue disparaît).
    private func cancelPreviewTask(for id: String) {
        if let task = previewTasks.removeValue(forKey: id) {
            task.cancel()
        }
        generatingPreviewIDs.remove(id)
        updateBackgroundTasksCount()
    }

    // MARK: - Audio transcription (speech-to-text)

    /// Lance la transcription des 15 premières secondes pour chaque item
    /// audio jamais transcrit. On réutilise le drapeau `aiDescribed` pour
    /// garantir une seule tentative par item (succès ou échec). Activé
    /// uniquement si l'utilisateur a laissé `describeImagesEnabled` à true.
    private func triggerPendingAudioTranscriptions() {
        guard !autoTriggersPaused else { return }
        guard UserDefaults.standard.bool(forKey: "describeImagesEnabled") else { return }
        for item in items where item.effectiveKind == "audio"
                                && item.aiDescribed != true
                                && !describingIDs.contains(item.id) {
            startAudioTranscription(for: item)
        }
    }

    private func startAudioTranscription(for item: SharedItem) {
        describingIDs.insert(item.id)
        let id = item.id
        let urlString = item.url
        let task = Task.detached(priority: .utility) {
            // Timeout 30 s : le clip audio fait au plus 15 s, plus
            // l'export AVAssetExportSession + l'autorisation SFSpeech
            // + la reconnaissance elle-même → 30 s couvre largement.
            // Au-delà, on suppose un blocage et on abandonne.
            let text = await PreviewGenerator.withTimeout(seconds: 30) {
                await Self.transcribeFirstSeconds(audioURLString: urlString, seconds: 15)
            }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                describingIDs.remove(id)
                aiTasks.removeValue(forKey: id)
                updateBackgroundTasksCount()
                applyAudioTranscription(id: id, text: text)
            }
        }
        aiTasks[id] = task
        updateBackgroundTasksCount()
    }

    private func applyAudioTranscription(id: String, text: String?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let text, !text.isEmpty {
            items[idx].title = text
            items[idx].aiDescribed = true
            items[idx].aiFailed = false
            // Le transcript est déjà dans la langue de l'utilisateur
            // (SFSpeechRecognizer utilise la locale courante) → pas de
            // traduction nécessaire.
            items[idx].translationDone = true
            // Invalide l'aperçu précédent (icône waveform générée
            // avant la transcription) pour qu'elle soit régénérée en
            // « page de texte » avec le transcript au prochain
            // triggerPendingPreviews. removePreviewIfAny supprime le
            // PNG sur disque, le nil déclenche la regénération.
            removePreviewIfAny(items[idx])
            items[idx].previewPath = nil
            saveItems()
        } else {
            // Échec : on marque quand même `aiDescribed` pour éviter tout
            // retry, et on laisse le titre actuel intact.
            items[idx].aiDescribed = true
            items[idx].aiFailed = true
            items[idx].translationDone = true
            saveItems()
        }
    }

    /// Demande l'autorisation Speech (une fois) puis transcrit les
    /// `seconds` premières secondes du fichier audio. Utilise la
    /// reconnaissance on-device si disponible (privacy + offline), sinon
    /// fallback vers le service réseau Apple. Retourne `nil` en cas
    /// d'échec à n'importe quelle étape.
    static func transcribeFirstSeconds(audioURLString: String, seconds: Double) async -> String? {
        guard let url = URL(string: audioURLString), url.isFileURL else { return nil }

        // Autorisation Speech
        let authStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        guard authStatus == .authorized else {
            print("Speech not authorized: \(authStatus.rawValue)")
            return nil
        }

        // Choix du recognizer dans la langue de l'app, fallback en-US.
        let appLocale = Locale.current
        let recognizer = SFSpeechRecognizer(locale: appLocale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else { return nil }

        // Trim à `seconds` premières secondes dans un fichier .m4a temporaire.
        guard let trimmedURL = await trimAudioPrefix(sourceURL: url, seconds: seconds) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: trimmedURL) }

        let request = SFSpeechURLRecognitionRequest(url: trimmedURL)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            var hasResumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if hasResumed { return }
                if let error {
                    print("Speech recognition error: \(error.localizedDescription)")
                    hasResumed = true
                    cont.resume(returning: nil)
                    return
                }
                guard let result, result.isFinal else { return }
                hasResumed = true
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: text.isEmpty ? nil : text)
            }
        }
    }

    /// Exporte les `seconds` premières secondes d'un fichier audio vers
    /// un .m4a temporaire utilisable par SFSpeechURLRecognitionRequest.
    static func trimAudioPrefix(sourceURL: URL, seconds: Double) async -> URL? {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try? await asset.load(.duration)
        let endSec = min(seconds, CMTimeGetSeconds(duration ?? CMTime(seconds: seconds, preferredTimescale: 600)))
        guard endSec > 0 else { return nil }
        let timeRange = CMTimeRange(start: .zero,
                                    duration: CMTime(seconds: endSec, preferredTimescale: 600))
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sm-trim-\(UUID().uuidString).m4a")
        exporter.outputURL = outURL
        exporter.outputFileType = .m4a
        exporter.timeRange = timeRange
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            exporter.exportAsynchronously {
                if exporter.status == .completed {
                    cont.resume(returning: outURL)
                } else {
                    print("Audio trim failed: \(exporter.error?.localizedDescription ?? "unknown")")
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Charge des données d'image utilisables pour OCR / IA. Pour une photo,
    /// retourne directement les octets du fichier. Pour une vidéo, extrait
    /// la première frame en JPEG. Retourne `nil` si l'extraction échoue —
    /// l'appelant gère alors le fallback (titre laissé en l'état).
    static func loadImageDataForAnalysis(urlString: String) -> Data? {
        guard let url = URL(string: urlString), url.isFileURL else { return nil }
        if isVideoURLString(urlString) {
            return extractFirstFrameJPEG(videoURL: url)
        }
        return try? Data(contentsOf: url)
    }

    /// Vrai si l'URL pointe vers un fichier vidéo (selon l'extension).
    static func isVideoURLString(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let ext = url.pathExtension
        guard let utype = UTType(filenameExtension: ext) else { return false }
        return utype.conforms(to: .movie) || utype.conforms(to: .audiovisualContent)
    }

    /// Extrait la première frame d'une vidéo et la renvoie sous forme de
    /// JPEG. Renvoie `nil` en cas d'échec (codec non supporté, fichier
    /// corrompu, etc.) → l'appelant doit alors retomber sur le comportement
    /// existant (pas d'OCR / pas de description IA).
    static func extractFirstFrameJPEG(videoURL: URL) -> Data? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Tolérance pour récupérer une frame proche de t=0 même si la vidéo
        // n'a pas de keyframe à exactement zéro.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
        } catch {
            print("Video frame extraction failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func recognizeText(in urlString: String) async -> String? {
        guard let data = loadImageDataForAnalysis(urlString: urlString),
              let cgImage = UIImage(data: data)?.cgImage else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // On dispatche le `perform([request])` synchrone Vision sur
            // un thread .utility explicite. Sans ça, quand la Task
            // appelante est suspended et qu'un autre code à QoS
            // user-interactive attend indirectement notre continuation,
            // Swift Concurrency peut tenter une escalade de priorité —
            // Vision tournant en interne sur des threads utility, le
            // runtime émet alors un warning « priority inversion ».
            DispatchQueue.global(qos: .utility).async {
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
            // Le format de backup garde les noms de dossier seuls
            // (rétro-compat des sauvegardes pré-iCloud). Les drapeaux
            // iCloud sont une décision PAR APPAREIL et ne se restaurent
            // pas — à l'import, chaque dossier repart en local-only.
            folders: folders.map(\.name),
            items: items,
            files: collectFileBlobs(),
            previews: collectPreviewBlobs()
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

    /// Collecte chaque PNG d'aperçu déjà généré (sous-dossier
    /// `previews/` du container App Group) en base64, indexé par item.id.
    /// Permet à la sauvegarde d'être auto-suffisante : la restauration
    /// n'aura plus à régénérer les aperçus (en particulier les captures
    /// WebView des URLs, lentes et nécessitant le réseau).
    private func collectPreviewBlobs() -> [String: String] {
        var blobs: [String: String] = [:]
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup) else { return blobs }
        let dir = container.appendingPathComponent("previews", isDirectory: true)
        for item in items {
            guard let path = item.previewPath, !path.isEmpty else { continue }
            let url = dir.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else { continue }
            blobs[item.id] = data.base64EncodedString()
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
            importErrorMessage = String(localized: "App Group container unavailable.")
            return
        }
        let dir = containerURL.appendingPathComponent("SharedFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // ===== Mode REPLACE =====
        if mode == .replace {
            // Vide entièrement `SharedFiles/` (tous types : photos,
            // vidéos, audios, fichiers) et `previews/` (PNG des
            // aperçus). `restoreItems` recrée immédiatement après ce
            // qui est dans le backup. Le wipe complet supprime aussi
            // les éventuels orphelins déjà présents sur disque (items
            // antérieurement effacés sans cleanup, résidus de bugs),
            // ce qui correspond à la promesse du dialog « Replace
            // deletes everything before restoring ».
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let previewDir = containerURL.appendingPathComponent("previews", isDirectory: true)
            try? FileManager.default.removeItem(at: previewDir)
            try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)

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

            // Reconstruction de `[Folder]` depuis les noms du backup,
            // tous remis en local-only (iCloudSynced = false). Default
            // garanti en tête.
            var newNames = bundle.folders
            if !newNames.contains(StoreKeys.defaultFolder) {
                newNames.insert(StoreKeys.defaultFolder, at: 0)
            }
            folders = newNames.enumerated().map { idx, name in
                Folder(name: name, iCloudSynced: false, sortIndex: Double(idx))
            }
            saveFolders()

            items = restoreItems(bundle.items,
                                 files: bundle.files,
                                 previews: bundle.previews ?? [:],
                                 into: dir,
                                 regenerateIDs: false)
            saveItems()

            if folders.contains(where: { $0.name == bundle.settings.selectedFolder }) {
                selectedFolder = bundle.settings.selectedFolder
            } else {
                selectedFolder = StoreKeys.defaultFolder
            }
            UserDefaults(suiteName: appGroup)?.set(selectedFolder, forKey: StoreKeys.selectedFolder)
            // Force une resync iCloud après le REPLACE : importe les
            // folders + items cloud absents du backup, nettoie les
            // orphelins, et re-pousse le contenu des folders synced
            // (s'il y en a, ce qui n'est pas le cas immédiatement
            // après un REPLACE puisque tout repart `iCloudSynced=false`,
            // mais reste utile pour aligner les états après que
            // l'utilisateur ait réactivé la sync sur un folder).
            runResyncReconcile()
            return
        }

        // ===== Mode MERGE =====
        // - Réglages : on conserve les valeurs courantes (rien d'écrasé).
        // - Folders : union (les folders nouveaux sont ajoutés à la fin),
        //   ajoutés en local-only.
        // - Items : append. On régénère les IDs pour éviter toute collision
        //   avec des items existants ; les fichiers binaires sont récupérés
        //   par l'ancien ID puis restaurés sous un nouveau nom.
        for f in bundle.folders where !folders.contains(where: { $0.name == f }) {
            let nextIndex = (folders.map(\.sortIndex).max() ?? 0) + 1
            folders.append(Folder(name: f, iCloudSynced: false, sortIndex: nextIndex))
        }
        saveFolders()

        let merged = restoreItems(bundle.items,
                                  files: bundle.files,
                                  previews: bundle.previews ?? [:],
                                  into: dir,
                                  regenerateIDs: true)
        items.append(contentsOf: merged)
        saveItems()
        // Force une resync iCloud après le MERGE : pareil que pour
        // le REPLACE — convergence locale ↔ cloud (import des folders/
        // items cloud manquants, cleanup orphelins, re-push idempotent
        // des folders synced).
        runResyncReconcile()
    }

    /// Écrit les binaires de `files` dans `dir` et retourne la liste d'items
    /// avec leur `url` pointant sur le nouveau chemin App Group. Si
    /// `regenerateIDs` est vrai, chaque item reçoit un nouvel UUID (pour
    /// éviter les collisions avec des items existants en mode merge).
    private func restoreItems(_ source: [SharedItem],
                              files: [String: BackupBundle.FileBlob],
                              previews: [String: String],
                              into dir: URL,
                              regenerateIDs: Bool) -> [SharedItem] {
        var result = source
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let previewDir: URL? = {
            guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
            let d = container.appendingPathComponent("previews", isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }()
        for i in 0..<result.count {
            let item = result[i]
            // ID de référence pour retrouver le blob (avant régénération).
            let blob = files[item.id]
            let previewBase64 = previews[item.id]
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
                    ocrDone: item.ocrDone,
                    previewPath: nil,
                    aiCallsCount: item.aiCallsCount,
                    translationDone: item.translationDone,
                    ocrFailed: item.ocrFailed,
                    titleFetchFailed: item.titleFetchFailed,
                    aiFailed: item.aiFailed,
                    previewLocked: item.previewLocked,
                    previewZoomed: item.previewZoomed
                )
                result[i] = copy
            }
            // Restauration de l'aperçu : on l'écrit sous le nouvel ID.
            if let b64 = previewBase64, let pdir = previewDir,
               let pdata = Data(base64Encoded: b64) {
                let pname = "\(result[i].id).png"
                let pdest = pdir.appendingPathComponent(pname)
                do {
                    try pdata.write(to: pdest, options: .atomic)
                    result[i].previewPath = pname
                } catch {
                    print("Restore preview write error: \(error)")
                }
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
        // Tous les types d'objets supportent désormais l'état non-lu.
        // Pour les URL la `modifiedAt` provient du Last-Modified HTTP ;
        // pour les autres types elle est posée par le Share Extension
        // au moment du partage (date de dernière modif POSIX pour un
        // fichier/photo/vidéo/audio, instant du partage pour un texte).
        // Tant qu'on ne « voit » pas l'item (markAsSeen via tap),
        // lastSeenModifiedAt reste nil → unread = true.
        guard let mod = item.modifiedAt else { return false }
        guard let seen = item.lastSeenModifiedAt else { return true }
        return mod > seen
    }

    /// Appelé quand l'utilisateur ouvre une URL : on mémorise la date vue
    /// pour ne plus marquer l'item comme "nouveau" jusqu'à la prochaine
    /// modification remotelement détectée.
    /// Action déclenchée par un tap sur un item, qu'il vienne de la liste
    /// principale ou de la grille d'aperçus : ouvre QuickLook pour les
    /// fichiers/photos/vidéos/audios, l'aperçu texte pour le texte, et
    /// Safari plein écran pour les URLs (en marquant l'item comme lu).
    private func openItem(_ item: SharedItem) {
        // Si on est en edit mode, ne rien faire : le tap est destiné à
        // modifier la sélection, géré par le List(selection:).
        if editMode.isEditing { return }
        // Sortie d'edit mode propre : si une sélection résiduelle existe
        // hors edit mode, iOS peut intercepter les taps comme « toggle
        // selection » au lieu de les laisser passer à .onTapGesture.
        // On vide donc la sélection résiduelle au premier tap.
        if !selection.isEmpty {
            selection.removeAll()
        }
        let kind = item.effectiveKind
        let linkURL: URL? = URL(string: item.url)
        // Marquer comme lu pour TOUS les types d'objets, plus seulement
        // les URL : ouvrir un fichier / une photo / une vidéo / un
        // audio / un texte enlève aussi le gras + bordeaux.
        markAsSeen(itemID: item.id)
        switch kind {
        case "file", "photo", "video", "audio":
            if let link = linkURL { previewFileURL = link }
        case "text":
            textToPreview = TextPreviewPayload(text: item.url, title: item.title)
        default:
            if let link = linkURL { safariFullScreenURL = link }
        }
    }

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
        let task = Task.detached(priority: .utility) {
            let description = await Self.describeImage(urlString: urlString,
                                                       provider: provider,
                                                       apiKey: apiKey,
                                                       customModel: customModel)
            await MainActor.run {
                // Si la Task a été annulée pendant l'attente du résultat
                // (ex: 1C par l'utilisateur), on ne consomme PAS de
                // crédit ni dans le compteur global ni dans le cap
                // per-item — la requête HTTP a peut-être abouti côté
                // provider (léger sous-comptage acceptable) mais
                // l'utilisateur a explicitement renoncé. Sans ça, 5
                // cancellations rapides cappaient l'item à tort.
                guard !Task.isCancelled else { return }
                // Comptage APRÈS complétion : on ne compte QUE les
                // providers cloud (OpenAI / Anthropic) — Apple
                // Intelligence on-device est exempt.
                if provider != "apple" {
                    recordAICall()
                    if let idx = items.firstIndex(where: { $0.id == id }) {
                        items[idx].aiCallsCount = (items[idx].aiCallsCount ?? 0) + 1
                    }
                }
                describingIDs.remove(id)
                aiTasks.removeValue(forKey: id)
                updateBackgroundTasksCount()
                updateItemAfterAIDescribe(id: id, description: description, provider: provider)
            }
        }
        aiTasks[id] = task
        updateBackgroundTasksCount()
    }

    /// Plafond per-item : au-delà de 5 appels IA cloud, on n'invoque plus
    /// pour cet item, l'utilisateur peut réinitialiser via le menu
    /// contextuel. Apple Intelligence (provider == "apple") n'est jamais
    /// plafonné car ne consomme aucun crédit.
    static let aiCallsLimit = 5
    private func aiCallsCapped(_ item: SharedItem, provider: String) -> Bool {
        guard provider != "apple" else { return false }
        return (item.aiCallsCount ?? 0) >= Self.aiCallsLimit
    }
    /// Vrai si la limite est atteinte indépendamment du provider courant
    /// — sert à afficher l'avertissement dans la ligne (l'item a accumulé
    /// 5 appels même si l'utilisateur a entre-temps changé de provider).
    private func aiCallsHardCapped(_ item: SharedItem) -> Bool {
        return (item.aiCallsCount ?? 0) >= Self.aiCallsLimit
    }
    /// Remet à zéro le compteur per-item d'appels IA (`aiCallsCount`)
    /// pour TOUS les items. Appelé par « Reset AI counters » du menu …
    /// → l'utilisateur peut relancer des descriptions IA sur des items
    /// qui avaient atteint le plafond de 5.
    private func resetPerItemAICallLimits() {
        var newItems = items
        var changed = false
        for idx in newItems.indices where (newItems[idx].aiCallsCount ?? 0) > 0 {
            newItems[idx].aiCallsCount = 0
            changed = true
        }
        if changed {
            items = newItems
            saveItems()
        }
    }

    private func resetItemAICalls(_ item: SharedItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].aiCallsCount = 0
        // Réautorise un nouveau cycle d'IA en réinitialisant aussi le
        // drapeau « tentative déjà faite », l'échec, la traduction et
        // l'OCR.
        items[idx].aiDescribed = nil
        items[idx].aiFailed = nil
        items[idx].translationDone = nil
        items[idx].ocrDone = nil
        items[idx].ocrFailed = nil
        saveItems()
    }

    private func updateItemAfterAIDescribe(id: String, description: String?, provider: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let description, !description.isEmpty {
            items[idx].title = description
            items[idx].aiDescribed = true
            items[idx].aiFailed = false
            // On reset le drapeau de traduction puisque le titre est
            // tout neuf (en anglais pour Apple Vision). Sera re-positionné
            // à `true` par `LabelTranslator` quand la traduction
            // aboutit (ou est tentée sans succès).
            items[idx].translationDone = nil
            saveItems()
            // Si la langue de l'app n'est pas l'anglais et que les labels
            // viennent d'Apple Vision (anglais), enfiler pour traduction
            // on-device (iOS 18+).
            if provider == "apple" {
                let lang = Locale.current.language.languageCode?.identifier ?? "en"
                if lang != "en", #available(iOS 18.0, *) {
                    pendingLabelTranslations.append(LabelTranslationJob(id: id, sourceText: description))
                    updateBackgroundTasksCount()
                }
            } else {
                // Pour les providers cloud, le prompt demande déjà la
                // langue cible → pas de traduction supplémentaire,
                // on marque comme « traduit » pour éviter les retries.
                items[idx].translationDone = true
                saveItems()
            }
        } else {
            // Échec : description IA n'a rien renvoyé.
            items[idx].aiDescribed = true
            items[idx].aiFailed = true
            saveItems()
        }
    }

    /// Lance la traduction Apple pour chaque item visible avec une
    /// description IA Apple non encore traduite. Sert au refresh
    /// global (1A et 1B) pour boucher le trou : sinon une queue
    /// `pendingLabelTranslations` interrompue (ex: erreur de session)
    /// laisse les jobs en attente indéfiniment.
    private func retryPendingTranslationsForCurrent() {
        guard #available(iOS 18.0, *) else { return }
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        guard lang != "en" else { return }
        let provider = UserDefaults.standard.string(forKey: "describeImagesProvider") ?? "anthropic"
        guard provider == "apple" else { return }

        let alreadyQueued = Set(pendingLabelTranslations.map(\.id))
        for it in currentItems
            where (it.effectiveKind == "photo" || it.effectiveKind == "video")
                && it.aiDescribed == true
                && it.translationDone != true
                && !alreadyQueued.contains(it.id) {
            guard let title = it.title, !title.isEmpty else { continue }
            pendingLabelTranslations.append(LabelTranslationJob(id: it.id, sourceText: title))
        }
        updateBackgroundTasksCount()
    }

    /// Charge l'image, la convertit en JPEG (max 1568 px sur le plus grand
    /// côté) puis appelle le provider choisi. Renvoie la description texte
    /// ou nil en cas d'échec.
    static func describeImage(urlString: String, provider: String, apiKey: String, customModel: String) async -> String? {
        guard let raw = loadImageDataForAnalysis(urlString: urlString) else { return nil }

        // Apple Intelligence (on-device Vision) : pas d'appel réseau,
        // pas besoin de compression JPEG ni de clé.
        if provider == "apple" {
            return await describeViaApple(imageData: raw)
        }

        guard let (jpeg, mediaType) = prepareImageForAI(data: raw) else { return nil }
        let base64 = jpeg.base64EncodedString()

        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let isVideoFrame = isVideoURLString(urlString)
        let prompt: String
        if isVideoFrame {
            prompt = "The attached image is the first frame extracted from a video file. Based on this frame, describe the VIDEO (not the image) in rich, visual detail: subjects, objects, colors, composition, lighting, mood, and any notable elements. Phrase the description in terms of the video — for example, say \"the video shows…\" rather than \"the image shows…\". Respond in the language with BCP-47 code \"\(lang)\". Return only the description itself, with no preamble, no quotes, no labels."
        } else {
            prompt = "Describe this image in rich, visual detail: subjects, objects, colors, composition, lighting, mood, and any notable elements. Respond in the language with BCP-47 code \"\(lang)\". Return only the description itself, with no preamble, no quotes, no labels."
        }

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
            // Idem `recognizeText` : on isole le `perform` synchrone
            // sur une queue utility explicite pour échapper à toute
            // escalade de priorité Swift Concurrency.
            DispatchQueue.global(qos: .utility).async {
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
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Compteurs : on lit les VRAIS tokens facturés depuis
            // `usage.input_tokens` / `usage.output_tokens` (Anthropic
            // Messages API). Si le champ est absent (formats anciens),
            // on enregistre 0 plutôt qu'une estimation fantaisiste.
            let usage = json["usage"] as? [String: Any]
            let inT = (usage?["input_tokens"] as? Int) ?? 0
            let outT = (usage?["output_tokens"] as? Int) ?? 0
            await MainActor.run {
                AICounters.record(provider: "anthropic", model: model,
                                  tokensIn: inT, tokensOut: outT)
            }
            return trimmed
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
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Compteurs : `usage.prompt_tokens` / `completion_tokens`
            // sont les vrais tokens facturés par l'API OpenAI.
            let usage = json["usage"] as? [String: Any]
            let inT = (usage?["prompt_tokens"] as? Int) ?? 0
            let outT = (usage?["completion_tokens"] as? Int) ?? 0
            await MainActor.run {
                AICounters.record(provider: "openai", model: model,
                                  tokensIn: inT, tokensOut: outT)
            }
            return trimmed
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
                        .blinking()
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
        let task = Task.detached(priority: .utility) {
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
                guard !Task.isCancelled else { return }
                geocodingIDs.remove(id)
                geocodeTasks.removeValue(forKey: id)
                updateBackgroundTasksCount()
                updateItemPlaceName(id: id, to: name)
            }
        }
        geocodeTasks[id] = task
        updateBackgroundTasksCount()
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
                    .blinking()
            } else if let d = item.modifiedAt {
                Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: d)))
                    .font(.caption2)
            } else {
                // URL jamais interrogée et pas en cours : on affiche quand même
                // une ligne (placeholder clignotant) pour garder un layout stable.
                Text("Fetching date…")
                    .font(.caption2)
                    .blinking()
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
        let task = Task.detached(priority: .utility) {
            let date = await Self.fetchLastModified(urlString: urlString)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                fetchingDateIDs.remove(id)
                dateFetchTasks.removeValue(forKey: id)
                updateBackgroundTasksCount()
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
        dateFetchTasks[id] = task
        updateBackgroundTasksCount()
    }

    private func updateItemModifiedAt(id: String, to date: Date) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let newTimestamp = date.timeIntervalSince1970
        let oldModified = items[idx].modifiedAt
        items[idx].modifiedAt = newTimestamp
        // Si la page a évolué côté serveur (Last-Modified strictement plus
        // récent que ce qu'on avait) et qu'un aperçu existait déjà → on le
        // réinitialise pour forcer une nouvelle capture WebView. Le nil
        // déclenchera triggerPendingPreviews au prochain loadItems.
        if items[idx].effectiveKind == "url",
           let old = oldModified, newTimestamp > old,
           items[idx].previewPath != nil {
            items[idx].previewPath = nil
        }
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

    /// Handler pour le pull-to-refresh de la sidebar. Équivalent au
    /// bouton « Resync iCloud » du menu : lance `resyncReconcile` côté
    /// CloudSync. Le spinner reste affiché jusqu'à la fin de
    /// l'opération. Affiche l'overlay « Refreshing » avec un sous-titre
    /// dédié à l'iCloud resync.
    @MainActor
    private func pullToRefreshICloud() async {
        showRefreshAnnouncement(subtitleKey: "Resynchronizing with iCloud")
        guard !isResyncing else { return }
        isResyncing = true
        await CloudSync.shared.resyncReconcile()
        reloadFoldersAndItemsFromAppGroup()
        isResyncing = false
    }

    /// Handler pour le pull-to-refresh de la liste. Se comporte comme le
    /// bouton « Refresh dates » du menu : lance un batch refresh si aucun
    /// n'est en cours, sinon attend celui en cours. Dans les deux cas le
    /// spinner de pull-to-refresh reste affiché jusqu'à la fin.
    @MainActor
    private func pullToRefreshDates() async {
        autoTriggersPaused = false
        showRefreshAnnouncement()
        // Aussi : on retente la génération des aperçus pour lesquels
        // une tentative précédente a échoué (previewPath == ""). On
        // remet leur path à nil et triggerPendingPreviews relancera la
        // génération au prochain cycle.
        retryFailedPreviews()
        // Et le reverse geocoding des photos visibles avec lat/lon mais
        // sans placeName — `startReverseGeocode` n'est sinon déclenché
        // que par le `.onAppear` de la ligne, donc une photo dont la
        // localisation a été annulée via 1C reste sans placeName tant
        // que l'utilisateur ne scrolle pas.
        retryPendingGeocodesForCurrent()
        // Idem pour les titres HTML des URLs visibles sans titre.
        retryPendingTitlesForCurrent()
        // Idem pour les traductions Apple non encore appliquées.
        retryPendingTranslationsForCurrent()
        // Idem pour les OCR Vision en échec.
        retryFailedOCRsForCurrent()
        // Idem pour les transcriptions audio cancellées avant
        // complétion (le speech-to-text est on-device et gratuit).
        retryPendingAudioTranscriptionsForCurrent()
        if let existing = refreshTask {
            await existing.value
            return
        }
        guard hasURLItems else { return }
        let task = Task { @MainActor in
            await refreshAllURLDates()
        }
        refreshTask = task
        updateBackgroundTasksCount()
        await task.value
        refreshTask = nil
        updateBackgroundTasksCount()
    }

    /// Lance le reverse geocoding pour chaque photo actuellement
    /// affichée qui a des coordonnées GPS mais pas encore de
    /// `placeName` (ou un placeName vide signifiant échec antérieur),
    /// et qui n'est pas déjà en cours. Sert à boucher le trou : sinon
    /// `startReverseGeocode` n'est appelée QUE depuis le `.onAppear`
    /// de la ligne, donc une photo dont le geocoding a été annulé
    /// (Stop refreshing avant fin) reste sans placeName tant que
    /// l'utilisateur ne scrolle pas la ligne hors / dans le viewport.
    private func retryPendingGeocodesForCurrent() {
        for it in currentItems
            where it.effectiveKind == "photo"
                && it.latitude != nil
                && it.longitude != nil
                && (it.placeName == nil || it.placeName == "")
                && !geocodingIDs.contains(it.id) {
            // Reset éventuel d'un placeName "" (échec antérieur) à nil
            // pour que `startReverseGeocode` puisse réécrire le résultat.
            if it.placeName == "" {
                if let idx = items.firstIndex(where: { $0.id == it.id }) {
                    items[idx].placeName = nil
                }
            }
            startReverseGeocode(for: it)
        }
    }

    private func retryFailedPreviews() {
        // On ne retente QUE les aperçus avec `previewPath == ""`
        // (échec d'une tentative précédente OU effacement volontaire
        // via « Clear previews of these URLs ») des items actuellement
        // affichés dans la liste principale. Idem refresh des dates
        // URL : on travaille sur une copie locale pour ne déclencher
        // qu'UNE seule réassignation de @State (sinon les Menus de la
        // toolbar clignotent).
        let visibleIDs = Set(currentItems.map(\.id))
        var newItems = items
        var changed = false
        for idx in newItems.indices
            where newItems[idx].previewPath == ""
                && newItems[idx].previewLocked != true
                && visibleIDs.contains(newItems[idx].id) {
            newItems[idx].previewPath = nil
            changed = true
        }
        if changed {
            items = newItems
            saveItems()
        }
        triggerPendingPreviews()
    }

    /// Vrai dès qu'au moins une tâche asynchrone est en cours pour
    /// l'app : refresh batch des dates, génération d'aperçu, fetch
    /// d'une date URL individuelle, description IA / transcription
    /// audio, ou reverse-geocoding. Sert au menu « … » pour basculer
    /// l'entrée en mode « Stop refreshing » même quand le travail a
    /// été lancé via un menu contextuel d'une seule ligne.
    private var hasAnyActiveRefresh: Bool {
        refreshTask != nil
            || !previewTasks.isEmpty
            || !aiTasks.isEmpty
            || !dateFetchTasks.isEmpty
            || !geocodeTasks.isEmpty
            || !titleFetchTasks.isEmpty
            || !ocrTasks.isEmpty
            || !pendingLabelTranslations.isEmpty
    }

    private func toggleRefreshAllDates() {
        if hasAnyActiveRefresh {
            refreshTask?.cancel()
            refreshTask = nil
            // Stop refreshing → annule TOUTES les tâches en vol, peu
            // importe leur nature (preview, IA / transcription, fetch
            // de date, geocoding). La roue dentée et tous les
            // « Fetching… » disparaissent immédiatement de l'UI.
            cancelAllRunningTasks()
        } else {
            // Reprend les auto-triggers (peut avoir été mis en pause
            // par un précédent Stop refreshing) puis comportement
            // strictement identique au pull-to-refresh : overlay
            // d'annonce + retry des aperçus en échec + refresh des
            // dates URL.
            autoTriggersPaused = false
            showRefreshAnnouncement()
            retryFailedPreviews()
            retryPendingGeocodesForCurrent()
            retryPendingTitlesForCurrent()
            retryPendingTranslationsForCurrent()
            retryFailedOCRsForCurrent()
            retryPendingAudioTranscriptionsForCurrent()
            refreshTask = Task { @MainActor in
                await refreshAllURLDates()
                refreshTask = nil
                updateBackgroundTasksCount()
            }
            updateBackgroundTasksCount()
        }
    }

    /// Annule toutes les tâches asynchrones en cours et nettoie l'UI :
    /// génération d'aperçus, description IA, transcription audio,
    /// fetch Last-Modified, reverse-geocoding.
    /// Recalcule le nombre total de tâches en vol et le publie via le
    /// singleton observé par `StatsPanelView`. À appeler après chaque
    /// modification d'un des dictionnaires de Tasks ou de `refreshTask`.
    private func updateBackgroundTasksCount() {
        let total = previewTasks.count
                  + aiTasks.count
                  + dateFetchTasks.count
                  + geocodeTasks.count
                  + titleFetchTasks.count
                  + ocrTasks.count
                  + pendingLabelTranslations.count
                  + (refreshTask != nil ? 1 : 0)
        if BackgroundTasksMonitor.shared.activeCount != total {
            BackgroundTasksMonitor.shared.activeCount = total
        }
    }

    private func cancelAllRunningTasks() {
        for (_, task) in previewTasks    { task.cancel() }
        for (_, task) in aiTasks         { task.cancel() }
        for (_, task) in dateFetchTasks  { task.cancel() }
        for (_, task) in geocodeTasks    { task.cancel() }
        for (_, task) in titleFetchTasks { task.cancel() }
        // Pour les OCR en vol : on cancel ET on marque les items
        // concernés comme `ocrFailed = true` afin que
        // `triggerPendingOCR` ne les relance pas immédiatement
        // (autoTriggersPaused bloque déjà mais ça libère l'utilisateur
        // après une éventuelle reprise via Refresh).
        let cancelledOCRIDs = Array(ocrTasks.keys)
        for (_, task) in ocrTasks { task.cancel() }
        if !cancelledOCRIDs.isEmpty {
            var newItems = items
            for idx in newItems.indices where cancelledOCRIDs.contains(newItems[idx].id) {
                newItems[idx].ocrDone = true
                newItems[idx].ocrFailed = true
            }
            items = newItems
            saveItems()
        }
        previewTasks.removeAll()
        aiTasks.removeAll()
        dateFetchTasks.removeAll()
        geocodeTasks.removeAll()
        titleFetchTasks.removeAll()
        ocrTasks.removeAll()
        // Vide la queue de traduction Apple : les jobs restants ne
        // seront pas traduits ; ils pourront être ré-enqueués via 1A,
        // 1B ou « Refresh AI text » si nécessaire.
        pendingLabelTranslations.removeAll()
        generatingPreviewIDs.removeAll()
        describingIDs.removeAll()
        fetchingDateIDs.removeAll()
        geocodingIDs.removeAll()
        // Pause les auto-triggers : sans cette pause, le timer 100 ms
        // verrait `previewPath == nil` etc. et relancerait aussitôt
        // une nouvelle génération → roue dentée éternelle.
        autoTriggersPaused = true
        updateBackgroundTasksCount()
    }

    @MainActor
    private func refreshAllURLDates() async {
        // Snapshot des URLs visibles dans la liste principale au moment
        // du lancement — on ne traite QUE ce qui est affiché (filtres
        // / smart folder / dossier / recherche pris en compte).
        let urlItems = currentItems.filter { $0.effectiveKind == "url" }
        let allIDs = Set(urlItems.map(\.id))

        // Une SEULE mutation @State pour marquer toutes les URLs comme
        // « en cours de fetch ». Sans ça, on faisait .insert puis
        // .remove pour chaque URL → 2 re-renders/URL → toolbar (et ses
        // Menus) clignotait pendant tout le refresh.
        fetchingDateIDs.formUnion(allIDs)

        // Buffer LOCAL de TOUS les résultats (pas du @State). Aucune
        // re-render pendant la collecte.
        var pendingDates: [(id: String, date: Date)] = []

        for chunk in urlItems.chunked(into: 4) {
            if Task.isCancelled { break }
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
                    if let maybeDate {
                        pendingDates.append((id, maybeDate))
                    } else if let item = items.first(where: { $0.id == id }),
                              item.modifiedAt == nil {
                        pendingDates.append((id, Date(timeIntervalSince1970: item.timestamp)))
                    }
                }
            }
        }

        // Une SEULE mutation @State à la fin pour libérer le set des
        // « en cours », même chose pour `items` via le batch. Total
        // côté @State pour tout le refresh : 2 mutations (au lieu de
        // ~3 × N).
        fetchingDateIDs.subtract(allIDs)
        if !pendingDates.isEmpty {
            applyDateUpdatesBatch(pendingDates)
        }
    }

    /// Applique en lot plusieurs `updateItemModifiedAt` : modifie une
    /// COPIE locale de `items`, puis assigne UNE SEULE FOIS le tableau
    /// résultant à `@State items`. Une seule re-évaluation du body de
    /// ContentView par chunk → la toolbar reste stable pendant un
    /// refresh massif.
    private func applyDateUpdatesBatch(_ updates: [(id: String, date: Date)]) {
        var newItems = items
        for (id, date) in updates {
            guard let idx = newItems.firstIndex(where: { $0.id == id }) else { continue }
            let newTimestamp = date.timeIntervalSince1970
            let oldModified = newItems[idx].modifiedAt
            newItems[idx].modifiedAt = newTimestamp
            if newItems[idx].effectiveKind == "url",
               let old = oldModified, newTimestamp > old,
               newItems[idx].previewPath != nil {
                newItems[idx].previewPath = nil
            }
        }
        items = newItems
        saveItems()
    }

    // MARK: - Title fetching

    private func fetchTitle(for item: SharedItem) {
        guard item.title == nil || item.title?.isEmpty == true,
              let url = URL(string: item.url),
              url.scheme == "http" || url.scheme == "https" else { return }
        // Gate anti-doublon : si une fetch est déjà en vol pour cet
        // item (ex: la ligne ré-affichée plusieurs fois en peu de
        // temps), on ne lance pas un 2ᵉ HEAD HTTP.
        guard !titleFetchTasks.keys.contains(item.id) else { return }
        // Bloque les retentatives automatiques après échec : si la
        // dernière tentative n'a pas trouvé de balise <title>, on ne
        // re-spamme pas le serveur à chaque scroll. L'utilisateur peut
        // forcer via 1A/1B.
        guard item.titleFetchFailed != true else { return }

        let id = item.id
        var req = URLRequest(url: url)
        req.timeoutInterval = 10  // timeout explicite, sinon URLSession utilise 60 s par défaut
        let task = Task.detached(priority: .utility) {
            let title: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                let dataTask = URLSession.shared.dataTask(with: req) { data, _, _ in
                    guard let data, let html = String(data: data, encoding: .utf8),
                          let match = html.range(of: "<title[^>]*>([^<]+)</title>", options: .regularExpression) else {
                        cont.resume(returning: nil); return
                    }
                    let tag = html[match]
                    guard let start = tag.firstIndex(of: ">"),
                          let end = tag.range(of: "</title>") else {
                        cont.resume(returning: nil); return
                    }
                    let raw = tag[tag.index(after: start)..<end.lowerBound]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let decoded = Self.decodeHTMLEntities(String(raw))
                    cont.resume(returning: decoded.isEmpty ? nil : decoded)
                }
                dataTask.resume()
            }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                titleFetchTasks.removeValue(forKey: id)
                updateBackgroundTasksCount()
                if let title {
                    updateItemTitle(id: id, to: title)
                } else {
                    // Échec : on marque pour ne pas re-spammer.
                    if let idx = items.firstIndex(where: { $0.id == id }) {
                        items[idx].titleFetchFailed = true
                        saveItems()
                    }
                }
            }
        }
        titleFetchTasks[id] = task
        updateBackgroundTasksCount()
    }

    /// Lance le fetch du <title> HTML pour chaque URL de
    /// `currentItems` qui n'a pas (encore) de titre. Sert au refresh
    /// global (1A et 1B) pour boucher le trou : sans ça, un titre
    /// jamais récupéré n'est plus retenté que via le `.onAppear` de
    /// la ligne.
    private func retryPendingTitlesForCurrent() {
        // Reset des marqueurs d'échec pour permettre la nouvelle
        // tentative — `fetchTitle` vérifie ensuite `titleFetchFailed
        // != true` donc il faut d'abord remettre à nil.
        var newItems = items
        var changed = false
        let visibleIDs = Set(currentItems.map(\.id))
        for idx in newItems.indices
            where newItems[idx].effectiveKind == "url"
                && newItems[idx].titleFetchFailed == true
                && visibleIDs.contains(newItems[idx].id) {
            newItems[idx].titleFetchFailed = nil
            changed = true
        }
        if changed {
            items = newItems
            saveItems()
        }
        for it in currentItems
            where it.effectiveKind == "url"
                && (it.title == nil || it.title?.isEmpty == true)
                && !titleFetchTasks.keys.contains(it.id) {
            fetchTitle(for: it)
        }
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

/// Applique un toolbarBackground bleu en dégradé uniquement quand un filtre
/// est actif — sinon laisse le système gérer la barre normale (même
/// pendant le scroll).
struct FilterToolbarBackground: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        // Toujours appliquer les MÊMES modifiers (même structure de vue)
        // pour ne pas faire de switch entre deux arbres de vues distincts
        // — SwiftUI reconstruit alors la nav bar UIKit à chaque re-render
        // du parent, ce qui fait clignoter les Menus à l'intérieur. On
        // varie uniquement les VALEURS des modifiers.
        content
            .toolbarBackground(
                LinearGradient(
                    colors: active
                        ? [Color.blue.opacity(0.22), Color.blue.opacity(0.16)]
                        : [Color.clear, Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                for: .navigationBar
            )
            .toolbarBackground(active ? .visible : .automatic, for: .navigationBar)
    }
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
    /// Appelé en cas d'échec de la traduction d'un job (réseau, langue
    /// non disponible, session invalidée, etc.) pour que le caller
    /// puisse marquer l'item comme « tenté » et éviter les retries
    /// infinis.
    let onFailed: (_ id: String) -> Void

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
        // Cible : la langue préférée de l'utilisateur (et non pas la langue
        // de développement de l'app, qui peut rester l'anglais quand
        // l'utilisateur n'a pas téléchargé une langue Translation pour
        // chaque locale supportée).
        let target: Locale.Language = {
            if let pref = Locale.preferredLanguages.first {
                return Locale.Language(identifier: pref)
            }
            return Locale.current.language
        }()
        if config == nil {
            config = TranslationSession.Configuration(
                source: Locale.Language(identifier: "en"),
                target: target
            )
        } else {
            // Pattern recommandé Apple : invalider l'ancienne config pour
            // que .translationTask ré-exécute son action avec une nouvelle
            // session. Recréer une config "égale" ne déclenche rien.
            config?.invalidate()
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
                await MainActor.run {
                    onFailed(job.id)
                }
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

// MARK: - Preview generation (320x200 PNG)

/// Génère un aperçu uniforme 320x200 pour chaque item partagé. L'image
/// finale est toujours en 320x200 ; l'objet d'origine est redimensionné
/// pour rentrer dedans en conservant son ratio, et le reste de la toile
/// est laissé transparent.
///
/// Traitement par type d'objet :
/// - **photo** : chargement direct de l'UIImage, scale "aspect fit" dans
///   la toile, pas de transformation supplémentaire.
/// - **video** : extraction de la première frame via
///   `AVAssetImageGenerator` (orientation respectée), puis même rendu
///   "aspect fit" que pour une photo.
/// - **audio** : icône `waveform` de SF Symbols rendue centrée sur fond
///   transparent (pas de waveform réel pour rester rapide et hors-ligne).
/// - **text** : les premières ~120 caractères dessinés sur fond
///   transparent en font système 12pt, alignés en haut-gauche avec
///   marge.
/// - **file** : icône `doc.fill` SF Symbol centrée + nom de fichier
///   tronqué dessous.
/// - **url** : tente d'abord de récupérer l'image OpenGraph (`og:image`
///   ou `twitter:image`) du HTML — si trouvée, rendue en aspect-fit ;
///   sinon le titre + l'hôte sont dessinés en texte sur fond
///   transparent (icône globe en filigrane).
enum PreviewGenerator {
    static let size = CGSize(width: 320, height: 200)

    /// Renvoie le nom de fichier (sans chemin) du PNG sauvegardé dans
    /// `previews/` du container App Group, ou nil en cas d'échec.
    static func generate(for item: SharedItem) async -> String? {
        let kind = item.effectiveKind
        let image: UIImage?
        switch kind {
        case "photo":
            image = await renderPhoto(urlString: item.url)
        case "video":
            image = await renderVideo(urlString: item.url)
        case "audio":
            // Si la transcription speech-to-text est terminée et a
            // produit un texte, on rend un aperçu type « page »
            // identique au type texte. Sinon (transcription pas
            // encore finie ou échouée), on retombe sur l'icône
            // waveform.
            if item.aiDescribed == true,
               let title = item.title, !title.isEmpty {
                image = await renderText(title)
            } else {
                image = await renderSymbol("waveform", color: .systemTeal)
            }
        case "text":
            image = await renderText(item.url)
        case "file":
            // QuickLook fournit nativement une miniature de la 1ʳᵉ
            // page pour les types qu'il sait afficher (PDF, Office,
            // iWork, RTF, code…). Si ça échoue (format inconnu, fichier
            // corrompu, timeout), on retombe sur l'icône doc.fill +
            // nom de fichier.
            if let qlImage = await renderFileQuickLook(urlString: item.url) {
                image = await scaleAspectFit(image: qlImage)
            } else {
                image = await renderFile(urlString: item.url, title: item.title)
            }
        default: // "url"
            let raw = item.originalURL ?? item.url
            // Cas spécial YouTube : on récupère directement la miniature
            // publique (img.youtube.com/vi/<id>/maxresdefault.jpg). Pas de
            // cookies, pas de bannière de consentement, pas d'erreur 153
            // sur les vidéos qui bloquent l'embed.
            if let ytThumb = await fetchYouTubeThumbnail(urlString: raw) {
                image = await scaleAspectFit(image: ytThumb)
            } else if let snap = await renderWebPage(urlString: raw) {
                image = snap
            } else {
                image = await renderURLPlaceholder(title: item.title, url: raw)
            }
        }
        guard let img = image else { return nil }
        return savePNG(img, id: item.id)
    }

    private static func renderPhoto(urlString: String) async -> UIImage? {
        guard let url = URL(string: urlString), url.isFileURL,
              let data = try? Data(contentsOf: url),
              let img = UIImage(data: data) else { return nil }
        return await scaleAspectFit(image: img)
    }

    private static func renderVideo(urlString: String) async -> UIImage? {
        guard let url = URL(string: urlString), url.isFileURL else { return nil }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return await scaleAspectFit(image: UIImage(cgImage: cg))
    }

    private static func renderSymbol(_ systemName: String, color: UIColor) async -> UIImage {
        let cfg = UIImage.SymbolConfiguration(pointSize: 96, weight: .regular)
        let symbol = UIImage(systemName: systemName, withConfiguration: cfg)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        return await blankCanvas { ctx in
            if let s = symbol {
                let ratio = min(140 / s.size.width, 140 / s.size.height)
                let w = s.size.width * ratio
                let h = s.size.height * ratio
                let rect = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
                s.draw(in: rect)
            }
            _ = ctx
        }
    }

    /// Rend l'item texte comme une « page » : fond blanc, marges
    /// fines, texte noir en très petite taille (6 pt logique = 18 pt
    /// stocké en ×3, donc lisible quand on zoome dans la grille
    /// d'aperçus). Le texte s'écoule en multi-ligne via
    /// `.usesLineFragmentOrigin` et est naturellement clippé en bas si
    /// trop long, comme un screenshot du haut d'une page web.
    private static func renderText(_ raw: String) async -> UIImage {
        return await blankCanvas { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            let style = NSMutableParagraphStyle()
            style.alignment = .left
            style.lineBreakMode = .byWordWrapping
            style.lineSpacing = 0.5
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 6, weight: .regular),
                .foregroundColor: UIColor.black,
                .paragraphStyle: style
            ]
            let inset: CGFloat = 6
            let rect = CGRect(x: inset, y: inset,
                              width: size.width - 2 * inset,
                              height: size.height - 2 * inset)
            // `.usesLineFragmentOrigin` enchaîne les lignes ; pas de
            // `truncatesLastVisibleLine` → le clipping naturel coupe
            // simplement en bas, comme une capture du haut de page.
            (raw as NSString).draw(with: rect,
                                   options: [.usesLineFragmentOrigin],
                                   attributes: attrs,
                                   context: nil)
        }
    }

    /// Capture la 1ʳᵉ page d'un fichier via QuickLookThumbnailing
    /// (PDF, Office, iWork, RTF, code, etc.). Renvoie nil sur format
    /// non supporté ou timeout (10 s) — l'appelant retombe alors sur
    /// le rendu icône + nom de fichier.
    static func renderFileQuickLook(urlString: String) async -> UIImage? {
        guard let url = URL(string: urlString), url.isFileURL else { return nil }
        // Demande une miniature plus grande que 320×200 pour tenir
        // compte du downscale ×3 ensuite — pixels nets en zoom.
        let req = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 640, height: 400),
            scale: 3,
            representationTypes: .thumbnail
        )
        return await snapshotWithTimeout(seconds: 10) { complete in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                complete(rep?.uiImage)
            }
        }
    }

    private static func renderFile(urlString: String, title: String?) async -> UIImage {
        let cfg = UIImage.SymbolConfiguration(pointSize: 90, weight: .regular)
        let icon = UIImage(systemName: "doc.fill", withConfiguration: cfg)?
            .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
        let label = title ?? URL(string: urlString)?.lastPathComponent ?? "file"
        return await blankCanvas { _ in
            if let icon = icon {
                let r = CGRect(x: (size.width - 90) / 2, y: 30, width: 90, height: 110)
                icon.draw(in: r)
            }
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingMiddle
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.label,
                .paragraphStyle: style
            ]
            let rect = CGRect(x: 8, y: 150, width: size.width - 16, height: 40)
            (label as NSString).draw(with: rect,
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: attrs,
                                     context: nil)
        }
    }

    private static func renderURLPlaceholder(title: String?, url: String) async -> UIImage {
        let host = URL(string: url)?.host ?? url
        let main = title ?? host
        let cfg = UIImage.SymbolConfiguration(pointSize: 70, weight: .regular)
        let globe = UIImage(systemName: "globe", withConfiguration: cfg)?
            .withTintColor(.systemGreen.withAlphaComponent(0.35), renderingMode: .alwaysOriginal)
        return await blankCanvas { _ in
            if let g = globe {
                let r = CGRect(x: size.width - 86, y: size.height - 86, width: 70, height: 70)
                g.draw(in: r)
            }
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
            let titleStyle = NSMutableParagraphStyle()
            titleStyle.lineBreakMode = .byTruncatingTail
            var titleAttrs2 = titleAttrs
            titleAttrs2[.paragraphStyle] = titleStyle
            (main as NSString).draw(with: CGRect(x: 12, y: 12, width: size.width - 24, height: 80),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: titleAttrs2,
                                    context: nil)
            let hostAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.secondaryLabel
            ]
            (host as NSString).draw(at: CGPoint(x: 12, y: size.height - 28), withAttributes: hostAttrs)
        }
    }

    /// Extrait l'identifiant vidéo YouTube d'une URL si possible.
    /// Supporte youtube.com/watch?v=, youtu.be/, youtube.com/embed/,
    /// youtube.com/shorts/, et la variante interne yout-ube.com.
    static func extractYouTubeID(_ urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else { return nil }
        if host == "youtu.be" {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        if host.hasSuffix("youtube.com") || host.hasSuffix("yout-ube.com") {
            if url.path == "/watch",
               let comp = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let v = comp.queryItems?.first(where: { $0.name == "v" })?.value {
                return v
            }
            for prefix in ["/embed/", "/shorts/", "/v/"] {
                if url.path.hasPrefix(prefix) {
                    return String(url.path.dropFirst(prefix.count))
                }
            }
        }
        return nil
    }

    /// Récupère la miniature haute résolution d'une vidéo YouTube depuis
    /// `img.youtube.com/vi/<id>/...`. Aucun cookie, aucune session.
    /// Tente d'abord `maxresdefault.jpg` (1280×720), sinon `hqdefault.jpg`
    /// (480×360) qui est garanti pour toute vidéo publique.
    static func fetchYouTubeThumbnail(urlString: String) async -> UIImage? {
        guard let id = extractYouTubeID(urlString) else { return nil }
        let candidates = [
            "https://img.youtube.com/vi/\(id)/maxresdefault.jpg",
            "https://img.youtube.com/vi/\(id)/hqdefault.jpg"
        ]
        for thumb in candidates {
            guard let url = URL(string: thumb) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            if let (data, response) = try? await URLSession.shared.data(for: req),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               data.count > 2000, // YouTube renvoie une mini placeholder ~1.5KB en cas d'absence
               let img = UIImage(data: data) {
                return img
            }
        }
        return nil
    }

    /// Réécrit une URL YouTube vers le domaine `youtube-nocookie.com`
    /// pour la capture d'aperçu : pas de cookies, pas de bandeau de
    /// consentement RGPD, donc une miniature plus propre. Les URLs non
    /// YouTube sont renvoyées telles quelles.
    static func rewriteYouTubeNoCookie(_ urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else { return urlString }
        // youtu.be/<id> → youtube-nocookie.com/embed/<id>
        if host == "youtu.be" {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !id.isEmpty {
                return "https://www.youtube-nocookie.com/embed/\(id)"
            }
        }
        // youtube.com/watch?v=<id> → youtube-nocookie.com/embed/<id>
        if host.hasSuffix("youtube.com") || host.hasSuffix("yout-ube.com") {
            if url.path == "/watch",
               let comp = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let v = comp.queryItems?.first(where: { $0.name == "v" })?.value {
                return "https://www.youtube-nocookie.com/embed/\(v)"
            }
            // youtube.com/embed/<id> → youtube-nocookie.com/embed/<id>
            if url.path.hasPrefix("/embed/") {
                return "https://www.youtube-nocookie.com\(url.path)"
            }
            // youtube.com/shorts/<id> → youtube-nocookie.com/embed/<id>
            if url.path.hasPrefix("/shorts/") {
                let id = String(url.path.dropFirst("/shorts/".count))
                if !id.isEmpty {
                    return "https://www.youtube-nocookie.com/embed/\(id)"
                }
            }
        }
        return urlString
    }

    /// Charge la page web dans un WKWebView hors écran, attend la fin du
    /// chargement (avec un délai de grâce pour laisser les CSS/images
    /// s'appliquer) puis prend un cliché du haut de la page (1024×640).
    /// Le cliché est ensuite scaled aspect-fit dans 320×200. Renvoie nil
    /// si le chargement échoue ou que la capture n'aboutit pas.
    @MainActor
    static func renderWebPage(urlString: String) async -> UIImage? {
        guard let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https" else { return nil }

        // Skip immédiat si la Task a été annulée AVANT l'acquisition de
        // la sémaphore (cas typique : utilisateur a fait Stop refreshing
        // pendant que l'item était queueé).
        if Task.isCancelled { return nil }

        // SÉRIALISATION : un seul rendu WKWebView à la fois pour toute
        // l'app.
        await WebPageRenderSemaphore.shared.acquire()
        defer { WebPageRenderSemaphore.shared.release() }

        // Skip après acquisition aussi : si la Task a été annulée
        // pendant qu'elle attendait son tour, on libère la sémaphore
        // sans faire de travail WebKit. Sans cette vérif, toutes les
        // tâches en file (annulées) auraient quand même drainé une à
        // une avec leur cycle complet de capture → blocage long pour
        // les nouvelles régénérations.
        if Task.isCancelled { return nil }

        // Rendu en haute résolution puis réduit en aspect-fit avec
        // interpolation .high → évite l'effet d'escalier visible quand on
        // resize une petite capture vers une vue zoomée.
        let viewportSize = CGSize(width: 1920, height: 1200)
        let config = WKWebViewConfiguration()
        let offscreenFrame = CGRect(x: -40_000, y: -40_000,
                                    width: viewportSize.width,
                                    height: viewportSize.height)
        let webView = WKWebView(frame: offscreenFrame, configuration: config)
        webView.isOpaque = true
        webView.backgroundColor = .white

        let host = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene) }
            .first?.windows.first { $0.isKeyWindow }
        host?.addSubview(webView)

        let delegate = WebPreviewLoadDelegate()
        webView.navigationDelegate = delegate
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        webView.load(req)

        let loaded = await delegate.waitForFinish(timeout: 12)

        // Re-vérifie : annulée pendant le load → on saute la capture.
        if Task.isCancelled {
            webView.navigationDelegate = nil
            webView.stopLoading()
            webView.removeFromSuperview()
            return nil
        }

        var bigSnapshot: UIImage? = nil
        if loaded {
            // Délai supplémentaire (2,5 s) avant la capture, pour
            // laisser le temps :
            //   - aux images / fonts / animations CSS de se stabiliser,
            //   - aux lecteurs vidéo injectés en JS d'apparaître (sur
            //     certains sites le player ne devient visible qu'au bout
            //     de ~0,5 s après que la navigation soit déclarée
            //     terminée par WKWebView).
            try? await Task.sleep(nanoseconds: 2_500_000_000)

            let snap = WKSnapshotConfiguration()
            snap.rect = CGRect(origin: .zero, size: viewportSize)

            // takeSnapshot peut ne JAMAIS rappeler son completion si le
            // WebContent process plante en arrière-plan. Sans timeout,
            // on hang ad vitam dans cet `await`, le `defer` qui libère
            // le sémaphore ne s'exécute pas, et toutes les
            // regénérations d'URL suivantes restent bloquées en file.
            // On wrap dans un timeout de 10 s.
            bigSnapshot = await snapshotWithTimeout(seconds: 10) { complete in
                webView.takeSnapshot(with: snap) { image, _ in
                    complete(image)
                }
            }
        }

        // Détacher proprement le delegate AVANT removeFromSuperview pour
        // éviter qu'un commitLayerTree en cours appelle un délégué dont
        // la durée de vie est terminée.
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        // Petit délai pour laisser WebKit finaliser ses layer commits
        // avant qu'on libère la sémaphore et qu'un nouveau WKWebView soit
        // créé.
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard let big = bigSnapshot else { return nil }
        let prepared = autoCropEnabled ? cropToContentBoundingBox(big) : big
        return await scaleAspectFit(image: prepared)
    }

    /// Lance une opération à callback (`takeSnapshot` etc.) avec un
    /// timeout. La première résolution gagne (callback ou minuteur),
    /// l'autre est ignorée silencieusement. Crucial : on N'ATTEND PAS
    /// la callback si elle ne vient pas — sinon, comme `takeSnapshot`
    /// peut ne jamais rappeler quand le WebContent process meurt, on
    /// se retrouvait bloqué pour toujours et la roue restait à
    /// l'écran.
    @MainActor
    static func snapshotWithTimeout(
        seconds: TimeInterval,
        operation: (@escaping (UIImage?) -> Void) -> Void
    ) async -> UIImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let state = SnapshotTimeoutState()
            let resume: (UIImage?) -> Void = { img in
                state.lock.lock()
                let already = state.resumed
                state.resumed = true
                state.lock.unlock()
                if !already {
                    cont.resume(returning: img)
                }
            }
            operation(resume)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                resume(nil)
            }
        }
    }

    /// Petite classe support pour synchroniser le « premier appelant
    /// gagne » sur la callback de `snapshotWithTimeout` (NSLock + Bool).
    final class SnapshotTimeoutState {
        let lock = NSLock()
        var resumed: Bool = false
    }

    /// Wrapper générique de timeout pour une fonction async qui renvoie
    /// un `T?`. La première résolution gagne (operation ou minuteur),
    /// l'autre est ignorée silencieusement. Utile pour `recognizeText`
    /// (Vision OCR) ou tout autre call async sans timeout interne.
    static func withTimeout<T>(seconds: TimeInterval,
                               operation: @escaping () async -> T?) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let state = SnapshotTimeoutState()
            let resume: (T?) -> Void = { val in
                state.lock.lock()
                let already = state.resumed
                state.resumed = true
                state.lock.unlock()
                if !already {
                    cont.resume(returning: val)
                }
            }
            Task {
                let result = await operation()
                resume(result)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                resume(nil)
            }
        }
    }

    /// Sémaphore async qui sérialise les rendus WKWebView. Un seul
    /// rendu en cours à la fois pour toute l'app. Implémenté avec
    /// `NSLock` (et non pas un `actor`) pour que `release()` soit
    /// SYNCHRONE → utilisable depuis `defer { }` sans `await`.
    final class WebPageRenderSemaphore {
        static let shared = WebPageRenderSemaphore()
        private let lock = NSLock()
        private var inUse: Bool = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            lock.lock()
            if !inUse {
                inUse = true
                lock.unlock()
                return
            }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                waiters.append(cont)
                lock.unlock()
            }
        }

        func release() {
            lock.lock()
            if !waiters.isEmpty {
                let c = waiters.removeFirst()
                lock.unlock()
                c.resume()
            } else {
                inUse = false
                lock.unlock()
            }
        }
    }

    /// Récupère la balise OpenGraph image d'une page web. Renvoie nil
    /// silencieusement en cas d'erreur, taille > 4 MB, etc.
    private static func fetchOpenGraphImage(urlString: String) async -> UIImage? {
        guard let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Mozilla/5.0 (compatible; ShareManager/1.0)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data.prefix(200_000), encoding: .utf8) else { return nil }
        let candidates = ["property=\"og:image\"", "name=\"twitter:image\"", "property=\"og:image:url\""]
        for marker in candidates {
            if let range = html.range(of: marker) {
                let after = html[range.upperBound...]
                if let contentRange = after.range(of: "content=\"") {
                    let rest = after[contentRange.upperBound...]
                    if let endQuote = rest.firstIndex(of: "\"") {
                        let imgURLString = String(rest[..<endQuote])
                        if let imgURL = URL(string: imgURLString, relativeTo: url),
                           let (imgData, _) = try? await URLSession.shared.data(from: imgURL),
                           imgData.count < 4_000_000,
                           let img = UIImage(data: imgData) {
                            return img
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func scaleAspectFit(image: UIImage) async -> UIImage {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return await blankCanvas { _ in } }
        let ratio = min(size.width / imgSize.width, size.height / imgSize.height)
        let drawSize = CGSize(width: imgSize.width * ratio, height: imgSize.height * ratio)
        let origin = CGPoint(x: (size.width - drawSize.width) / 2,
                             y: (size.height - drawSize.height) / 2)
        return await blankCanvas { ctx in
            // Interpolation haute qualité (Lanczos-like) pour éviter le
            // crénelage / pixelisation lors du downscale d'une capture HD.
            ctx.interpolationQuality = .high
            ctx.setShouldAntialias(true)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }

    /// Lecture (non-cachée) du toggle utilisateur « Auto-crop URL
    /// previews ». Vrai par défaut quand la clé n'a jamais été écrite,
    /// pour activer la fonctionnalité d'office sans migration.
    private static var autoCropEnabled: Bool {
        (UserDefaults.standard.object(forKey: "autoCropMonochromePreviews") as? Bool) ?? true
    }

    /// Si l'image présente une grande bordure monochrome (ex. capture
    /// d'une page web qui dessine un lecteur vidéo centré sur fond
    /// noir), renvoie un crop sur la zone d'intérêt. Sinon renvoie
    /// l'image inchangée.
    ///
    /// Algorithme :
    ///   1. Downscale en 160×N RGBA (~64 KB de buffer).
    ///   2. Couleur de fond = médiane par canal des 4 bandes de bordure.
    ///   3. Pixel « intéressant » = distance L1 au fond > 90.
    ///   4. Calcule densité = N_interesting / aire(bbox-all-interesting).
    ///      - Densité élevée (≥ 50 %) : le contenu remplit globalement
    ///        la page → on garde la bbox-all (= page presque pleine
    ///        d'éléments, type article Wikipedia). 85 % d'aire ⇒ no-op
    ///        (déjà bien rempli).
    ///      - Densité basse (< 50 %) : la page contient un contenu
    ///        principal isolé sur fond uni, parsemé de petits
    ///        décorateurs UI (texte de header, barre de saisie, etc.).
    ///        On cherche alors la PLUS GROSSE composante connexe
    ///        (4-voisinage) parmi les pixels intéressants : c'est le
    ///        contenu principal. Sa bbox seule est utilisée — les
    ///        petits décorateurs (composantes plus petites) sont
    ///        ignorés.
    ///   5. Marge de 4 %, retraduction en coordonnées de l'image
    ///      source, `cgImage.cropping(to:)`.
    private static func cropToContentBoundingBox(_ image: UIImage) -> UIImage {
        // S'assure que l'image a une orientation normalisée (sinon
        // `cgImage` pointerait sur les pixels bruts non orientés, et le
        // crop tomberait à côté).
        let normalized: UIImage
        if image.imageOrientation == .up {
            normalized = image
        } else {
            let r = UIGraphicsImageRenderer(size: image.size)
            normalized = r.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        }
        guard let cg = normalized.cgImage else { return image }
        let srcW = cg.width
        let srcH = cg.height
        guard srcW > 0, srcH > 0 else { return image }

        // Grille de travail réduite. Garde un ratio proche de l'image
        // source pour ne pas distordre la médiane des bords.
        let gridW = 160
        let gridH = max(20, Int((Double(gridW) * Double(srcH) / Double(srcW)).rounded()))
        let bytesPerRow = gridW * 4
        var pixels = [UInt8](repeating: 0, count: gridW * gridH * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels,
                                  width: gridW,
                                  height: gridH,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: gridW, height: gridH))

        // Échantillonne les 4 bandes de bordure (épaisseur 1 px en
        // coords de la grille). Pour chaque canal, prend la médiane.
        var rs = [UInt8]()
        var gs = [UInt8]()
        var bs = [UInt8]()
        rs.reserveCapacity(2 * gridW + 2 * gridH)
        gs.reserveCapacity(2 * gridW + 2 * gridH)
        bs.reserveCapacity(2 * gridW + 2 * gridH)
        func appendPixel(x: Int, y: Int) {
            let i = (y * gridW + x) * 4
            rs.append(pixels[i])
            gs.append(pixels[i + 1])
            bs.append(pixels[i + 2])
        }
        for x in 0..<gridW {
            appendPixel(x: x, y: 0)
            appendPixel(x: x, y: gridH - 1)
        }
        for y in 0..<gridH {
            appendPixel(x: 0, y: y)
            appendPixel(x: gridW - 1, y: y)
        }
        rs.sort(); gs.sort(); bs.sort()
        let bgR = Int(rs[rs.count / 2])
        let bgG = Int(gs[gs.count / 2])
        let bgB = Int(bs[bs.count / 2])

        // Marque les pixels « intéressants » et calcule la bbox-all
        // en parallèle.
        let threshold = 90 // ≈ 30 par canal sur 255 (L1 sur RGB)
        var interesting = [Bool](repeating: false, count: gridW * gridH)
        var nInteresting = 0
        var allMinX = gridW, allMinY = gridH, allMaxX = -1, allMaxY = -1
        for y in 0..<gridH {
            let rowBase = y * gridW * 4
            let maskBase = y * gridW
            for x in 0..<gridW {
                let i = rowBase + x * 4
                let dr = abs(Int(pixels[i]) - bgR)
                let dg = abs(Int(pixels[i + 1]) - bgG)
                let db = abs(Int(pixels[i + 2]) - bgB)
                if dr + dg + db > threshold {
                    interesting[maskBase + x] = true
                    nInteresting += 1
                    if x < allMinX { allMinX = x }
                    if x > allMaxX { allMaxX = x }
                    if y < allMinY { allMinY = y }
                    if y > allMaxY { allMaxY = y }
                }
            }
        }
        // Image entièrement monochrome (rare en pratique — un fond
        // 100 % uni sans la moindre variation) : rien à cropper.
        if allMaxX < 0 { return image }

        let allArea = (allMaxX - allMinX + 1) * (allMaxY - allMinY + 1)
        let totalArea = gridW * gridH
        let density = Double(nInteresting) / Double(allArea)

        // Bbox à utiliser : par défaut, celle de l'union de tous les
        // pixels intéressants ; en cas de page « clairsemée », celle
        // de la plus grosse composante connexe seule.
        var useMinX = allMinX, useMinY = allMinY
        var useMaxX = allMaxX, useMaxY = allMaxY

        if density < 0.5 {
            // Plus grosse composante connexe (4-voisinage). DFS
            // itératif via une pile pour éviter tout débordement de
            // récursion sur de grosses composantes.
            var labels = [Int8](repeating: 0, count: gridW * gridH) // 0 = non visité
            var stack: [Int] = []
            stack.reserveCapacity(256)
            var bestCount = 0
            var bestMinX = 0, bestMinY = 0, bestMaxX = 0, bestMaxY = 0
            for sy in 0..<gridH {
                for sx in 0..<gridW {
                    let sIdx = sy * gridW + sx
                    if !interesting[sIdx] || labels[sIdx] == 1 { continue }
                    stack.removeAll(keepingCapacity: true)
                    stack.append(sIdx)
                    labels[sIdx] = 1
                    var count = 0
                    var cMinX = sx, cMinY = sy, cMaxX = sx, cMaxY = sy
                    while let idx = stack.popLast() {
                        let y = idx / gridW
                        let x = idx - y * gridW
                        count += 1
                        if x < cMinX { cMinX = x }
                        if x > cMaxX { cMaxX = x }
                        if y < cMinY { cMinY = y }
                        if y > cMaxY { cMaxY = y }
                        if x > 0 {
                            let n = idx - 1
                            if interesting[n] && labels[n] == 0 { labels[n] = 1; stack.append(n) }
                        }
                        if x < gridW - 1 {
                            let n = idx + 1
                            if interesting[n] && labels[n] == 0 { labels[n] = 1; stack.append(n) }
                        }
                        if y > 0 {
                            let n = idx - gridW
                            if interesting[n] && labels[n] == 0 { labels[n] = 1; stack.append(n) }
                        }
                        if y < gridH - 1 {
                            let n = idx + gridW
                            if interesting[n] && labels[n] == 0 { labels[n] = 1; stack.append(n) }
                        }
                    }
                    if count > bestCount {
                        bestCount = count
                        bestMinX = cMinX
                        bestMinY = cMinY
                        bestMaxX = cMaxX
                        bestMaxY = cMaxY
                    }
                }
            }
            // Si on a trouvé une composante (toujours vrai puisque
            // nInteresting > 0), on l'utilise.
            if bestCount > 0 {
                useMinX = bestMinX
                useMinY = bestMinY
                useMaxX = bestMaxX
                useMaxY = bestMaxY
            }
        }

        // Garde-fou : si la bbox retenue couvre déjà l'essentiel du
        // viewport, ne pas cropper inutilement.
        let useArea = (useMaxX - useMinX + 1) * (useMaxY - useMinY + 1)
        if Double(useArea) / Double(totalArea) >= 0.85 { return image }

        // Marge de 4 %, retraduction en coordonnées de l'image source.
        let scaleX = Double(srcW) / Double(gridW)
        let scaleY = Double(srcH) / Double(gridH)
        let marginX = Int((Double(gridW) * 0.04).rounded())
        let marginY = Int((Double(gridH) * 0.04).rounded())
        let gMinX = max(0, useMinX - marginX)
        let gMinY = max(0, useMinY - marginY)
        let gMaxX = min(gridW - 1, useMaxX + marginX)
        let gMaxY = min(gridH - 1, useMaxY + marginY)
        let cropX = Int((Double(gMinX) * scaleX).rounded(.down))
        let cropY = Int((Double(gMinY) * scaleY).rounded(.down))
        let cropW = Int((Double(gMaxX - gMinX + 1) * scaleX).rounded(.up))
        let cropH = Int((Double(gMaxY - gMinY + 1) * scaleY).rounded(.up))
        let cropRect = CGRect(
            x: max(0, cropX),
            y: max(0, cropY),
            width: min(srcW - max(0, cropX), max(1, cropW)),
            height: min(srcH - max(0, cropY), max(1, cropH))
        )
        guard let cropped = cg.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: cropped, scale: normalized.scale, orientation: .up)
    }

    /// Tous les rendus passent par cette fonction. Isolée `@MainActor`
    /// parce que les APIs UIKit appelées dans la closure `draw`
    /// (`NSString.draw(with:)`, `UIImage(systemName:)`,
    /// `UIImage.draw(in:)`) ont en pratique une thread-affinity main
    /// thread sur iOS 17/18 — appeler depuis une `Task.detached` non
    /// hoppée pouvait corrompre l'état interne UIKit et crasher dans
    /// `renderer.image` (EXC_BAD_ACCESS).
    ///
    /// Auparavant on faisait `DispatchQueue.main.sync` ici, mais Swift
    /// Concurrency émet un `unsafeForcedSync` quand on appelle ça depuis
    /// un contexte async (cooperative thread pool) — risque de blocage
    /// du pool, crash visible sur iPadOS 18. La bascule `@MainActor` +
    /// `await` côté appelants règle le problème : la runtime hop sur le
    /// main actor sans bloquer le worker thread.
    @MainActor
    private static func blankCanvas(_ draw: (CGContext) -> Void) -> UIImage {
        renderImage(draw: draw)
    }

    @MainActor
    private static func renderImage(draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        // PNG pixel scale = 3× → image stockée 960×600 pixels (logique
        // 320×200) → reste nette même quand l'utilisateur zoome.
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rctx in
            let ctx = rctx.cgContext
            ctx.interpolationQuality = .high
            ctx.setShouldAntialias(true)
            draw(ctx)
        }
    }

    private static func savePNG(_ image: UIImage, id: String) -> String? {
        guard let png = image.pngData() else { return nil }
        let fm = FileManager.default
        guard let container = fm.containerURL(
            forSecurityApplicationGroupIdentifier: "group.net.fenyo.apple.sharemanager") else {
            return nil
        }
        let dir = container.appendingPathComponent("previews", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let filename = "\(id).png"
        let dest = dir.appendingPathComponent(filename)
        do {
            try png.write(to: dest, options: .atomic)
            return filename
        } catch {
            print("Preview save failed: \(error)")
            return nil
        }
    }

    /// Charge un aperçu déjà généré depuis le sous-dossier `previews/`.
    static func loadPreview(filename: String) -> UIImage? {
        guard !filename.isEmpty,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.net.fenyo.apple.sharemanager") else {
            return nil
        }
        let url = container.appendingPathComponent("previews", isDirectory: true)
            .appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

/// Délégué `WKNavigationDelegate` minimal qui expose une attente
/// asynchrone (`waitForFinish`) résolue à `didFinish` ou `didFail`,
/// ou par timeout. Utilisé pour le rendu offscreen des aperçus de pages
/// web.
@MainActor
final class WebPreviewLoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolved = false

    func waitForFinish(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.continuation = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resolve(false)
            }
        }
    }

    private func resolve(_ value: Bool) {
        guard !resolved else { return }
        resolved = true
        continuation?.resume(returning: value)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resolve(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resolve(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resolve(false)
    }
}

// MARK: - Previews sheet (90% × 90%, 2 columns, pinch to zoom)

struct PreviewsSheet: View {
    let items: [SharedItem]
    let onSelect: (SharedItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            // UIScrollView fournit nativement un pinch-zoom centré sur
            // les doigts (comportement standard iOS / iPadOS — Photos,
            // Maps, Safari). On enveloppe la grille SwiftUI dedans.
            ZoomableScrollView(minScale: 0.5, maxScale: 4.0) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                          spacing: 12) {
                    ForEach(items) { item in
                        previewTile(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(item) }
                    }
                }
                .padding(12)
            }
            .navigationTitle("Previews")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func previewTile(item: SharedItem) -> some View {
        PreviewTile(item: item)
    }
}

/// Conteneur `UIScrollView` qui héberge n'importe quel contenu SwiftUI
/// et lui applique le pinch-to-zoom natif iOS — centré sur les doigts,
/// avec inertie de pan, gestion des bords, etc. (comme dans Photos).
struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    let minScale: CGFloat
    let maxScale: CGFloat
    let content: Content

    init(minScale: CGFloat = 0.5,
         maxScale: CGFloat = 4.0,
         @ViewBuilder content: () -> Content) {
        self.minScale = minScale
        self.maxScale = maxScale
        self.content = content()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = minScale
        scrollView.maximumZoomScale = maxScale
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = true

        let host = context.coordinator.host
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(host.view)
        // Le hosted view dimensionne sa hauteur en fonction de la
        // largeur disponible (intrinsic content size de la grille
        // SwiftUI) ; on contraint sa largeur à celle du scroll view
        // pour avoir un layout fluide horizontalement.
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.host.rootView = content
    }

    func makeCoordinator() -> Coordinator { Coordinator(content: content) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let host: UIHostingController<Content>
        init(content: Content) {
            self.host = UIHostingController(rootView: content)
            self.host.view.backgroundColor = .clear
            super.init()
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            host.view
        }
    }
}

/// Aperçu compact affichée à droite d'une ligne de la liste
/// principale. Cache local pour éviter le re-décodage à chaque tick du
/// timer de rechargement (sans ce cache : clignotement).
struct RowThumbnail: View {
    let item: SharedItem
    @State private var cached: UIImage? = nil
    @State private var loadedPath: String? = nil

    var body: some View {
        Group {
            if let img = cached {
                Image(uiImage: img)
                    .resizable()
                    // Zoom ×2 centré : `scaleEffect` agrandit le rendu
                    // sans changer le frame de mise en page, et le
                    // `.clipped()` à l'extérieur recadre. L'aperçu
                    // garde donc strictement la même taille dans la
                    // ligne, mais on voit 2× plus gros le centre.
                    .scaleEffect(item.previewZoomed == true ? 2.0 : 1.0)
                    .clipped()
            } else {
                Color(.tertiarySystemFill)
            }
        }
        .overlay(alignment: .topLeading) {
            if item.previewLocked == true {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if item.previewZoomed == true {
                Text("×2")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(3)
            }
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: item.previewPath) { _, _ in loadIfNeeded() }
    }

    private func loadIfNeeded() {
        guard let path = item.previewPath, !path.isEmpty else {
            cached = nil; loadedPath = nil; return
        }
        guard path != loadedPath else { return }
        loadedPath = path
        if let img = PreviewGenerator.loadPreview(filename: path) {
            cached = img
        }
    }
}

/// Tuile d'aperçu qui charge l'UIImage UNE SEULE FOIS quand le
/// `previewPath` apparaît ou change. Sans cache local, l'image est
/// rechargée du disque à chaque re-render du parent (timer 100 ms qui
/// recharge `items`), ce qui provoque un clignotement visible.
private struct PreviewTile: View {
    let item: SharedItem
    @State private var cached: UIImage? = nil
    @State private var loadedPath: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let img = cached {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(320.0 / 200.0, contentMode: .fit)
                        // Zoom ×2 centré, idem RowThumbnail. Le
                        // `clipShape` plus bas recadre.
                        .scaleEffect(item.previewZoomed == true ? 2.0 : 1.0)
                } else {
                    Rectangle()
                        .fill(Color(.tertiarySystemFill))
                        .aspectRatio(320.0 / 200.0, contentMode: .fit)
                        .overlay { ProgressView() }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if item.previewLocked == true {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.previewZoomed == true {
                    Text("×2")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(6)
                }
            }
            Text(item.title ?? URL(string: item.url)?.lastPathComponent ?? item.url)
                .font(.caption2)
                .lineLimit(1)
                .foregroundColor(.primary)
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: item.previewPath) { _, _ in loadIfNeeded() }
    }

    private func loadIfNeeded() {
        guard let path = item.previewPath, !path.isEmpty else {
            cached = nil
            loadedPath = nil
            return
        }
        guard path != loadedPath else { return }
        loadedPath = path
        if let img = PreviewGenerator.loadPreview(filename: path) {
            cached = img
        }
    }
}

// MARK: - Widget reload coordinator (debounced, not @State)

/// Coalesce les appels `WidgetCenter.shared.reloadAllTimelines()` :
/// pendant un re-traitement IA on peut appeler `saveItems()` des
/// dizaines de fois par seconde, et chaque saveItems schedule un
/// reload. On garantit ici qu'il n'y a JAMAIS plus d'un reload en
/// attente. Implémenté comme classe singleton (pas un @State) → ne
/// déclenche aucun re-render SwiftUI.
final class WidgetReloadCoordinator {
    static let shared = WidgetReloadCoordinator()
    private var pending: Bool = false
    private let lock = NSLock()

    func schedule() {
        lock.lock()
        let already = pending
        pending = true
        lock.unlock()
        guard !already else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.pending = false
            self.lock.unlock()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

// MARK: - Stats panel view (isolated re-render)

/// Sous-vue dédiée au panneau de stats en bas de la sidebar. Possède
/// son propre @State et son propre timer 2 s pour la taille du
/// container. Comme c'est une struct SwiftUI séparée de ContentView,
/// les mutations de ses @State n'invalident QUE ce sous-arbre — la
/// toolbar de ContentView (donc ses Menus) reste stable.
/// Singleton ObservableObject mis à jour par `ContentView` à chaque
/// modification du nombre de tâches en vol. Observé UNIQUEMENT par
/// `StatsPanelView` → ses changements ne re-rendent pas la toolbar de
/// `ContentView` (donc pas de clignotement des Menus).
@MainActor
final class BackgroundTasksMonitor: ObservableObject {
    static let shared = BackgroundTasksMonitor()
    @Published var activeCount: Int = 0
    private init() {}
}

struct StatsPanelView: View {
    let appGroup: String
    /// Callbacks fournis par ContentView pour les menus contextuels
    /// déclenchés par un appui long sur les lignes. On passe par
    /// closures plutôt que par accès direct au state du parent : la
    /// StatsPanelView reste isolée et ses re-renders ne provoquent
    /// pas de re-render du ContentView.
    var onDeleteLocalData: () -> Void = {}
    var onResyncICloud: () -> Void = {}
    var onResetAICounters: () -> Void = {}

    @State private var appDataBytes: Int64 = 0
    @State private var appDataComputing: Bool = false
    @State private var statsTick: Int = 0
    /// Octets uploadés dans iCloud pour cette app — somme des
    /// binaires (`SharedFiles/`) et previews (`previews/`) des items
    /// dont le folder est marqué `iCloudSynced=true`. Approximation
    /// locale : CloudKit ne fournit pas d'API de quota par container.
    @State private var iCloudBytes: Int64 = 0
    /// Vrai s'il y a au moins un folder synchronisé localement.
    /// Conditionne l'affichage de la ligne iCloud.
    @State private var hasSyncedFolder: Bool = false
    @State private var iCloudComputing: Bool = false
    @ObservedObject private var tasks = BackgroundTasksMonitor.shared

    var body: some View {
        // `_ = statsTick` lit la valeur pour que la vue se rafraîchisse
        // quand on bumpe le tick (les compteurs IA sont dans
        // UserDefaults, pas dans @State).
        let _ = statsTick

        VStack(alignment: .leading, spacing: 10) {
            // Apparition/disparition smooth pilotée par
            // `.animation(value: hasTasks)` posée plus bas sur le
            // VStack racine. La `.transition` sur le HStack définit
            // ce que l'animation interpole (fade + glissement vers le
            // haut).
            if tasks.activeCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.2")
                        .foregroundColor(.purple)
                    Text("Background tasks")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(tasks.activeCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(tasks.activeCount)))
                        // Force SwiftUI à interpoler le changement de
                        // nombre via la `contentTransition` rolling-
                        // digits définie ci-dessus, même quand la valeur
                        // varie de quelques unités à la fois.
                        .animation(.easeInOut(duration: 0.4), value: tasks.activeCount)
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .move(edge: .top))
                ))
            }

            HStack(spacing: 8) {
                Image(systemName: "internaldrive")
                    .foregroundColor(.blue)
                Text("Local data")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(formatBytes(appDataBytes))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button(role: .destructive) {
                    onDeleteLocalData()
                } label: {
                    Label("Delete only local data", systemImage: "trash")
                }
            }
            if hasSyncedFolder {
                HStack(spacing: 8) {
                    Image(systemName: "icloud.fill")
                        .foregroundColor(.blue)
                    Text("iCloud")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text(formatBytes(iCloudBytes))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button {
                        onResyncICloud()
                    } label: {
                        Label("Resync iCloud", systemImage: "arrow.triangle.2.circlepath.icloud")
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .move(edge: .top))
                ))
            }

            let providers = AICounters.providersWithCalls()
            if !providers.isEmpty {
                Divider()
                    .transition(.opacity)
                ForEach(providers, id: \.self) { p in
                    let s = AICounters.read(provider: p)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundColor(.purple)
                            Text(AICounters.displayName(p))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            if let m = s.model, !m.isEmpty {
                                Text("(\(m))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        HStack {
                            Text("Requests")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(s.requests)")
                                .font(.caption2)
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(s.requests)))
                        }
                        HStack {
                            Text("Tokens in")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatTokens(s.tokensIn))
                                .font(.caption2)
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(s.tokensIn)))
                        }
                        HStack {
                            Text("Tokens out")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatTokens(s.tokensOut))
                                .font(.caption2)
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(s.tokensOut)))
                        }
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button(role: .destructive) {
                            onResetAICounters()
                        } label: {
                            Label("Reset AI counters", systemImage: "gauge.with.dots.needle.0percent")
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .animation(.easeInOut(duration: 0.5), value: providersSignature)
        .animation(.easeInOut(duration: 0.5), value: appDataBytes)
        .animation(.easeInOut(duration: 0.5), value: iCloudBytes)
        // Pilote l'apparition/disparition smooth des lignes
        // conditionnelles (« Background tasks », « iCloud »).
        .animation(.easeInOut(duration: 0.5), value: tasks.activeCount > 0)
        .animation(.easeInOut(duration: 0.5), value: hasSyncedFolder)
        .onAppear {
            recomputeAppDataBytes()
            recomputeICloudBytes()
        }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            recomputeAppDataBytes()
            recomputeICloudBytes()
            statsTick &+= 1
        }
    }

    private var providersSignature: String {
        AICounters.providersWithCalls().map { p in
            let s = AICounters.read(provider: p)
            return "\(p)|\(s.requests)|\(s.tokensIn)|\(s.tokensOut)|\(s.model ?? "")"
        }.joined(separator: ";")
    }

    private func recomputeAppDataBytes() {
        guard !appDataComputing else { return }
        appDataComputing = true
        let group = appGroup
        Task.detached(priority: .utility) {
            var total: Int64 = 0
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group) {
                total = directorySize(at: container)
            }
            await MainActor.run {
                appDataBytes = total
                appDataComputing = false
            }
        }
    }

    /// Calcule la taille uploadée dans iCloud pour cette app, en
    /// sommant les binaires (`SharedFiles/`) et les previews
    /// (`previews/`) des items dont le folder est marqué
    /// `iCloudSynced=true`. Pas d'API CloudKit pour le quota par
    /// container, donc on se base sur l'état local des items
    /// synchronisés — exact tant que les pushes ne sont pas
    /// en retard.
    private func recomputeICloudBytes() {
        guard !iCloudComputing else { return }
        iCloudComputing = true
        let group = appGroup
        Task.detached(priority: .utility) {
            var total: Int64 = 0
            var hasSynced = false
            if let d = UserDefaults(suiteName: group),
               let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group) {
                // 1. Identifier les folders synced.
                var syncedNames: Set<String> = []
                if let data = d.data(forKey: "folders"),
                   let arr = try? JSONDecoder().decode([Folder].self, from: data) {
                    for f in arr where f.iCloudSynced {
                        syncedNames.insert(f.name)
                    }
                }
                hasSynced = !syncedNames.isEmpty
                // 2. Pour chaque item dans un folder synced : binaire + preview.
                if hasSynced,
                   let data = d.data(forKey: "items"),
                   let items = try? JSONDecoder().decode([SharedItem].self, from: data) {
                    let previewsDir = container.appendingPathComponent("previews",
                                                                       isDirectory: true)
                    for item in items where syncedNames.contains(item.folder) {
                        // Binaire : `url` commence par `file://` pour
                        // les items kind file/photo/video/audio.
                        if let u = URL(string: item.url), u.isFileURL {
                            if let attr = try? FileManager.default.attributesOfItem(atPath: u.path),
                               let size = attr[.size] as? NSNumber {
                                total += size.int64Value
                            }
                        }
                        // Preview PNG.
                        if let p = item.previewPath, !p.isEmpty {
                            let url = previewsDir.appendingPathComponent(p)
                            if let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
                               let size = attr[.size] as? NSNumber {
                                total += size.int64Value
                            }
                        }
                    }
                }
            }
            let finalTotal = total
            let finalHasSynced = hasSynced
            await MainActor.run {
                iCloudBytes = finalTotal
                hasSyncedFolder = finalHasSynced
                iCloudComputing = false
            }
        }
    }

    private func formatBytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Spinning gear (busy indicator on item rows)

/// Petite roue dentée qui tourne en continu, posée à la place de
/// l'icône de type d'objet quand une opération asynchrone est en cours
/// pour la ligne (description IA, OCR, transcription audio, génération
/// d'aperçu, fetch de date URL ou reverse geocoding). Utilise un
/// `TimelineView(.animation)` qui ne fait re-rendre QUE la roue
/// elle-même — le reste de la liste reste inchangé.
struct SpinningGear: View {
    let color: Color
    @State private var rotating: Bool = false

    var body: some View {
        // Rotation pilotée par CoreAnimation : une seule mutation de
        // `rotating` (false → true) au montage, l'animation
        // `.repeatForever(autoreverses: false)` tourne ensuite hors de
        // SwiftUI → AUCUN re-render du parent (donc plus de
        // clignotement des Menus de la toolbar).
        Image(systemName: "gearshape.fill")
            .foregroundColor(color)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .animation(
                .linear(duration: 1.2).repeatForever(autoreverses: false),
                value: rotating
            )
            .onAppear { rotating = true }
    }
}

// MARK: - Blinking modifier (local, no global re-render)

extension View {
    /// Fait clignoter doucement le contenu (opacité 1.0 ↔ 0.35, période
    /// 1,2 s) sans déclencher de re-render du parent : utilise un
    /// `TimelineView` qui réévalue UNIQUEMENT son contenu à chaque tick.
    func blinking() -> some View {
        modifier(BlinkingModifier())
    }

    /// Variante conditionnelle : ne clignote que si `active` est vrai,
    /// sinon affichage stable à pleine opacité. Utilisé pour faire
    /// clignoter l'icône d'une ligne uniquement pendant qu'une tâche
    /// asynchrone tourne pour cet item.
    @ViewBuilder
    func blinking(if active: Bool) -> some View {
        if active {
            self.blinking()
        } else {
            self
        }
    }
}

private struct BlinkingModifier: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: 0.6)) { ctx in
            let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
            content.opacity(on ? 1.0 : 0.35)
        }
    }
}

/// Calcule récursivement la taille totale (octets) d'un dossier. Utilisé
/// pour afficher la taille des données de l'app dans le panneau latéral.
func directorySize(at url: URL) -> Int64 {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return 0 }
    var total: Int64 = 0
    for case let file as URL in enumerator {
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey,
                                                        .totalFileAllocatedSizeKey,
                                                        .fileSizeKey])
        guard values?.isRegularFile == true else { continue }
        if let allocated = values?.totalFileAllocatedSize {
            total += Int64(allocated)
        } else if let size = values?.fileSize {
            total += Int64(size)
        }
    }
    return total
}
