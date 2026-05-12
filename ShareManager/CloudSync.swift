import Foundation
import CloudKit
import UIKit

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
                log("accountStatus = available")
            case .noAccount:
                accountState = .unavailable
                log("accountStatus = noAccount (utilisateur non connecté à iCloud sur cet appareil)")
            case .restricted:
                accountState = .unavailable
                log("accountStatus = restricted (compte limité par parental controls / MDM)")
            case .couldNotDetermine:
                accountState = .unavailable
                log("accountStatus = couldNotDetermine (erreur transitoire de CloudKit)")
            case .temporarilyUnavailable:
                accountState = .unavailable
                log("accountStatus = temporarilyUnavailable (re-essaiera plus tard)")
            @unknown default:
                accountState = .unavailable
                log("accountStatus = inconnu (\(status.rawValue))")
            }
        } catch {
            accountState = .unavailable
            log("accountStatus failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Public API

    /// Active la sync pour un dossier : crée la zone si nécessaire,
    /// pousse le Folder record + tous ses items (avec assets), et
    /// installe la subscription de notifications.
    func startSync(folder: Folder, items: [SharedItem]) async {
        log("startSync(\(folder.name)) called, accountState=\(accountState)")
        await refreshAccountStatus()
        guard accountState == .available else {
            log("startSync(\(folder.name)) aborted: accountState=\(accountState)")
            return
        }
        do {
            log("startSync(\(folder.name)) ensuring zone…")
            try await ensureZone()
            let folderRecord = buildFolderRecord(folder)
            let itemRecords = items
                .filter { $0.folder == folder.name }
                .map { buildItemRecord($0, folderRecordID: folderRecord.recordID) }
            log("startSync(\(folder.name)) saving \(1 + itemRecords.count) records (1 folder + \(itemRecords.count) items)")
            try await saveRecords([folderRecord] + itemRecords)
            try await ensureSubscription()
            log("startSync(\(folder.name)) ✅ done")
        } catch {
            log("startSync(\(folder.name)) failed: \(error.localizedDescription) — \(error)")
        }
    }

    /// Désactive la sync : supprime du cloud le Folder record ET tous
    /// ses items en UNE SEULE opération atomique `CKModifyRecords`.
    /// Toutes les copies locales (sur tous les appareils) restent
    /// intactes — c'est `applyPulledChanges` côté receveur qui traite
    /// l'event `−Folder` comme un simple flip `iCloudSynced=false`.
    ///
    /// Pourquoi coalescer folder + items dans une seule opération
    /// plutôt que de compter sur le cascade-delete via `parent` :
    /// les change-tokens CloudKit peuvent en théorie scinder les
    /// deletions cascade en plusieurs notifications. Un autre device
    /// pollant entre les deux pourrait recevoir les item-deletions
    /// pendant que le folder est encore considéré `iCloudSynced=true`
    /// localement → suppression locale appliquée à tort. En les
    /// regroupant dans une seule `CKModifyRecords`, toutes les
    /// deletions arrivent ensemble dans le `fetchZoneChanges` du
    /// receveur, et `applyPulledChanges` traite le folder d'abord,
    /// ce qui protège les items via `localOnlyFolderNames`.
    func stopSync(folderName: String, itemIDs: [String]) async {
        guard accountState == .available else { return }
        let folderID = CKRecord.ID(recordName: folderName, zoneID: zoneID)
        let itemRecordIDs = itemIDs.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        let allToDelete = [folderID] + itemRecordIDs
        log("stopSync(\(folderName)) deleting \(allToDelete.count) records atomically (1 folder + \(itemIDs.count) items)")
        // Neutralise le `flushPush` debounced qui va suivre (déclenché
        // par le `saveFolders` du caller). Sans ça, flushPush voit
        // toujours `lastPushedItemHashes` peuplé pour ces items et
        // tente une seconde fois de les supprimer → erreurs « record
        // not found » et risque d'échec de invalidate-token.
        for id in itemIDs { lastPushedItemHashes.removeValue(forKey: id) }
        lastPushedFolderNames.remove(folderName)
        do {
            try await deleteRecords(allToDelete)
            // Invalide le token (même rationale que flushPush) : on
            // vient de modifier la zone, le prochain pull repart en
            // full refresh pour rester cohérent avec d'éventuels
            // changements concurrents d'un autre device.
            saveZoneChangeToken(nil)
            log("stopSync(\(folderName)) ✅ done — invalidating token")
        } catch {
            log("stopSync(\(folderName)) failed: \(error.localizedDescription)")
        }
    }

    /// Suppression *explicite* d'un folder synced — à utiliser quand
    /// l'utilisateur efface le folder localement (vs. `stopSync` qui
    /// se contente d'arrêter la sync). Propage la suppression aux
    /// autres appareils via un mécanisme de tombstone :
    ///
    ///   1. Annule un éventuel `flushPush` en attente (sinon son
    ///      diff enverrait des `−Folder`/`−Item` ordinaires *avant*
    ///      le tombstone, et les autres devices appliqueraient la
    ///      protection stopSync).
    ///   2. Nettoie le snapshot interne (`lastPushedItemHashes`,
    ///      `lastPushedFolderNames`) pour rendre tout `flushPush`
    ///      ultérieur idempotent.
    ///   3. Push un `Folder` record avec `tombstone=1` en
    ///      `savePolicy=.allKeys`. Les autres devices reçoivent cet
    ///      update dans `changedFolders` et hard-delete le folder
    ///      + ses items localement.
    ///   4. Delete atomique du folder + items côté cloud. CloudKit
    ///      garantit l'ordre serveur (update avant delete), donc
    ///      les events arriveront dans le bon ordre chez les
    ///      receveurs : tombstone d'abord, deletion ensuite (no-op
    ///      car le folder local est déjà parti).
    func deleteSyncedFolder(folderName: String, itemIDs: [String]) async {
        guard accountState == .available else { return }
        log("deleteSyncedFolder(\(folderName)) starting, \(itemIDs.count) items")

        // 1+2. Cancel pending flushPush + clean snapshot.
        pendingPushTask?.cancel()
        pendingPushTask = nil
        for id in itemIDs { lastPushedItemHashes.removeValue(forKey: id) }
        lastPushedFolderNames.remove(folderName)

        let folderID = CKRecord.ID(recordName: folderName, zoneID: zoneID)

        // 3. Tombstone push.
        let tomb = CKRecord(recordType: "Folder", recordID: folderID)
        tomb["name"] = folderName as CKRecordValue
        tomb["tombstone"] = 1 as CKRecordValue
        log("deleteSyncedFolder(\(folderName)) pushing tombstone update")
        do {
            try await saveRecordsForceOverwrite([tomb])
        } catch {
            log("deleteSyncedFolder(\(folderName)) tombstone push failed: \(error.localizedDescription)")
            // On continue : si le tombstone n'est pas passé, le
            // delete suivant retombera sur la sémantique stopSync
            // côté receveurs (folder conservé en local-only). Mieux
            // que de ne rien faire.
        }

        // 4. Delete atomique du folder + items.
        let allToDelete = [folderID] + itemIDs.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        log("deleteSyncedFolder(\(folderName)) deleting \(allToDelete.count) records (1 folder + \(itemIDs.count) items)")
        do {
            try await deleteRecords(allToDelete)
            saveZoneChangeToken(nil)
            log("deleteSyncedFolder(\(folderName)) ✅ done")
        } catch {
            log("deleteSyncedFolder(\(folderName)) delete failed: \(error.localizedDescription)")
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

    /// Reset complet de l'état CloudKit, pour repartir from-scratch
    /// pendant le développement. Effectue dans l'ordre :
    ///   1. Supprime la `CapturedZone` côté serveur → cascade-delete
    ///      de tous les records (Folders + Items + assets).
    ///   2. Efface tokens et drapeaux locaux (zone créée, subscription
    ///      créée, server-change-tokens).
    ///   3. Reset le snapshot mémoire utilisé par le diff push.
    /// Après ce reset, au prochain `startSync` la zone est recréée
    /// et un push complet repart de zéro.
    func resetState() async {
        await refreshAccountStatus()
        if accountState == .available {
            do {
                _ = try await privateDB.modifyRecordZones(saving: [], deleting: [zoneID])
                log("resetState: zone deleted server-side")
            } catch {
                log("resetState: zone delete failed: \(error.localizedDescription)")
            }
        }
        defaults?.removeObject(forKey: "cloudKitZoneCreated")
        defaults?.removeObject(forKey: "cloudKitSubscriptionCreated")
        defaults?.removeObject(forKey: "cloudKitZoneChangeToken")
        defaults?.removeObject(forKey: "cloudKitDBChangeToken")
        lastPushedItemHashes = [:]
        lastPushedFolderNames = []
        pendingPushTask?.cancel()
        pendingPushTask = nil
        log("resetState: ✅ local state cleared")
    }

    /// Réconcilie l'état local avec le cloud sans tout détruire,
    /// pour récupérer d'un bug ou d'une divergence (token mal
    /// positionné, push échoué, records orphelins, etc.).
    ///
    /// Algorithme (cf. plan « Resync iCloud ») :
    ///   1. Pre-checks : compte iCloud `.available`, zone + subscription
    ///      recréées si manquantes.
    ///   2. Reset du snapshot diff push en mémoire + invalidation du
    ///      `serverChangeToken` → le prochain fetch est forcément full.
    ///   3. Full fetch de la zone via `fetchZoneChanges` ; les Folder
    ///      + Item records cloud sont mergés localement (folders ajoutés
    ///      en `iCloudSynced=true`, items ajoutés/mis à jour, assets
    ///      binaires et previews téléchargés au passage).
    ///   4. Nettoyage des items orphelins côté cloud : tout Item dont
    ///      le `folder` field ne correspond à aucun Folder du cloud
    ///      est supprimé.
    ///   5. Re-push idempotent de tout le contenu des folders locaux
    ///      synchronisés, avec `savePolicy = .allKeys` pour écraser
    ///      brutalement les versions/timestamps cloud potentiellement
    ///      corrompus.
    ///   6. Token réinvalidé après le re-push.
    ///
    /// Conçu pour être déclenché manuellement par l'utilisateur via
    /// le menu `...`. Pas de garantie de durée ; pour 100 items
    /// + assets, compter quelques secondes ; au-delà, plusieurs
    /// dizaines de secondes.
    func resyncReconcile() async {
        log("resyncReconcile: starting")

        // Étape 1 : pre-checks.
        await refreshAccountStatus()
        guard accountState == .available else {
            log("resyncReconcile aborted: accountState=\(accountState)")
            return
        }
        do {
            try await ensureZone()
        } catch {
            log("resyncReconcile: ensureZone failed: \(error.localizedDescription)")
            return
        }
        try? await ensureSubscription()

        // Étape 2 : reset diff push + token.
        lastPushedItemHashes = [:]
        lastPushedFolderNames = []
        pendingPushTask?.cancel()
        pendingPushTask = nil
        saveZoneChangeToken(nil)
        log("resyncReconcile: state reset (snapshot + token)")

        // Étape 3 : full fetch + merge local. `applyToLocal=true` →
        // applyPulledChanges écrit dans UserDefaults App Group.
        let fetched: FetchedZoneChanges
        do {
            fetched = try await fetchZoneChanges(applyToLocal: true)
        } catch {
            log("resyncReconcile: fetchZoneChanges failed: \(error.localizedDescription)")
            return
        }
        log("resyncReconcile: cloud has \(fetched.changedFolders.count) folders, \(fetched.changedItems.count) items")

        // Étape 4 : cleanup orphelins (items dont le folder field n'est
        // associé à aucun Folder du cloud). Opération purement cloud.
        let cloudFolderNames = Set(fetched.changedFolders.map(\.name))
        let orphans = fetched.changedItems.filter { !cloudFolderNames.contains($0.folder) }
        if !orphans.isEmpty {
            log("resyncReconcile: deleting \(orphans.count) orphan items from cloud")
            for o in orphans {
                log("resyncReconcile: orphan ↓ Item \(o.id) folder=\"\(o.folder)\" (no matching Folder record)")
            }
            do {
                try await deleteRecords(orphans.map { CKRecord.ID(recordName: $0.id, zoneID: zoneID) })
            } catch {
                log("resyncReconcile: orphan delete failed: \(error.localizedDescription)")
                // Pas un blocage : on continue avec le re-push.
            }
        } else {
            log("resyncReconcile: no orphan items to clean up")
        }

        // Étape 5 : re-push idempotent du contenu local synchronisé,
        // avec `savePolicy = .allKeys` pour écraser brutalement.
        let (localFolders, localItems) = readLocalFoldersAndItems()
        let syncedFolders = localFolders.filter { $0.iCloudSynced }
        var recordsToSave: [CKRecord] = []
        var nextItemHashes: [String: Int] = [:]
        var nextFolderNames: Set<String> = []
        for f in syncedFolders {
            let fr = buildFolderRecord(f)
            recordsToSave.append(fr)
            nextFolderNames.insert(f.name)
            for item in localItems where item.folder == f.name {
                recordsToSave.append(buildItemRecord(item, folderRecordID: fr.recordID))
                nextItemHashes[item.id] = item.hashValue
            }
        }
        if !recordsToSave.isEmpty {
            log("resyncReconcile: force-pushing \(recordsToSave.count) records (\(syncedFolders.count) folders + \(nextItemHashes.count) items)")
            do {
                try await saveRecordsForceOverwrite(recordsToSave)
                lastPushedItemHashes = nextItemHashes
                lastPushedFolderNames = nextFolderNames
                log("resyncReconcile: force-push ✅ done")
            } catch {
                log("resyncReconcile: force-push failed: \(error.localizedDescription)")
            }
        } else {
            log("resyncReconcile: no local synced content to push")
        }

        // Étape 6 : invalide le token (cohérence avec le pattern
        // flushPush/stopSync — le prochain pull repart en full).
        saveZoneChangeToken(nil)

        log("resyncReconcile: ✅ done — folders=\(syncedFolders.count) items=\(nextItemHashes.count) orphans=\(orphans.count)")
    }

    /// Lit `folders` + `items` depuis l'App Group UserDefaults.
    /// Utilisé par `resyncReconcile` après l'application des changements
    /// cloud, pour décider quoi re-pousser.
    private nonisolated func readLocalFoldersAndItems() -> (folders: [Folder], items: [SharedItem]) {
        guard let d = UserDefaults(suiteName: appGroup) else { return ([], []) }
        var folders: [Folder] = []
        if let data = d.data(forKey: "folders"),
           let arr = try? JSONDecoder().decode([Folder].self, from: data) {
            folders = arr
        }
        var items: [SharedItem] = []
        if let data = d.data(forKey: "items"),
           let arr = try? JSONDecoder().decode([SharedItem].self, from: data) {
            items = arr
        }
        return (folders, items)
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
        guard accountState == .available else {
            log("flushPush aborted: accountState=\(accountState)")
            return
        }

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

        for r in recordsToSave {
            switch r.recordType {
            case "Folder":
                log("flushPush: ↑ Folder \"\(r.recordID.recordName)\"")
            case "Item":
                let folder = r["folder"] as? String ?? "?"
                let title = (r["title"] as? String) ?? (r["url"] as? String)?.prefix(60).description ?? "?"
                log("flushPush: ↑ Item \(r.recordID.recordName) folder=\"\(folder)\" title=\"\(title)\"")
            default: break
            }
        }
        for id in idsToDelete {
            log("flushPush: ↓ delete \(id.recordName)")
        }
        log("flushPush: \(recordsToSave.count) records to save, \(idsToDelete.count) to delete")
        do {
            try await ensureZone()
            if !recordsToSave.isEmpty { try await saveRecords(recordsToSave) }
            if !idsToDelete.isEmpty   { try await deleteRecords(idsToDelete) }
            try? await ensureSubscription()
            // Mise à jour du snapshot mémoire APRÈS succès — en cas
            // d'erreur on retentera au prochain snapshotChanged.
            lastPushedItemHashes = currentItemHashes
            lastPushedFolderNames = syncedFolderNames
            // Invalide le serverChangeToken : le prochain
            // fetchZoneChanges sera un full refresh (token=nil). Sinon
            // on observe en pratique des cas où, après un push, le
            // token avance côté client à une position d'où un record
            // pushé en parallèle par un autre device reste invisible
            // pour ce device — symptôme : iPad pousse son item, iPhone
            // pousse le sien ≈ en même temps, iPad ne voit jamais
            // l'item iPhone bien que le record soit confirmé présent
            // sur le serveur (cf. logs 2026-05-12).
            saveZoneChangeToken(nil)
            log("flushPush ✅ done — invalidating token for next pull")
        } catch {
            log("flushPush failed: \(error.localizedDescription)")
        }
    }

    /// Tire le delta côté serveur et applique localement (UserDefaults
    /// App Group + fichiers SharedFiles/, previews/).
    func pullChanges() async {
        log("pullChanges() called, accountState=\(accountState)")
        await refreshAccountStatus()
        guard accountState == .available else {
            log("pullChanges aborted: accountState=\(accountState)")
            return
        }
        do {
            log("pullChanges ensuring zone…")
            try await ensureZone()
            // S'assure aussi que la subscription existe sur CE device,
            // même s'il ne pousse jamais (cas pull-only). Sans ça,
            // l'appareil ne recevrait jamais de push silencieuses
            // quand un autre appareil modifie la base privée — la
            // sync ne dépendrait que du timer 10 s en foreground.
            try? await ensureSubscription()
            log("pullChanges fetching zone changes (token=\(savedZoneChangeToken() == nil ? "nil" : "present"))")
            try await fetchZoneChanges()
            log("pullChanges ✅ done")
        } catch {
            log("pullChanges failed: \(error.localizedDescription) — \(error)")
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
        if defaults?.bool(forKey: "cloudKitSubscriptionCreated") == true {
            return
        }
        log("ensureSubscription: creating CKDatabaseSubscription…")
        let sub = CKDatabaseSubscription(subscriptionID: "captured-private-db")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // push silencieuse
        sub.notificationInfo = info
        _ = try await privateDB.modifySubscriptions(saving: [sub], deleting: [])
        defaults?.set(true, forKey: "cloudKitSubscriptionCreated")
        log("ensureSubscription: ✅ created")
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
        if let v = item.previewZoomed  { r["previewZoomed"] = (v ? 1 : 0) as CKRecordValue }
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
            previewLocked: (r["previewLocked"] as? Int).map { $0 != 0 },
            previewZoomed: (r["previewZoomed"] as? Int).map { $0 != 0 }
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

    /// Variante de `saveRecords` qui écrase brutalement le serveur :
    /// `savePolicy = .allKeys` ignore les versions de records côté
    /// serveur et écrit tous les champs. Utilisé par `resyncReconcile`
    /// pour repartir d'un état propre quand l'utilisateur suspecte que
    /// les versions/timestamps cloud sont corrompus.
    private func saveRecordsForceOverwrite(_ records: [CKRecord]) async throws {
        let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        op.savePolicy = .allKeys
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

    /// Résultat d'un fetch de zone : les changements bruts reçus du
    /// serveur. `pullChanges` les applique localement immédiatement ;
    /// `resyncReconcile` en a besoin pour détecter les orphelins
    /// avant de les appliquer.
    struct FetchedZoneChanges {
        var changedFolders: [Folder]
        var changedItems: [SharedItem]
        var deletedFolderNames: [String]
        var deletedItemIDs: [String]
        /// Folders dont le record cloud contient `tombstone=1` : signal
        /// explicite émis par `deleteSyncedFolder` avant le delete
        /// proprement dit. Distingue une vraie suppression (à
        /// propager hard côté local) d'un simple `stopSync` (qui
        /// flippe juste `iCloudSynced=false`).
        var tombstonedFolderNames: [String]
    }

    @discardableResult
    private func fetchZoneChanges(applyToLocal: Bool = true) async throws -> FetchedZoneChanges {
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
        var tombstonedFolderNames: [String] = []

        op.recordWasChangedBlock = { recordID, result in
            switch result {
            case .success(let record):
                switch record.recordType {
                case "Item":
                    if let item = self.itemFromRecordSync(record) {
                        self.log("fetchZoneChanges: + Item \(item.id) folder=\"\(item.folder)\" title=\"\(item.title ?? item.url.prefix(60).description)\"")
                        changedItems.append(item)
                    }
                case "Folder":
                    if let name = record["name"] as? String {
                        if let tomb = record["tombstone"] as? Int, tomb != 0 {
                            self.log("fetchZoneChanges: 🪦 Tombstone Folder \"\(name)\"")
                            tombstonedFolderNames.append(name)
                        } else if let sortIndex = record["sortIndex"] as? Double {
                            self.log("fetchZoneChanges: + Folder \"\(name)\"")
                            changedFolders.append(Folder(name: name, iCloudSynced: true, sortIndex: sortIndex))
                        }
                    }
                default: break
                }
            case .failure(let err):
                self.log("fetchZoneChanges: record \(recordID.recordName) failed: \(err.localizedDescription)")
            }
        }
        op.recordWithIDWasDeletedBlock = { recordID, recordType in
            switch recordType {
            case "Item":
                self.log("fetchZoneChanges: − Item \(recordID.recordName)")
                deletedIDs.append(recordID.recordName)
            case "Folder":
                self.log("fetchZoneChanges: − Folder \"\(recordID.recordName)\"")
                deletedFolderNames.append(recordID.recordName)
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

        log("fetchZoneChanges: received changedItems=\(changedItems.count), deletedItemIDs=\(deletedIDs.count), changedFolders=\(changedFolders.count), deletedFolderNames=\(deletedFolderNames.count), tombstonedFolders=\(tombstonedFolderNames.count)")
        if applyToLocal {
            applyPulledChanges(changedItems: changedItems,
                               deletedItemIDs: deletedIDs,
                               changedFolders: changedFolders,
                               deletedFolderNames: deletedFolderNames,
                               tombstonedFolderNames: tombstonedFolderNames)
        }
        return FetchedZoneChanges(
            changedFolders: changedFolders,
            changedItems: changedItems,
            deletedFolderNames: deletedFolderNames,
            deletedItemIDs: deletedIDs,
            tombstonedFolderNames: tombstonedFolderNames
        )
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
            previewLocked: (r["previewLocked"] as? Int).map { $0 != 0 },
            previewZoomed: (r["previewZoomed"] as? Int).map { $0 != 0 }
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
    ///
    /// **Comportement « auto-rejoin » documenté** : si un folder du
    /// même nom existe déjà localement avec `iCloudSynced=false` (par
    /// ex. après un Stop iCloud sync, ou un folder créé localement
    /// avant qu'un autre appareil ne décide de partager un homonyme),
    /// recevoir un Folder record du cloud le **bascule automatiquement
    /// en synced**. L'appareil rejoint la sync sans intervention
    /// utilisateur ; ses items locaux dans ce folder seront ensuite
    /// pushés via `newlySyncedFolderNames` ci-dessous. C'est volontaire
    /// (simplicité + cohérence inter-appareils) — pour NE PAS rejoindre,
    /// l'utilisateur doit renommer son folder local avant qu'un autre
    /// appareil ne pousse un homonyme.
    private nonisolated func applyPulledChanges(changedItems: [SharedItem],
                                                deletedItemIDs: [String],
                                                changedFolders: [Folder],
                                                deletedFolderNames: [String],
                                                tombstonedFolderNames: [String] = []) {
        guard let d = UserDefaults(suiteName: appGroup) else { return }

        // ----- folders -----
        var folders: [Folder] = []
        if let data = d.data(forKey: "folders"),
           let arr = try? JSONDecoder().decode([Folder].self, from: data) {
            folders = arr
        }
        var items: [SharedItem] = []
        if let data = d.data(forKey: "items"),
           let arr = try? JSONDecoder().decode([SharedItem].self, from: data) {
            items = arr
        }

        // Tombstones : traités EN PREMIER. Hard-delete des folders +
        // items + fichiers/previews disque. Distingue ce cas du
        // `−Folder` ordinaire (qui suit la sémantique stopSync :
        // flip `iCloudSynced=false`, conservation locale).
        if !tombstonedFolderNames.isEmpty {
            let tombSet = Set(tombstonedFolderNames)
            let itemsToWipe = items.filter { tombSet.contains($0.folder) }
            for it in itemsToWipe {
                if let u = URL(string: it.url), u.isFileURL {
                    try? FileManager.default.removeItem(at: u)
                }
                if let path = it.previewPath, !path.isEmpty,
                   let container = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: appGroup) {
                    let prevURL = container
                        .appendingPathComponent("previews", isDirectory: true)
                        .appendingPathComponent(path)
                    try? FileManager.default.removeItem(at: prevURL)
                }
            }
            items.removeAll { tombSet.contains($0.folder) }
            folders.removeAll { tombSet.contains($0.name) }
            log("applyPulledChanges: hard-deleted \(tombSet.count) tombstoned folder(s) and their content")
        }
        // Détecte si un folder local passe de non-synced à synced via
        // ce pull. Dans ce cas, des items locaux pourraient déjà être
        // dedans côté local sans être encore connus du cloud → on
        // déclenchera un push après merge pour les pousser.
        var newlySyncedFolderNames: Set<String> = []
        for f in changedFolders {
            if let idx = folders.firstIndex(where: { $0.name == f.name }) {
                let wasUnsynced = !folders[idx].iCloudSynced
                folders[idx].sortIndex = f.sortIndex
                folders[idx].iCloudSynced = true
                if wasUnsynced { newlySyncedFolderNames.insert(f.name) }
            } else {
                folders.append(f)
            }
        }
        // Suppression de folder reçue du cloud : on ne supprime JAMAIS
        // le folder localement. Sémantique retenue : un « Stop iCloud
        // sync » fait sur un appareil détruit les records côté serveur
        // pour économiser le quota, mais TOUS les appareils du cluster
        // conservent leur copie locale (le folder est juste flippé en
        // `iCloudSynced=false`). C'est la promesse du modèle local-
        // first : la sync ne doit jamais supprimer de données chez un
        // utilisateur sans action explicite locale.
        //
        // Pour les folders déjà inconnus localement, l'event est
        // simplement ignoré (rien à conserver).
        var localOnlyFolderNames: Set<String> = Set(
            folders.filter { !$0.iCloudSynced }.map(\.name)
        )
        for name in deletedFolderNames {
            if let idx = folders.firstIndex(where: { $0.name == name }) {
                folders[idx].iCloudSynced = false
                localOnlyFolderNames.insert(name)
            }
        }
        if let data = try? JSONEncoder().encode(folders) {
            d.set(data, forKey: "folders")
        }

        // ----- items -----
        // `items` est déjà chargé en haut (avant le traitement des
        // tombstones, qui peut le modifier).
        // Items reçus du cloud SANS preview encore : on les inscrit
        // dans un "delay set" pour empêcher `triggerPendingPreviews`
        // de les régénérer localement pendant 30 s. Pendant ce
        // délai, on espère recevoir la version cloud (poussée par
        // l'autre appareil dès que sa propre génération est finie).
        // Items reçus AVEC preview : on retire l'id du delay set
        // s'il y était (preview cloud livrée, plus besoin d'attendre).
        var delaySet = (d.dictionary(forKey: "cloudPreviewWaitingItems") as? [String: Double]) ?? [:]
        let nowTS = Date().timeIntervalSince1970
        for it in changedItems {
            log("applyPulledChanges item: id=\(it.id) folder=\"\(it.folder)\" url=\"\(it.url.prefix(60))\" locked=\(it.previewLocked == true)")
            if let idx = items.firstIndex(where: { $0.id == it.id }) {
                // Règle de fusion :
                //   - Si l'item local était DÉJÀ verrouillé, on
                //     conserve son `previewPath` local. Le verrou
                //     signifie « ne touche pas à cet aperçu »,
                //     y compris quand une nouvelle version arrive
                //     du cloud. Tous les autres champs (titre,
                //     note, lock state, etc.) sont mis à jour
                //     normalement.
                //   - Sinon (non verrouillé), on applique l'item
                //     cloud tel quel — l'aperçu cloud écrase
                //     la locale.
                let localWasLocked = items[idx].previewLocked == true
                if localWasLocked {
                    var merged = it
                    merged.previewPath = items[idx].previewPath
                    items[idx] = merged
                } else {
                    items[idx] = it
                }
            } else {
                items.insert(it, at: 0)
            }
            // Le delay set ne s'applique qu'aux items NON verrouillés :
            // un item verrouillé reçu sans preview n'aura jamais sa
            // aperçu régénérée localement (cf. triggerPendingPreviews
            // qui skip les verrouillés).
            if it.previewLocked != true,
               (it.previewPath == nil || (it.previewPath ?? "").isEmpty) {
                delaySet[it.id] = nowTS
            } else {
                delaySet.removeValue(forKey: it.id)
            }
        }
        // Purge les entrées expirées (> 5 min) du delay set pour
        // éviter qu'il enfle indéfiniment.
        delaySet = delaySet.filter { nowTS - $0.value < 300 }
        d.set(delaySet, forKey: "cloudPreviewWaitingItems")
        let toDelete = Set(deletedItemIDs)
        if !toDelete.isEmpty {
            // Même garde que pour les folders : on ne supprime pas
            // localement les items dont le folder est devenu
            // local-only sur ce device. Les events de suppression
            // pour ces items sont l'écho de notre propre stopSync.
            items.removeAll { it in
                toDelete.contains(it.id) && !localOnlyFolderNames.contains(it.folder)
            }
        }
        if let data = try? JSONEncoder().encode(items) {
            d.set(data, forKey: "items")
            log("applyPulledChanges wrote \(items.count) items to App Group UserDefaults")
        }

        // Si au moins un folder local vient juste de passer en
        // synced grâce à ce pull, il peut contenir des items locaux
        // qui n'ont jamais été poussés (cas : l'utilisateur a créé
        // un folder du même nom sur 2 appareils avec des items
        // différents, puis a activé la sync sur un seul). On
        // déclenche immédiatement un push debounced pour propager
        // ces items vers iCloud.
        //
        // Subtilité : les items qu'on vient juste de RECEVOIR
        // (`changedItems`) sont déjà sur le serveur dans leur
        // version courante — pas la peine de les ré-uploader. On
        // seede donc `lastPushedItemHashes` avec leur hash post-
        // merge pour que `flushPush` les skip.
        if !newlySyncedFolderNames.isEmpty {
            log("applyPulledChanges: folder(s) newly synced \(newlySyncedFolderNames) — triggering push of local items")
            let receivedIds = Set(changedItems.map(\.id))
            let foldersSnap = folders
            let itemsSnap = items
            Task { [weak self] in
                guard let self else { return }
                await self.seedReceivedHashesAndPush(receivedIds: receivedIds,
                                                    folders: foldersSnap,
                                                    items: itemsSnap)
            }
        }
    }

    /// Seede `lastPushedItemHashes` avec le hash courant des items
    /// dont l'id figure dans `receivedIds` (= items qu'on vient juste
    /// de recevoir via pull et qui sont donc déjà à jour sur le
    /// serveur). Déclenche ensuite `snapshotChanged` qui calculera
    /// le delta et poussera uniquement les items LOCAUX (= ceux du
    /// folder nouvellement synced qui ne sont pas dans receivedIds).
    func seedReceivedHashesAndPush(receivedIds: Set<String>,
                                   folders: [Folder],
                                   items: [SharedItem]) {
        for it in items where receivedIds.contains(it.id) {
            lastPushedItemHashes[it.id] = it.hashValue
        }
        snapshotChanged(folders: folders, items: items)
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
        // Préfixe les lignes du timestamp local (HH:mm:ss.SSS) pour
        // mesurer les délais push/pull, et du nom de l'appareil
        // (iPhone / iPad par défaut sur iOS 16+ sans entitlement
        // user-assigned-device-name) pour distinguer les logs venant
        // des différents appareils dans une session de debug
        // multi-appareils.
        let ts = Self.timestampFormatter.string(from: Date())
        let line = "[CloudSync][\(ts)][\(UIDevice.current.name)] \(s)"
        // 1. Stdout — pour la console Xcode quand l'app est branchée
        //    en debug. Peut être perdu si Xcode déconnecte son stream
        //    (cas observé sur sessions multi-appareils longues).
        print(line)
        // 2. Fichier `extension_debug.log` du container App Group, si
        //    l'utilisateur a activé Debug Logs dans le menu …. Permet
        //    de relire les logs depuis l'app (menu … → View Logs) même
        //    quand Xcode a coupé son stream, ou quand l'iPhone tourne
        //    en standalone sans Xcode attaché.
        Self.appendToDebugFile(line)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func appendToDebugFile(_ line: String) {
        guard let d = UserDefaults(suiteName: "group.net.fenyo.apple.sharemanager"),
              d.bool(forKey: "debugLogsEnabled"),
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.net.fenyo.apple.sharemanager")
        else { return }
        let logFile = container.appendingPathComponent("extension_debug.log")
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFile, options: .atomic)
        }
    }
}
