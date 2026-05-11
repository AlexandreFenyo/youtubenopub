import Foundation
import CloudKit

/// Synchronisation iCloud par-dossier via CloudKit. Les dossiers
/// individuellement marqués `iCloudSynced` voient leur Folder record
/// + tous leurs Items (avec binaires en CKAsset et previews en
/// CKAsset) pushés vers la base privée du container
/// `iCloud.net.fenyo.apple.sharemanager`. Aucun trafic CloudKit n'est
/// déclenché tant qu'aucun dossier n'a été marqué synced.
///
/// Architecture :
///   - **Zone custom** `CapturedZone` dans la database privée. Permet
///     l'usage de `CKFetchRecordZoneChangesOperation` avec
///     `serverChangeToken` (la default zone ne supporte PAS les
///     change tokens, donc pas de sync delta efficace).
///   - **Tokens delta** persistés dans `UserDefaults` App Group :
///     `cloudKitDBChangeToken` (database-level) et un token par zone
///     (en pratique une seule). Permet de ne tirer que les
///     enregistrements modifiés depuis la dernière sync.
///   - **Subscription** `CKDatabaseSubscription` posée à la première
///     activation de sync sur un appareil : iOS pousse silencieusement
///     vers l'app, qui appelle `pullChanges()`.
///   - **Source de vérité locale** = `UserDefaults` App Group, comme
///     avant l'introduction d'iCloud. CloudSync lit/écrit le tableau
///     d'items JSON directement à cet endroit ; le ContentView le
///     recharge via son timer 100 ms. Pas de delegate ni de closure
///     vers l'UI.
actor CloudSync {

    static let shared = CloudSync()

    // MARK: - Configuration

    private let containerID = "iCloud.net.fenyo.apple.sharemanager"
    private let appGroup = "group.net.fenyo.apple.sharemanager"
    private let zoneName = "CapturedZone"

    private lazy var container: CKContainer = CKContainer(identifier: containerID)
    private lazy var privateDB: CKDatabase = container.privateCloudDatabase
    private lazy var zoneID: CKRecordZone.ID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    private init() {}

    // MARK: - Account state

    enum AccountState { case unknown, unavailable, available }
    private(set) var accountState: AccountState = .unknown

    /// À appeler au lancement de l'app. Met à jour `accountState`
    /// à partir du `CKAccountStatus`.
    func refreshAccountStatus() async {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                accountState = .available
            case .noAccount, .restricted, .couldNotDetermine, .temporarilyUnavailable:
                accountState = .unavailable
            @unknown default:
                accountState = .unavailable
            }
        } catch {
            accountState = .unavailable
        }
    }

    // MARK: - Public API

    /// Active la sync pour un dossier : crée la zone si nécessaire,
    /// pousse le Folder record + tous ses items (avec assets), et
    /// installe la subscription de notifications.
    func startSync(folder: Folder, items: [SharedItem]) async {
        await refreshAccountStatus()
        guard accountState == .available else { return }
        do {
            try await ensureZone()
            let folderRecord = buildFolderRecord(folder)
            let itemRecords = items
                .filter { $0.folder == folder.name }
                .map { buildItemRecord($0, folderRecordID: folderRecord.recordID) }
            try await saveRecords([folderRecord] + itemRecords)
            try await ensureSubscription()
        } catch {
            log("startSync failed: \(error.localizedDescription)")
        }
    }

    /// Désactive la sync : supprime du cloud le Folder record (cascade
    /// vers ses items via la `parent` reference côté Apple). Les
    /// copies locales restent intactes.
    func stopSync(folderName: String) async {
        guard accountState == .available else { return }
        let folderID = CKRecord.ID(recordName: folderName, zoneID: zoneID)
        do {
            try await deleteRecords([folderID])
        } catch {
            log("stopSync failed: \(error.localizedDescription)")
        }
    }

    /// Pousse un item modifié vers iCloud. Le caller doit avoir
    /// vérifié que le folder de l'item est marqué synced — c'est lui
    /// qui a accès à la liste des dossiers locale.
    func pushItem(_ item: SharedItem) async {
        guard accountState == .available else { return }
        let folderID = CKRecord.ID(recordName: item.folder, zoneID: zoneID)
        let record = buildItemRecord(item, folderRecordID: folderID)
        do {
            try await saveRecords([record])
        } catch {
            log("pushItem(\(item.id)) failed: \(error.localizedDescription)")
        }
    }

    /// Supprime un item du cloud (utilisé quand l'utilisateur efface
    /// localement OU déplace l'item vers un folder non-synced).
    func removeItem(id: String) async {
        guard accountState == .available else { return }
        let itemID = CKRecord.ID(recordName: id, zoneID: zoneID)
        do {
            try await deleteRecords([itemID])
        } catch {
            log("removeItem(\(id)) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Snapshot-based diff push (debounced)

    /// Snapshot mémoire du dernier état local pushé, pour calculer le
    /// delta à chaque mutation. Garde uniquement le strict nécessaire
    /// pour repérer un changement (id → hash).
    private var lastPushedItemHashes: [String: Int] = [:]
    private var lastPushedFolderNames: Set<String> = []
    private var pendingPushTask: Task<Void, Never>? = nil

    /// Appelé après chaque mutation côté UI (saveItems / saveFolders /
    /// startICloudSync / etc.). On capture l'état courant, et on
    /// programme un push debounced — annule + relance pour
    /// regrouper plusieurs saves rapprochées en un seul aller-retour
    /// CloudKit.
    func snapshotChanged(folders: [Folder], items: [SharedItem]) {
        pendingPushTask?.cancel()
        pendingPushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 s de fenêtre de coalescing
            guard let self else { return }
            if Task.isCancelled { return }
            await self.flushPush(folders: folders, items: items)
        }
    }

    /// Effectue le push réel : diff vs `lastPushed*`, construit un
    /// `CKModifyRecordsOperation` avec les records à mettre à jour et
    /// les ids à supprimer.
    private func flushPush(folders: [Folder], items: [SharedItem]) async {
        guard accountState == .available else { return }

        let syncedFolders = folders.filter { $0.iCloudSynced }
        let syncedFolderNames = Set(syncedFolders.map(\.name))

        // ----- Items à push / delete -----
        var recordsToSave: [CKRecord] = []
        var idsToDelete: [CKRecord.ID] = []

        var currentItemHashes: [String: Int] = [:]
        for item in items where syncedFolderNames.contains(item.folder) {
            let h = item.hashValue
            currentItemHashes[item.id] = h
            if lastPushedItemHashes[item.id] != h {
                let folderID = CKRecord.ID(recordName: item.folder, zoneID: zoneID)
                recordsToSave.append(buildItemRecord(item, folderRecordID: folderID))
            }
        }
        // Items précédemment pushés mais qui n'existent plus dans un
        // folder synced → delete côté cloud.
        for prevID in lastPushedItemHashes.keys where currentItemHashes[prevID] == nil {
            idsToDelete.append(CKRecord.ID(recordName: prevID, zoneID: zoneID))
        }

        // ----- Folders à push / delete -----
        for f in syncedFolders where !lastPushedFolderNames.contains(f.name) {
            recordsToSave.append(buildFolderRecord(f))
        }
        for prevName in lastPushedFolderNames where !syncedFolderNames.contains(prevName) {
            idsToDelete.append(CKRecord.ID(recordName: prevName, zoneID: zoneID))
        }

        guard !recordsToSave.isEmpty || !idsToDelete.isEmpty else { return }

        do {
            try await ensureZone()
            if !recordsToSave.isEmpty { try await saveRecords(recordsToSave) }
            if !idsToDelete.isEmpty   { try await deleteRecords(idsToDelete) }
            try? await ensureSubscription()
            // Mise à jour du snapshot mémoire APRÈS succès — en cas
            // d'erreur on retentera au prochain snapshotChanged.
            lastPushedItemHashes = currentItemHashes
            lastPushedFolderNames = syncedFolderNames
        } catch {
            log("flushPush failed: \(error.localizedDescription)")
        }
    }

    /// Tire le delta côté serveur et applique localement (UserDefaults
    /// App Group + fichiers SharedFiles/, previews/).
    func pullChanges() async {
        await refreshAccountStatus()
        guard accountState == .available else { return }
        do {
            try await ensureZone()
            try await fetchZoneChanges()
        } catch {
            log("pullChanges failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Zone

    /// S'assure que la zone custom existe. Idempotent : un drapeau
    /// persisté en `UserDefaults` évite l'appel `save(zone)` à chaque
    /// fois.
    private func ensureZone() async throws {
        if defaults?.bool(forKey: "cloudKitZoneCreated") == true { return }
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await privateDB.modifyRecordZones(saving: [zone], deleting: [])
        defaults?.set(true, forKey: "cloudKitZoneCreated")
    }

    // MARK: - Subscription

    /// Crée la `CKDatabaseSubscription` qui demande à iOS de nous
    /// notifier silencieusement à chaque modif sur la database. À
    /// faire une seule fois ; un drapeau persisté évite la re-création.
    private func ensureSubscription() async throws {
        if defaults?.bool(forKey: "cloudKitSubscriptionCreated") == true { return }
        let sub = CKDatabaseSubscription(subscriptionID: "captured-private-db")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // push silencieuse
        sub.notificationInfo = info
        _ = try await privateDB.modifySubscriptions(saving: [sub], deleting: [])
        defaults?.set(true, forKey: "cloudKitSubscriptionCreated")
    }

    // MARK: - Record building

    private func buildFolderRecord(_ folder: Folder) -> CKRecord {
        let id = CKRecord.ID(recordName: folder.name, zoneID: zoneID)
        let r = CKRecord(recordType: "Folder", recordID: id)
        r["name"] = folder.name as CKRecordValue
        r["sortIndex"] = folder.sortIndex as CKRecordValue
        r["createdAt"] = Date() as CKRecordValue
        return r
    }

    private func buildItemRecord(_ item: SharedItem, folderRecordID: CKRecord.ID) -> CKRecord {
        let id = CKRecord.ID(recordName: item.id, zoneID: zoneID)
        let r = CKRecord(recordType: "Item", recordID: id)
        r["url"] = item.url as CKRecordValue
        if let v = item.title          { r["title"] = v as CKRecordValue }
        if let v = item.sourceApp      { r["sourceApp"] = v as CKRecordValue }
        r["folder"] = item.folder as CKRecordValue
        r["timestamp"] = item.timestamp as CKRecordValue
        if let v = item.kind           { r["kind"] = v as CKRecordValue }
        if let v = item.modifiedAt     { r["modifiedAt"] = v as CKRecordValue }
        if let v = item.latitude       { r["latitude"] = v as CKRecordValue }
        if let v = item.longitude      { r["longitude"] = v as CKRecordValue }
        if let v = item.placeName      { r["placeName"] = v as CKRecordValue }
        if let v = item.aiDescribed    { r["aiDescribed"] = (v ? 1 : 0) as CKRecordValue }
        if let v = item.lastSeenModifiedAt { r["lastSeenModifiedAt"] = v as CKRecordValue }
        if let v = item.originalURL    { r["originalURL"] = v as CKRecordValue }
        if let v = item.note           { r["note"] = v as CKRecordValue }
        if let v = item.ocrDone        { r["ocrDone"] = (v ? 1 : 0) as CKRecordValue }
        if let v = item.previewPath    { r["previewPath"] = v as CKRecordValue }
        if let v = item.aiCallsCount   { r["aiCallsCount"] = v as CKRecordValue }
        if let v = item.translationDone { r["translationDone"] = (v ? 1 : 0) as CKRecordValue }
        if let v = item.ocrFailed      { r["ocrFailed"] = (v ? 1 : 0) as CKRecordValue }
        if let v = item.titleFetchFailed { r["titleFetchFailed"] = (v ? 1 : 0) as CKRecordValue }
        if let v = item.aiFailed       { r["aiFailed"] = (v ? 1 : 0) as CKRecordValue }
        if let v = item.previewLocked  { r["previewLocked"] = (v ? 1 : 0) as CKRecordValue }
        r["parent"] = CKRecord.Reference(recordID: folderRecordID, action: .deleteSelf)
        // Binaires : photos / files / videos / audios — `item.url`
        // pointe sur un file:// dans SharedFiles/. On joint le fichier
        // tel quel comme CKAsset (CloudKit stocke et chiffre).
        if let bin = binaryURL(for: item) {
            r["asset"] = CKAsset(fileURL: bin)
        }
        // Preview PNG s'il existe — stocké aussi en CKAsset pour que
        // le second appareil puisse l'afficher sans le régénérer.
        if let prev = previewURL(for: item) {
            r["previewAsset"] = CKAsset(fileURL: prev)
        }
        return r
    }

    private func itemFromRecord(_ r: CKRecord) -> SharedItem? {
        guard let url = r["url"] as? String,
              let folder = r["folder"] as? String,
              let timestamp = r["timestamp"] as? Double
        else { return nil }
        var item = SharedItem(
            id: r.recordID.recordName,
            url: url,
            title: r["title"] as? String,
            sourceApp: r["sourceApp"] as? String,
            folder: folder,
            timestamp: timestamp,
            kind: r["kind"] as? String,
            modifiedAt: r["modifiedAt"] as? Double,
            latitude: r["latitude"] as? Double,
            longitude: r["longitude"] as? Double,
            placeName: r["placeName"] as? String,
            aiDescribed: (r["aiDescribed"] as? Int).map { $0 != 0 },
            lastSeenModifiedAt: r["lastSeenModifiedAt"] as? Double,
            originalURL: r["originalURL"] as? String,
            note: r["note"] as? String,
            ocrDone: (r["ocrDone"] as? Int).map { $0 != 0 },
            previewPath: r["previewPath"] as? String,
            aiCallsCount: r["aiCallsCount"] as? Int,
            translationDone: (r["translationDone"] as? Int).map { $0 != 0 },
            ocrFailed: (r["ocrFailed"] as? Int).map { $0 != 0 },
            titleFetchFailed: (r["titleFetchFailed"] as? Int).map { $0 != 0 },
            aiFailed: (r["aiFailed"] as? Int).map { $0 != 0 },
            previewLocked: (r["previewLocked"] as? Int).map { $0 != 0 }
        )
        // Rapatrie les assets vers SharedFiles/ et previews/ ; remplace
        // url et previewPath par les chemins locaux résultants.
        if let asset = r["asset"] as? CKAsset, let src = asset.fileURL,
           let dst = importBinary(from: src, originalURL: url) {
            item.url = dst.absoluteString
        }
        if let prev = r["previewAsset"] as? CKAsset, let src = prev.fileURL,
           let dst = importPreview(from: src, id: item.id) {
            item.previewPath = dst.lastPathComponent
        }
        return item
    }

    // MARK: - Local file management

    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }
    private var sharedFilesDir: URL? {
        guard let c = containerURL else { return nil }
        let d = c.appendingPathComponent("SharedFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var previewsDir: URL? {
        guard let c = containerURL else { return nil }
        let d = c.appendingPathComponent("previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func binaryURL(for item: SharedItem) -> URL? {
        // Item dont la `url` est un file:// dans le container App Group.
        guard let u = URL(string: item.url), u.isFileURL,
              FileManager.default.fileExists(atPath: u.path)
        else { return nil }
        return u
    }

    private func previewURL(for item: SharedItem) -> URL? {
        guard let path = item.previewPath, !path.isEmpty,
              let dir = previewsDir
        else { return nil }
        let url = dir.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copie un binaire reçu via CKAsset vers `SharedFiles/`. Nom de
    /// fichier dérivé de l'URL source pour préserver l'extension.
    private func importBinary(from src: URL, originalURL: String) -> URL? {
        guard let dir = sharedFilesDir else { return nil }
        let suggested = URL(string: originalURL)?.lastPathComponent ?? src.lastPathComponent
        let dst = dir.appendingPathComponent(suggested)
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            return dst
        } catch {
            log("importBinary copy failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func importPreview(from src: URL, id: String) -> URL? {
        guard let dir = previewsDir else { return nil }
        let dst = dir.appendingPathComponent("\(id).png")
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            return dst
        } catch {
            log("importPreview copy failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Push primitives

    private func saveRecords(_ records: [CKRecord]) async throws {
        let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        op.savePolicy = .changedKeys
        op.qualityOfService = .utility
        try await runModifyOp(op)
    }

    private func deleteRecords(_ ids: [CKRecord.ID]) async throws {
        let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: ids)
        op.qualityOfService = .utility
        try await runModifyOp(op)
    }

    private func runModifyOp(_ op: CKModifyRecordsOperation) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let err): cont.resume(throwing: err)
                }
            }
            privateDB.add(op)
        }
    }

    // MARK: - Pull primitives

    private func fetchZoneChanges() async throws {
        let token = savedZoneChangeToken()
        var config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = token
        let op = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: config]
        )
        op.qualityOfService = .utility
        op.fetchAllChanges = true

        // Buffers pour appliquer les changements en bloc à la fin.
        var changedItems: [SharedItem] = []
        var deletedIDs: [String] = []
        var changedFolders: [Folder] = []
        var deletedFolderNames: [String] = []

        op.recordWasChangedBlock = { _, result in
            switch result {
            case .success(let record):
                switch record.recordType {
                case "Item":
                    if let item = self.itemFromRecordSync(record) {
                        changedItems.append(item)
                    }
                case "Folder":
                    if let name = record["name"] as? String,
                       let sortIndex = record["sortIndex"] as? Double {
                        changedFolders.append(Folder(name: name, iCloudSynced: true, sortIndex: sortIndex))
                    }
                default: break
                }
            case .failure: break
            }
        }
        op.recordWithIDWasDeletedBlock = { recordID, recordType in
            switch recordType {
            case "Item": deletedIDs.append(recordID.recordName)
            case "Folder": deletedFolderNames.append(recordID.recordName)
            default: break
            }
        }
        op.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
            self.saveZoneChangeToken(token)
        }
        op.recordZoneFetchResultBlock = { _, result in
            if case .success(let (token, _, _)) = result {
                self.saveZoneChangeToken(token)
            }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let err): cont.resume(throwing: err)
                }
            }
            privateDB.add(op)
        }

        applyPulledChanges(changedItems: changedItems,
                           deletedItemIDs: deletedIDs,
                           changedFolders: changedFolders,
                           deletedFolderNames: deletedFolderNames)
    }

    /// Variante sync du décodage (les callbacks de CKOp ne sont pas
    /// async). Le téléchargement des assets s'est déjà fait côté
    /// CloudKit (les `CKAsset.fileURL` pointent vers le cache local).
    private nonisolated func itemFromRecordSync(_ r: CKRecord) -> SharedItem? {
        guard let url = r["url"] as? String,
              let folder = r["folder"] as? String,
              let timestamp = r["timestamp"] as? Double
        else { return nil }
        var item = SharedItem(
            id: r.recordID.recordName,
            url: url,
            title: r["title"] as? String,
            sourceApp: r["sourceApp"] as? String,
            folder: folder,
            timestamp: timestamp,
            kind: r["kind"] as? String,
            modifiedAt: r["modifiedAt"] as? Double,
            latitude: r["latitude"] as? Double,
            longitude: r["longitude"] as? Double,
            placeName: r["placeName"] as? String,
            aiDescribed: (r["aiDescribed"] as? Int).map { $0 != 0 },
            lastSeenModifiedAt: r["lastSeenModifiedAt"] as? Double,
            originalURL: r["originalURL"] as? String,
            note: r["note"] as? String,
            ocrDone: (r["ocrDone"] as? Int).map { $0 != 0 },
            previewPath: r["previewPath"] as? String,
            aiCallsCount: r["aiCallsCount"] as? Int,
            translationDone: (r["translationDone"] as? Int).map { $0 != 0 },
            ocrFailed: (r["ocrFailed"] as? Int).map { $0 != 0 },
            titleFetchFailed: (r["titleFetchFailed"] as? Int).map { $0 != 0 },
            aiFailed: (r["aiFailed"] as? Int).map { $0 != 0 },
            previewLocked: (r["previewLocked"] as? Int).map { $0 != 0 }
        )
        if let asset = r["asset"] as? CKAsset, let src = asset.fileURL,
           let dst = importBinarySync(from: src, originalURL: url) {
            item.url = dst.absoluteString
        }
        if let prev = r["previewAsset"] as? CKAsset, let src = prev.fileURL,
           let dst = importPreviewSync(from: src, id: item.id) {
            item.previewPath = dst.lastPathComponent
        }
        return item
    }

    private nonisolated func importBinarySync(from src: URL, originalURL: String) -> URL? {
        guard let c = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { return nil }
        let dir = c.appendingPathComponent("SharedFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suggested = URL(string: originalURL)?.lastPathComponent ?? src.lastPathComponent
        let dst = dir.appendingPathComponent(suggested)
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            return dst
        } catch { return nil }
    }
    private nonisolated func importPreviewSync(from src: URL, id: String) -> URL? {
        guard let c = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { return nil }
        let dir = c.appendingPathComponent("previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("\(id).png")
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            return dst
        } catch { return nil }
    }

    // MARK: - Local merge

    /// Applique le résultat d'un pull aux UserDefaults App Group :
    ///   - folders : merge par nom, ajout des nouveaux marqués
    ///     `iCloudSynced = true` ; suppression de ceux deletes côté
    ///     cloud (cascade locale pas faite ici — les items resteront
    ///     orphelins jusqu'au prochain pull du delete d'item).
    ///   - items : insertion/maj par id, retrait des ids supprimés.
    /// Le ContentView recharge à son prochain tick et reflète l'état.
    private nonisolated func applyPulledChanges(changedItems: [SharedItem],
                                                deletedItemIDs: [String],
                                                changedFolders: [Folder],
                                                deletedFolderNames: [String]) {
        guard let d = UserDefaults(suiteName: appGroup) else { return }

        // ----- folders -----
        var folders: [Folder] = []
        if let data = d.data(forKey: "folders"),
           let arr = try? JSONDecoder().decode([Folder].self, from: data) {
            folders = arr
        }
        for f in changedFolders {
            if let idx = folders.firstIndex(where: { $0.name == f.name }) {
                folders[idx].sortIndex = f.sortIndex
                folders[idx].iCloudSynced = true
            } else {
                folders.append(f)
            }
        }
        for name in deletedFolderNames {
            folders.removeAll { $0.name == name }
        }
        if let data = try? JSONEncoder().encode(folders) {
            d.set(data, forKey: "folders")
        }

        // ----- items -----
        var items: [SharedItem] = []
        if let data = d.data(forKey: "items"),
           let arr = try? JSONDecoder().decode([SharedItem].self, from: data) {
            items = arr
        }
        for it in changedItems {
            if let idx = items.firstIndex(where: { $0.id == it.id }) {
                items[idx] = it
            } else {
                items.insert(it, at: 0)
            }
        }
        let toDelete = Set(deletedItemIDs)
        if !toDelete.isEmpty {
            items.removeAll { toDelete.contains($0.id) }
        }
        if let data = try? JSONEncoder().encode(items) {
            d.set(data, forKey: "items")
        }
    }

    // MARK: - Tokens persistence

    private var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    private nonisolated func savedZoneChangeToken() -> CKServerChangeToken? {
        guard let d = UserDefaults(suiteName: appGroup),
              let data = d.data(forKey: "cloudKitZoneChangeToken")
        else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
    private nonisolated func saveZoneChangeToken(_ token: CKServerChangeToken?) {
        guard let d = UserDefaults(suiteName: appGroup) else { return }
        guard let token else {
            d.removeObject(forKey: "cloudKitZoneChangeToken")
            return
        }
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            d.set(data, forKey: "cloudKitZoneChangeToken")
        }
    }

    // MARK: - Logging

    private nonisolated func log(_ s: String) {
        // Coupé du système de debug logs de la share extension :
        // CloudSync log uniquement sur la console Xcode (`os_log` pour
        // que ça apparaisse aussi dans Console.app sur Mac).
        print("[CloudSync] \(s)")
    }
}
