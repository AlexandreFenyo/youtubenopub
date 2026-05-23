import Foundation
import CloudKit
import UIKit
import CryptoKit

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

    /// Verrou partagé sérialisant TOUS les read-modify-write des clés
    /// `items` / `folders` de l'App Group, entre l'UI
    /// (`ContentView.saveItems` / `saveFolders`, thread principal) et
    /// CloudSync (`mergeChangedFoldersItems` / `applyDeletionsAndTombstones`,
    /// queue CloudKit). Sans lui, l'écriture aveugle de l'UI pouvait
    /// écraser des items que le merge venait d'ajouter pendant un pull →
    /// items perdus des métadonnées + fichiers binaires orphelins (bug
    /// observé en déplaçant des objets pendant qu'une sync écrivait).
    /// Couvre l'intra-process ; l'extension de partage est un autre
    /// process (non couvert, mais ne tourne pas en concurrence avec les
    /// pulls de l'app).
    static let storeLock = NSLock()

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
            let scopedItems = items.filter { $0.folder == folder.name }
            let itemRecords = scopedItems.map { buildItemRecord($0, folderRecordID: folderRecord.recordID) }
            // Mesure la taille totale (binaires + previews) que la
            // CKModifyRecordsOperation devra uploader. CKModifyRecords
            // a une limite implicite côté serveur (≈ 50 Mo / 400
            // records) ; en cas de dépassement on observe des erreurs
            // partielFailure / requestSizeTooLarge ou des timeouts
            // silencieux. Logguer le payload est essentiel pour
            // diagnostiquer ce cas (>30 photos/vidéos en une fois).
            let totalBytes = startSyncPayloadBytes(items: scopedItems)
            let totalMB = Double(totalBytes) / (1024 * 1024)
            log(String(format: "startSync(\(folder.name)) saving %d records (1 folder + %d items), payload ≈ %.2f MB",
                       1 + itemRecords.count, itemRecords.count, totalMB))
            // Push progressif (per-record) : décrémente le badge ↑ à
            // l'unité au fil de l'envoi, comme flushPush. Baseline = le
            // compteur ↑ courant (posé par le snapshotChanged de
            // l'activation, inclut d'éventuels autres items en attente),
            // au moins le nombre d'items de ce dossier.
            let pendingItemIDs = Set(itemRecords.map { $0.recordID.recordName })
            let baseline = max(defaults?.integer(forKey: Self.pendingUploadKey) ?? 0,
                               pendingItemIDs.count)
            let progressLock = NSLock()
            var savedCount = 0
            try await saveRecords([folderRecord] + itemRecords) { savedID in
                guard pendingItemIDs.contains(savedID.recordName) else { return }
                progressLock.lock()
                savedCount += 1
                let remaining = max(0, baseline - savedCount)
                progressLock.unlock()
                self.writeUploadCount(remaining)
            }
            try await ensureSubscription()
            // Persiste les signatures stables des items de ce folder
            // (reprise inter-redémarrage) + seede le snapshot mémoire
            // pour ces items, afin que le diff push de la session ne
            // les re-pousse pas.
            var sigs = loadPushedSignatures()
            for item in scopedItems {
                sigs[item.id] = itemSignature(item)
                lastPushedItemHashes[item.id] = item.hashValue
            }
            savePushedSignatures(sigs)
            lastPushedFolderNames.insert(folder.name)
            // Recale le badge ↑ d'après l'état local complet (ces items
            // sont désormais sur le serveur). Sans ça, le ↑N posé par le
            // snapshotChanged de l'activation resterait figé (le flushPush
            // debouncé suivant sort en no-op avant d'écrire le compteur).
            let (lf, li) = readLocalFoldersAndItems()
            writeUploadCount(localPendingUploadCount(folders: lf, items: li))
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
        defaults?.removeObject(forKey: Self.pushedSignaturesKey)
        defaults?.removeObject(forKey: Self.pendingUploadKey)
        defaults?.removeObject(forKey: Self.pendingDownloadKey)
        defaults?.removeObject(forKey: Self.noAutoDescribeKey)
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
        var nextSignatures: [String: String] = [:]
        for f in syncedFolders {
            let fr = buildFolderRecord(f)
            recordsToSave.append(fr)
            nextFolderNames.insert(f.name)
            for item in localItems where item.folder == f.name {
                recordsToSave.append(buildItemRecord(item, folderRecordID: fr.recordID))
                nextItemHashes[item.id] = item.hashValue
                nextSignatures[item.id] = itemSignature(item)
            }
        }
        if !recordsToSave.isEmpty {
            log("resyncReconcile: force-pushing \(recordsToSave.count) records (\(syncedFolders.count) folders + \(nextItemHashes.count) items)")
            do {
                try await saveRecordsForceOverwrite(recordsToSave)
                lastPushedItemHashes = nextItemHashes
                lastPushedFolderNames = nextFolderNames
                savePushedSignatures(nextSignatures)
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
        // Met à jour IMMÉDIATEMENT le compteur « à envoyer » (calcul
        // local, sans réseau) pour que le badge ↑N apparaisse dès la
        // mutation — avant même le push debouncé et sans dépendre de la
        // sonde réseau (qui pourrait rater une opération rapide).
        writeUploadCount(localPendingUploadCount(folders: folders, items: items))
        pendingPushTask?.cancel()
        pendingPushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 s de fenêtre de coalescing
            guard let self else { return }
            if Task.isCancelled { return }
            await self.flushPush(folders: folders, items: items)
        }
    }

    /// Nombre d'items « à envoyer » d'après le snapshot mémoire
    /// (instantané, sans réseau) : items des folders synced dont le
    /// hash diffère du dernier état pushé. Source de vérité du badge
    /// ↑N (l'envoi est intrinsèquement local à cet appareil — lui seul
    /// sait ce qu'il n'a pas encore poussé).
    private func localPendingUploadCount(folders: [Folder], items: [SharedItem]) -> Int {
        let syncedNames = Set(folders.filter { $0.iCloudSynced }.map(\.name))
        var n = 0
        for item in items where syncedNames.contains(item.folder) {
            if lastPushedItemHashes[item.id] != item.hashValue { n += 1 }
        }
        return n
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

        guard !recordsToSave.isEmpty || !idsToDelete.isEmpty else {
            // Rien à pousser/supprimer : l'état local est déjà aligné
            // sur le snapshot → plus rien « à envoyer ». On recale le
            // badge ↑ (typiquement à 0) avant de sortir.
            writeUploadCount(localPendingUploadCount(folders: folders, items: items))
            return
        }

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
            if !recordsToSave.isEmpty {
                // Push en UNE opération (efficace), mais avec suivi de
                // progression à l'unité : CloudKit appelle
                // `perRecordSaveBlock` au fil des records écrits côté
                // serveur → on décrémente le badge ↑ record par record
                // au lieu de sauter de N à 0 à la fin.
                let pendingItemIDs = Set(
                    recordsToSave.filter { $0.recordType == "Item" }.map { $0.recordID.recordName }
                )
                let totalPending = pendingItemIDs.count
                let progressLock = NSLock()
                var savedCount = 0
                try await saveRecords(recordsToSave) { savedID in
                    guard pendingItemIDs.contains(savedID.recordName) else { return }
                    progressLock.lock()
                    savedCount += 1
                    let remaining = max(0, totalPending - savedCount)
                    progressLock.unlock()
                    self.writeUploadCount(remaining)
                }
            }
            if !idsToDelete.isEmpty   { try await deleteRecords(idsToDelete) }
            try? await ensureSubscription()
            // Mise à jour du snapshot mémoire APRÈS succès — en cas
            // d'erreur on retentera au prochain snapshotChanged.
            lastPushedItemHashes = currentItemHashes
            lastPushedFolderNames = syncedFolderNames
            // Le push est confirmé → plus rien à envoyer pour ces
            // items : on recale le badge ↑ (0) sans attendre la sonde.
            writeUploadCount(localPendingUploadCount(folders: folders, items: items))
            // Persiste les signatures stables (pour la reprise inter-
            // redémarrage). Après un flushPush réussi, TOUS les items
            // des folders synced sont sur le serveur (les inchangés y
            // étaient déjà), donc on reconstruit la map complète —
            // ce qui auto-prune les entrées des items supprimés.
            var sigs: [String: String] = [:]
            for item in items where syncedFolderNames.contains(item.folder) {
                sigs[item.id] = itemSignature(item)
            }
            savePushedSignatures(sigs)
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
            await refreshTransferCounts()
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
            await refreshTransferCounts()
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
        if defaults?.bool(forKey: "cloudKitZoneCreated") == true {
            log("ensureZone: skipped (flag cloudKitZoneCreated=true)")
            return
        }
        log("ensureZone: creating zone \"\(zoneName)\"…")
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await privateDB.modifyRecordZones(saving: [zone], deleting: [])
        defaults?.set(true, forKey: "cloudKitZoneCreated")
        log("ensureZone: ✅ zone created and flag persisted")
    }

    // MARK: - Subscription

    /// Crée la `CKDatabaseSubscription` qui demande à iOS de nous
    /// notifier silencieusement à chaque modif sur la database. À
    /// faire une seule fois ; un drapeau persisté évite la re-création.
    private func ensureSubscription() async throws {
        if defaults?.bool(forKey: "cloudKitSubscriptionCreated") == true {
            log("ensureSubscription: skipped (flag cloudKitSubscriptionCreated=true)")
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

    /// Comme `saveRecords`, mais notifie `perRecordSaved` pour CHAQUE
    /// record effectivement écrit côté serveur, via le
    /// `perRecordSaveBlock` de CloudKit. Permet un suivi de progression
    /// à l'unité pendant un gros push (le badge ↑ décroît record par
    /// record au lieu de sauter à 0 d'un coup). La closure s'exécute sur
    /// la queue interne de l'opération (hors acteur) → elle doit être
    /// thread-safe.
    private func saveRecords(_ records: [CKRecord],
                             perRecordSaved: @escaping (CKRecord.ID) -> Void) async throws {
        let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        op.savePolicy = .changedKeys
        op.qualityOfService = .utility
        op.perRecordSaveBlock = { recordID, result in
            if case .success = result { perRecordSaved(recordID) }
        }
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
        // Pré-calcule le compteur ↓ AVANT le téléchargement lourd, pour
        // que le badge soit visible pendant toute la durée du pull. Sans
        // ça, sur un pull rapide, la sonde périodique (4 s) peut rater la
        // fenêtre où serveur > local, et le refresh de FIN de pull
        // calcule 0 (tout est déjà appliqué) → la flèche n'apparaît
        // jamais. Le merge décrémente ensuite ce compteur au fil des
        // items reçus (palier 1).
        if applyToLocal {
            await recomputeDownloadCount()
        }
        let token = savedZoneChangeToken()
        var config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = token
        let op = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: config]
        )
        op.qualityOfService = .utility
        op.fetchAllChanges = true

        // Buffers conservés intégralement pour la valeur de retour
        // (utilisée par resyncReconcile pour la détection d'orphelins).
        var changedItems: [SharedItem] = []
        var deletedIDs: [String] = []
        var changedFolders: [Folder] = []
        var deletedFolderNames: [String] = []
        var tombstonedFolderNames: [String] = []

        // --- Apply progressif (uniquement si applyToLocal) ---
        // On applique les items reçus PAR LOTS pendant le pull (au lieu
        // d'un seul bloc en fin), pour que les objets apparaissent au
        // fil de l'eau et que le badge ↓ décroisse (la sonde compare
        // serveur ↔ local, ce dernier avançant à chaque lot). Les
        // suppressions/tombstones restent appliquées en fin de pull.
        var pendingItems: [SharedItem] = []
        var newlySyncedAccum: Set<String> = []
        // Palier de 1 : chaque item reçu est appliqué immédiatement →
        // les objets apparaissent un par un et le badge ↓ décroît de 1
        // en 1. Coût : une réécriture du tableau d'items complet dans
        // l'App Group par item reçu (acceptable aux volumes visés).
        let flushThreshold = 1

        op.recordWasChangedBlock = { recordID, result in
            switch result {
            case .success(let record):
                switch record.recordType {
                case "Item":
                    if let item = self.itemFromRecordSync(record) {
                        self.log("fetchZoneChanges: + Item \(item.id) folder=\"\(item.folder)\" title=\"\(item.title ?? item.url.prefix(60).description)\"")
                        changedItems.append(item)
                        if applyToLocal {
                            pendingItems.append(item)
                            if pendingItems.count >= flushThreshold {
                                let ns = self.mergeChangedFoldersItems(
                                    changedFolders: changedFolders,
                                    changedItems: pendingItems)
                                newlySyncedAccum.formUnion(ns)
                                pendingItems.removeAll(keepingCapacity: true)
                            }
                        }
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
        // Token capturé en local et NON persisté pendant l'opération.
        // CloudKit peut émettre des checkpoints de token intermédiaires
        // (`recordZoneChangeTokensUpdatedBlock`) pendant un gros fetch
        // multi-lots. Si on les persistait au fil de l'eau et que l'app
        // était tuée AVANT `applyPulledChanges` (qui n'applique qu'à la
        // toute fin, en bloc), le token aurait avancé au-delà de records
        // bufferisés jamais appliqués localement → objets définitivement
        // sautés au redémarrage. On ne persiste donc le token qu'APRÈS
        // application locale réussie (cf. plus bas).
        var pendingFinalToken: CKServerChangeToken? = nil
        op.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
            pendingFinalToken = token
        }
        op.recordZoneFetchResultBlock = { _, result in
            if case .success(let (token, _, _)) = result {
                pendingFinalToken = token
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
            // 1. Fusion finale : reliquat d'items non encore flushés +
            //    TOUS les folders (réappliqués, idempotent — garantit
            //    qu'un folder arrivé après ses items est bien présent).
            if !pendingItems.isEmpty || !changedFolders.isEmpty {
                let ns = mergeChangedFoldersItems(changedFolders: changedFolders,
                                                  changedItems: pendingItems)
                newlySyncedAccum.formUnion(ns)
            }
            // 2. Suppressions / tombstones : appliquées en bloc à la fin,
            //    après toutes les fusions (préserve l'ordre et la garde
            //    local-only).
            applyDeletionsAndTombstones(deletedItemIDs: deletedIDs,
                                        deletedFolderNames: deletedFolderNames,
                                        tombstonedFolderNames: tombstonedFolderNames)
            // 3. Push des items locaux des folders nouvellement synced.
            triggerNewlySyncedPush(receivedIds: Set(changedItems.map(\.id)),
                                   newlySynced: newlySyncedAccum)
            // 4. Persiste le token SEULEMENT maintenant : tout est écrit
            //    dans l'App Group. Un kill avant ce point fait simplement
            //    re-fetcher le même delta au prochain pull (idempotent).
            if let pendingFinalToken {
                saveZoneChangeToken(pendingFinalToken)
            }
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
    /// Fusionne (upsert) les **changements** reçus — folders + items —
    /// dans les métadonnées locales. **Ne traite PAS** les suppressions
    /// ni les tombstones (cf. `applyDeletionsAndTombstones`). Idempotent
    /// et conçu pour être appelé **par lots pendant le pull** afin que
    /// les objets apparaissent au fil de l'eau et que le badge ↓ décroisse
    /// (la sonde compare serveur ↔ local, ce dernier étant mis à jour
    /// progressivement).
    ///
    /// Retourne l'ensemble des folders qui viennent de passer de
    /// non-synced à synced via ces changements (pour déclencher, une
    /// seule fois en fin de pull, le push des items locaux préexistants).
    @discardableResult
    private nonisolated func mergeChangedFoldersItems(changedFolders: [Folder],
                                                      changedItems: [SharedItem]) -> Set<String> {
        guard let d = UserDefaults(suiteName: appGroup) else { return [] }
        // Sérialise le read-modify-write avec l'UI (saveItems/saveFolders)
        // pour éviter qu'une écriture aveugle de l'UI n'écrase ces
        // changements (→ items perdus + fichiers orphelins).
        Self.storeLock.lock()
        defer { Self.storeLock.unlock() }

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

        // Détecte les folders qui passent de non-synced → synced.
        var newlySyncedFolderNames: Set<String> = []
        if !changedFolders.isEmpty {
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
            if let data = try? JSONEncoder().encode(folders) {
                d.set(data, forKey: "folders")
            }
        }

        // Items : insertion / mise à jour, avec la règle de fusion sur
        // l'aperçu verrouillé et la gestion du "delay set" preview.
        if !changedItems.isEmpty {
            var delaySet = (d.dictionary(forKey: "cloudPreviewWaitingItems") as? [String: Double]) ?? [:]
            // Ensemble des items reçus du cloud à NE PAS auto-décrire.
            var noAutoDescribe = Set((d.array(forKey: Self.noAutoDescribeKey) as? [String]) ?? [])
            // Nombre d'items réellement NOUVEAUX sur ce device : sert à
            // décrémenter le badge ↓ au fil de la réception (palier 1).
            var newlyAdded = 0
            let nowTS = Date().timeIntervalSince1970
            for it in changedItems {
                log("mergeChangedFoldersItems: id=\(it.id) folder=\"\(it.folder)\" url=\"\(it.url.prefix(60))\" locked=\(it.previewLocked == true)")
                let existingIdx = items.firstIndex(where: { $0.id == it.id })
                if existingIdx == nil { newlyAdded += 1 }
                if let idx = existingIdx {
                    // Si l'item local était DÉJÀ verrouillé, on conserve
                    // son `previewPath` local (le verrou protège l'aperçu
                    // même contre une version cloud). Sinon, l'item cloud
                    // écrase tel quel.
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
                // Suppression de la description AUTO :
                //   - reçu DÉJÀ décrit (aiDescribed==true) → on retire
                //     l'id (rien à attendre, le drapeau le protège aussi) ;
                //   - reçu sans description ET NOUVEAU sur cet appareil
                //     (existingIdx == nil) → on l'inscrit : c'est un objet
                //     venu d'un autre appareil, à lui de le décrire. (Un
                //     item déjà présent localement — ex. notre propre objet
                //     qui revient par un full-refresh — n'est PAS inscrit,
                //     pour ne pas brider l'appareil d'origine.)
                if it.aiDescribed == true {
                    noAutoDescribe.remove(it.id)
                } else if existingIdx == nil {
                    noAutoDescribe.insert(it.id)
                }
                if it.previewLocked != true,
                   (it.previewPath == nil || (it.previewPath ?? "").isEmpty) {
                    delaySet[it.id] = nowTS
                } else {
                    delaySet.removeValue(forKey: it.id)
                }
            }
            delaySet = delaySet.filter { nowTS - $0.value < 300 }
            d.set(delaySet, forKey: "cloudPreviewWaitingItems")
            // Élague les ids d'items disparus pour borner l'ensemble.
            noAutoDescribe.formIntersection(Set(items.map(\.id)))
            d.set(Array(noAutoDescribe), forKey: Self.noAutoDescribeKey)
            if let data = try? JSONEncoder().encode(items) {
                d.set(data, forKey: "items")
                log("mergeChangedFoldersItems wrote \(items.count) items to App Group UserDefaults")
            }
            // Décrémente le badge ↓ du nombre d'items fraîchement reçus
            // (pré-positionné par recomputeDownloadCount au début du pull).
            // Plancher à 0 ; le refresh de fin de pull recale la valeur.
            if newlyAdded > 0 {
                let cur = d.integer(forKey: Self.pendingDownloadKey)
                d.set(max(0, cur - newlyAdded), forKey: Self.pendingDownloadKey)
            }
        }

        return newlySyncedFolderNames
    }

    /// Applique les **suppressions** (tombstones + deletions de folders
    /// et d'items) reçues d'un pull. Appelé **une seule fois en fin de
    /// pull**, après toutes les fusions de changements, pour préserver
    /// l'ordre (tombstones → folders → items) et la garde `localOnly`
    /// qui protège des échos de notre propre `stopSync`.
    private nonisolated func applyDeletionsAndTombstones(deletedItemIDs: [String],
                                                         deletedFolderNames: [String],
                                                         tombstonedFolderNames: [String]) {
        guard !deletedItemIDs.isEmpty || !deletedFolderNames.isEmpty
                || !tombstonedFolderNames.isEmpty else { return }
        guard let d = UserDefaults(suiteName: appGroup) else { return }
        // Même verrou que mergeChangedFoldersItems / l'UI.
        Self.storeLock.lock()
        defer { Self.storeLock.unlock() }

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
            log("applyDeletionsAndTombstones: hard-deleted \(tombSet.count) tombstoned folder(s) and their content")
        }

        // Suppression de folder reçue du cloud : on ne supprime JAMAIS
        // le folder localement (modèle local-first). Un « Stop iCloud
        // sync » détruit les records serveur mais chaque appareil garde
        // sa copie locale, le folder est juste flippé `iCloudSynced=false`.
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

        let toDelete = Set(deletedItemIDs)
        if !toDelete.isEmpty {
            // On ne supprime pas localement les items dont le folder est
            // devenu local-only sur ce device : ces events sont l'écho
            // de notre propre stopSync.
            let actuallyRemoved = items.filter {
                toDelete.contains($0.id) && !localOnlyFolderNames.contains($0.folder)
            }
            items.removeAll { it in
                toDelete.contains(it.id) && !localOnlyFolderNames.contains(it.folder)
            }
            // Nettoyage disque : une suppression distante libère l'espace
            // local (binaire SharedFiles/ + preview previews/).
            cleanupFilesForRemovedItems(actuallyRemoved, remaining: items)
            if let data = try? JSONEncoder().encode(items) {
                d.set(data, forKey: "items")
                log("applyDeletionsAndTombstones removed \(actuallyRemoved.count) item(s)")
            }
        }
    }

    /// Déclenche, une seule fois en fin de pull, le push des items
    /// locaux préexistants d'un folder qui vient de passer en synced
    /// (cas : folder homonyme créé sur 2 appareils, sync activée sur un
    /// seul). Les items qu'on vient de recevoir (`receivedIds`) sont déjà
    /// sur le serveur → on seede `lastPushedItemHashes` pour que
    /// `flushPush` ne les ré-uploade pas.
    private nonisolated func triggerNewlySyncedPush(receivedIds: Set<String>,
                                                    newlySynced: Set<String>) {
        guard !newlySynced.isEmpty else { return }
        log("applyPulledChanges: folder(s) newly synced \(newlySynced) — triggering push of local items")
        let (folders, items) = readLocalFoldersAndItems()
        Task { [weak self] in
            guard let self else { return }
            await self.seedReceivedHashesAndPush(receivedIds: receivedIds,
                                                 folders: folders,
                                                 items: items)
        }
    }

    /// Supprime du disque les binaires + previews des items qui
    /// viennent d'être retirés localement (suppression distante), pour
    /// libérer l'espace. Garde-fou anti-collision : on ne supprime un
    /// fichier que si AUCUN item restant ne le référence encore — les
    /// noms de binaires sont dérivés du `lastPathComponent` de l'URL
    /// d'origine et peuvent donc collisionner entre items.
    private nonisolated func cleanupFilesForRemovedItems(_ removed: [SharedItem],
                                                         remaining: [SharedItem]) {
        guard !removed.isEmpty else { return }
        let fm = FileManager.default
        var usedBinaryPaths = Set<String>()
        var usedPreviewNames = Set<String>()
        for it in remaining {
            if let u = URL(string: it.url), u.isFileURL {
                usedBinaryPaths.insert(u.standardizedFileURL.path)
            }
            if let p = it.previewPath, !p.isEmpty { usedPreviewNames.insert(p) }
        }
        let previewsDir = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("previews", isDirectory: true)
        var deleted = 0
        for it in removed {
            if let u = URL(string: it.url), u.isFileURL,
               !usedBinaryPaths.contains(u.standardizedFileURL.path),
               fm.fileExists(atPath: u.path) {
                try? fm.removeItem(at: u)
                deleted += 1
            }
            if let p = it.previewPath, !p.isEmpty,
               !usedPreviewNames.contains(p), let dir = previewsDir {
                let url = dir.appendingPathComponent(p)
                if fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                    deleted += 1
                }
            }
        }
        if deleted > 0 {
            log("cleanupFilesForRemovedItems: freed \(deleted) file(s) for \(removed.count) removed item(s)")
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

    /// Somme des tailles disque (binaire + preview) que `startSync`
    /// devra uploader. Utilisé uniquement pour les logs de diagnostic.
    private func startSyncPayloadBytes(items: [SharedItem]) -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        for it in items {
            if let bin = binaryURL(for: it),
               let attrs = try? fm.attributesOfItem(atPath: bin.path),
               let n = attrs[.size] as? NSNumber {
                total += n.int64Value
            }
            if let prev = previewURL(for: it),
               let attrs = try? fm.attributesOfItem(atPath: prev.path),
               let n = attrs[.size] as? NSNumber {
                total += n.int64Value
            }
        }
        return total
    }

    // MARK: - Inventory (debug)

    /// Diagnostic-only : énumère TOUS les records actuellement présents
    /// sur le serveur dans la `CapturedZone`, indépendamment du
    /// `serverChangeToken`. Ne modifie ni le token persistant ni
    /// l'état local — son seul effet est d'écrire dans les logs un
    /// récapitulatif lisible :
    ///
    ///   - liste des Folder records par nom et `sortIndex` (avec
    ///     marqueur tombstone le cas échéant) ;
    ///   - liste des Item records groupés par folder, avec id, title,
    ///     et présence des CKAsset binaire/preview ;
    ///   - compteurs globaux, par folder, et détection des items
    ///     orphelins (folder field sans Folder record correspondant).
    ///
    /// Conçu pour répondre rapidement à la question « est-ce que ce
    /// que j'ai pushé depuis un autre appareil est bien visible côté
    /// serveur depuis CET appareil ? ». Si un folder est ici mais
    /// n'apparaît pas en local après pull, le problème est au niveau
    /// du delta/token, pas du push. S'il n'est pas ici, l'appareil
    /// source n'a jamais fini de pousser (réseau, payload trop gros,
    /// app suspendue avant la fin, etc.).
    func inventoryCloud() async {
        log("inventoryCloud: starting (bypass serverChangeToken)")
        await refreshAccountStatus()
        guard accountState == .available else {
            log("inventoryCloud aborted: accountState=\(accountState)")
            return
        }
        do {
            try await ensureZone()
        } catch {
            log("inventoryCloud: ensureZone failed: \(error.localizedDescription)")
            return
        }

        // Full fetch (token=nil) sans toucher au token persistant ni
        // à l'état local.
        var config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = nil
        let op = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: config]
        )
        op.qualityOfService = .userInitiated
        op.fetchAllChanges = true

        // Buffers — pas de mutation d'état CloudSync ici. Même
        // pattern que `fetchZoneChanges` : les callbacks CKOperation
        // arrivent séquentiellement sur la queue interne de la
        // CKDatabase, donc une mutation directe de vars locales est
        // safe dans ce contexte.
        struct FolderRow { let name: String; let sortIndex: Double?; let tombstone: Bool }
        struct ItemRow { let id: String; let folder: String; let title: String; let hasAsset: Bool; let hasPreview: Bool }
        var foldersOut: [FolderRow] = []
        var itemsOut: [ItemRow] = []

        op.recordWasChangedBlock = { recordID, result in
            switch result {
            case .success(let record):
                switch record.recordType {
                case "Folder":
                    let name = (record["name"] as? String) ?? recordID.recordName
                    let sort = record["sortIndex"] as? Double
                    let tomb = ((record["tombstone"] as? Int) ?? 0) != 0
                    foldersOut.append(FolderRow(name: name, sortIndex: sort, tombstone: tomb))
                case "Item":
                    let folder = (record["folder"] as? String) ?? "?"
                    let title = (record["title"] as? String)
                        ?? ((record["url"] as? String).map { String($0.prefix(60)) })
                        ?? "?"
                    let hasAsset = record["asset"] != nil
                    let hasPreview = record["previewAsset"] != nil
                    itemsOut.append(ItemRow(id: recordID.recordName, folder: folder, title: title,
                                            hasAsset: hasAsset, hasPreview: hasPreview))
                default: break
                }
            case .failure(let err):
                self.log("inventoryCloud: record \(recordID.recordName) failed: \(err.localizedDescription)")
            }
        }
        // On ignore volontairement recordWithIDWasDeletedBlock /
        // recordZoneChangeTokensUpdatedBlock / recordZoneFetchResultBlock
        // pour ne PAS sauvegarder le token. Avec previousServerChangeToken
        // = nil, le serveur renvoie l'état complet ; pas de deletions
        // à voir, et on veut explicitement éviter d'avancer le token
        // du sync principal.

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                op.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let err): cont.resume(throwing: err)
                    }
                }
                privateDB.add(op)
            }
        } catch {
            log("inventoryCloud: fetch failed: \(error.localizedDescription) — \(error)")
            return
        }

        let folders = foldersOut.sorted { ($0.sortIndex ?? 0) < ($1.sortIndex ?? 0) }
        let items = itemsOut
        log("inventoryCloud: server has \(folders.count) Folder record(s), \(items.count) Item record(s)")

        let folderNames = Set(folders.map(\.name))
        for f in folders {
            let count = items.filter { $0.folder == f.name }.count
            let tag = f.tombstone ? " 🪦TOMBSTONE" : ""
            let sortStr = f.sortIndex.map { String(format: "%.3f", $0) } ?? "nil"
            log("inventoryCloud: 📁 \"\(f.name)\" sortIndex=\(sortStr) items=\(count)\(tag)")
        }
        let orphans = items.filter { !folderNames.contains($0.folder) }
        if !orphans.isEmpty {
            log("inventoryCloud: ⚠️ \(orphans.count) orphan item(s) — folder field has no matching Folder record")
            for o in orphans.prefix(20) {
                log("inventoryCloud: ⚠️ orphan \(o.id) folder=\"\(o.folder)\" title=\"\(o.title)\"")
            }
        }
        // Détails par folder, plafonnés à 50 items chacun pour ne pas
        // saturer le fichier de log en cas de gros volume.
        for f in folders {
            let folderItems = items.filter { $0.folder == f.name }
            let withAsset = folderItems.filter(\.hasAsset).count
            let withPreview = folderItems.filter(\.hasPreview).count
            log("inventoryCloud: --- \"\(f.name)\" — \(folderItems.count) item(s), assets=\(withAsset), previews=\(withPreview)")
            for (i, it) in folderItems.prefix(50).enumerated() {
                let a = it.hasAsset ? "📎" : "  "
                let p = it.hasPreview ? "🖼" : "  "
                log("inventoryCloud:   \(a)\(p) [\(i+1)/\(folderItems.count)] \(it.id) title=\"\(it.title)\"")
            }
            if folderItems.count > 50 {
                log("inventoryCloud:   … (\(folderItems.count - 50) more items not listed)")
            }
        }

        // Subscriptions côté serveur : utile pour vérifier que la
        // CKDatabaseSubscription est bien installée sur cet appareil.
        do {
            let subs = try await privateDB.allSubscriptions()
            log("inventoryCloud: server reports \(subs.count) subscription(s) for this user")
            for s in subs {
                log("inventoryCloud:   • subscription id=\(s.subscriptionID) type=\(type(of: s))")
            }
        } catch {
            log("inventoryCloud: subscriptions fetch failed: \(error.localizedDescription)")
        }

        // État local persistant pertinent pour comparer.
        let tokenPresent = savedZoneChangeToken() != nil
        let zoneFlag = defaults?.bool(forKey: "cloudKitZoneCreated") ?? false
        let subFlag = defaults?.bool(forKey: "cloudKitSubscriptionCreated") ?? false
        log("inventoryCloud: local flags — zoneCreated=\(zoneFlag) subscriptionCreated=\(subFlag) zoneChangeToken=\(tokenPresent ? "present" : "nil")")

        log("inventoryCloud: ✅ done")
    }

    // MARK: - Transfer counts (UI progress badges)

    /// Clés App Group exposant à l'IHM le nombre d'objets en attente
    /// de transfert dans chaque sens. Lues par `StatsPanelView` pour
    /// afficher « ↑N » (à envoyer) / « ↓N » (à récupérer) à côté de la
    /// taille iCloud.
    private static let pendingUploadKey = "cloudPendingUploadCount"
    private static let pendingDownloadKey = "cloudPendingDownloadCount"

    private var isRefreshingCounts = false

    /// Recalcule le compteur « à récupérer » (↓) et l'écrit dans
    /// l'App Group pour l'IHM.
    ///
    /// Le compteur « à envoyer » (↑) n'est PAS géré ici : il est
    /// calculé localement et instantanément (cf. `snapshotChanged` /
    /// `flushPush` / `seedSnapshotFromLocal`), car l'envoi est
    /// intrinsèquement local à cet appareil et doit s'afficher dès la
    /// mutation, sans latence réseau.
    ///
    /// Principe pour le ↓ : une **sonde métadonnées** (token=nil,
    /// `desiredKeys` réduit → AUCUN binaire téléchargé) récupère
    /// l'index des records présents côté serveur. **à récupérer** =
    /// items présents sur le serveur (dans un folder serveur réel)
    /// dont l'id n'est PAS encore en local. Découplé du
    /// `serverChangeToken` : reflète l'écart réel même sur un receveur
    /// qui n'a pas encore le folder en local. Pendant un gros
    /// `fetchZoneChanges`, l'acteur est suspendu sur sa continuation :
    /// cette sonde peut s'intercaler et afficher « ↓30 » tant que le
    /// pull lourd n'a pas fini d'appliquer.
    func refreshTransferCounts() async {
        if isRefreshingCounts { return }
        isRefreshingCounts = true
        defer { isRefreshingCounts = false }

        await refreshAccountStatus()
        await recomputeDownloadCount()
    }

    /// Sonde le serveur (métadonnées) et écrit le compteur ↓ = items
    /// présents côté serveur (dans un folder serveur) dont l'id n'est
    /// pas encore en local. Suppose `accountState` déjà rafraîchi par
    /// l'appelant. Retourne le nombre écrit, ou `nil` si la sonde a
    /// échoué (réseau) — dans ce cas le compteur affiché est laissé
    /// inchangé.
    @discardableResult
    private func recomputeDownloadCount() async -> Int? {
        guard accountState == .available else {
            writeDownloadCount(0)
            return 0
        }

        let (localFolders, localItems) = readLocalFoldersAndItems()
        let syncedLocalFolders = Set(localFolders.filter { $0.iCloudSynced }.map(\.name))
        let localItemIds = Set(localItems.map(\.id))

        // Rien de synced localement ET zone jamais créée sur cet
        // appareil → rien à récupérer, 0 sans toucher au réseau.
        let zoneCreated = defaults?.bool(forKey: "cloudKitZoneCreated") ?? false
        if syncedLocalFolders.isEmpty && !zoneCreated {
            writeDownloadCount(0)
            return 0
        }

        let serverIndex: (folderNames: Set<String>, itemFolders: [String: String])
        do {
            serverIndex = try await fetchServerItemIndex()
        } catch {
            // Échec réseau : on ne perturbe pas l'affichage courant.
            log("recomputeDownloadCount: index fetch failed: \(error.localizedDescription)")
            return nil
        }

        let pendingDownload = serverIndex.itemFolders.filter { (id, folder) in
            !localItemIds.contains(id) && serverIndex.folderNames.contains(folder)
        }.count

        writeDownloadCount(pendingDownload)
        return pendingDownload
    }

    /// Sonde métadonnées : index serveur (folders + mapping itemID →
    /// folder) sans téléchargement de binaire. `token=nil` → image
    /// complète ; `desiredKeys` réduit aux petits champs → pas de
    /// `asset`/`previewAsset` rapatriés. N'enregistre PAS de
    /// `serverChangeToken` (indépendant du sync principal).
    private func fetchServerItemIndex() async throws
        -> (folderNames: Set<String>, itemFolders: [String: String]) {
        try await ensureZone()
        var config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = nil
        config.desiredKeys = ["folder", "name", "tombstone"]
        let op = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: config]
        )
        op.qualityOfService = .utility
        op.fetchAllChanges = true

        var folderNames: Set<String> = []
        var itemFolders: [String: String] = [:]
        op.recordWasChangedBlock = { recordID, result in
            guard case .success(let record) = result else { return }
            switch record.recordType {
            case "Folder":
                let tomb = ((record["tombstone"] as? Int) ?? 0) != 0
                if !tomb {
                    folderNames.insert((record["name"] as? String) ?? recordID.recordName)
                }
            case "Item":
                itemFolders[recordID.recordName] = (record["folder"] as? String) ?? ""
            default: break
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
        return (folderNames, itemFolders)
    }

    private nonisolated func writeUploadCount(_ n: Int) {
        UserDefaults(suiteName: appGroup)?.set(n, forKey: Self.pendingUploadKey)
    }
    private nonisolated func writeDownloadCount(_ n: Int) {
        UserDefaults(suiteName: appGroup)?.set(n, forKey: Self.pendingDownloadKey)
    }

    // MARK: - Upload resume (cross-restart)

    /// Clé App Group : signature stable du dernier état pushé par
    /// item (`id` → SHA256 du JSON trié de l'item). Sert UNIQUEMENT
    /// à `resumePendingUploads` pour détecter, après un redémarrage,
    /// les items modifiés hors-ligne (le snapshot mémoire
    /// `lastPushedItemHashes` est perdu au kill, et `hashValue` n'est
    /// de toute façon PAS stable entre deux process Swift — seed
    /// aléatoire — donc inutilisable en persistance).
    private static let pushedSignaturesKey = "cloudPushedItemSignatures"

    /// Clé App Group : ids des items reçus d'iCloud SANS description IA.
    /// Le déclencheur automatique de description (côté UI,
    /// `triggerPendingAIDescriptions`) les ignore : décrire un objet est
    /// la responsabilité de l'appareil d'origine ; le receveur attend
    /// que la description lui parvienne par sync plutôt que de relancer
    /// une invocation IA en double. Un id sort de l'ensemble dès qu'on
    /// reçoit la version décrite de l'item (ou que l'item disparaît). Les
    /// actions MANUELLES (Regenerate AI text) ne passent pas par le
    /// déclencheur auto et ne sont donc pas affectées.
    static let noAutoDescribeKey = "cloudReceivedNoAutoDescribe"

    /// Signature de contenu stable et déterministe d'un item, pour la
    /// détection de changement inter-redémarrage. `hashValue` ne
    /// convient pas (randomisé par process) ; on hashe le JSON à clés
    /// triées.
    private nonisolated func itemSignature(_ item: SharedItem) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(item) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func loadPushedSignatures() -> [String: String] {
        (UserDefaults(suiteName: appGroup)?
            .dictionary(forKey: Self.pushedSignaturesKey) as? [String: String]) ?? [:]
    }
    private nonisolated func savePushedSignatures(_ map: [String: String]) {
        UserDefaults(suiteName: appGroup)?.set(map, forKey: Self.pushedSignaturesKey)
    }

    /// Reconstruit le snapshot mémoire (`lastPushedItemHashes`,
    /// `lastPushedFolderNames`) ET la map de signatures persistée à
    /// partir de l'état local des folders synced. À appeler après une
    /// opération qui garantit que TOUS les items des folders synced
    /// sont sur le serveur (fin de `resumePendingUploads`). Auto-prune
    /// les entrées de signature des items disparus.
    private func seedSnapshotFromLocal(folders: [Folder], items: [SharedItem]) {
        let syncedNames = Set(folders.filter { $0.iCloudSynced }.map(\.name))
        var hashes: [String: Int] = [:]
        var sigs: [String: String] = [:]
        for item in items where syncedNames.contains(item.folder) {
            hashes[item.id] = item.hashValue
            sigs[item.id] = itemSignature(item)
        }
        lastPushedItemHashes = hashes
        lastPushedFolderNames = syncedNames
        savePushedSignatures(sigs)
        // Recale le badge ↑ après seed (snapshot reflète l'état serveur).
        writeUploadCount(localPendingUploadCount(folders: folders, items: items))
    }

    /// Reprend un envoi interrompu après un redémarrage de l'app.
    ///
    /// Contexte : rien ne relance un push au lancement (seuls des
    /// pulls sont déclenchés), et le snapshot de diff push est en
    /// mémoire — perdu si l'app est tuée pendant un upload. Un dossier
    /// marqué synced dont les items ne sont jamais arrivés sur le
    /// serveur resterait donc bloqué (badge ↑N figé) jusqu'à une
    /// mutation manuelle ou un « Resync iCloud ».
    ///
    /// Algorithme (idempotent, ciblé — ne re-pousse PAS toute la
    /// bibliothèque) :
    ///   1. Sonde l'index serveur (métadonnées, sans binaires).
    ///   2. Détermine le strict nécessaire à pousser :
    ///        - folders synced absents du serveur ;
    ///        - items synced absents du serveur (id manquant) OU
    ///          modifiés hors-ligne (signature ≠ dernière pushée).
    ///   3. Pousse ce diff, ré-installe la subscription au passage.
    ///   4. Re-seed le snapshot mémoire + signatures (tout est sur le
    ///      serveur après succès), invalide le token, rafraîchit les
    ///      compteurs.
    func resumePendingUploads() async {
        await refreshAccountStatus()
        guard accountState == .available else { return }

        let (localFolders, localItems) = readLocalFoldersAndItems()
        let syncedFolders = localFolders.filter { $0.iCloudSynced }
        guard !syncedFolders.isEmpty else { return }
        let syncedNames = Set(syncedFolders.map(\.name))

        let serverIndex: (folderNames: Set<String>, itemFolders: [String: String])
        do {
            serverIndex = try await fetchServerItemIndex()
        } catch {
            log("resumePendingUploads: index fetch failed: \(error.localizedDescription)")
            return
        }
        let serverItemIds = Set(serverIndex.itemFolders.keys)
        let sigs = loadPushedSignatures()

        var recordsToSave: [CKRecord] = []
        for f in syncedFolders where !serverIndex.folderNames.contains(f.name) {
            recordsToSave.append(buildFolderRecord(f))
        }
        var missingCount = 0
        var changedCount = 0
        for item in localItems where syncedNames.contains(item.folder) {
            let missing = !serverItemIds.contains(item.id)
            let changed = !missing && sigs[item.id] != itemSignature(item)
            if missing || changed {
                if missing { missingCount += 1 } else { changedCount += 1 }
                let folderID = CKRecord.ID(recordName: item.folder, zoneID: zoneID)
                recordsToSave.append(buildItemRecord(item, folderRecordID: folderID))
            }
        }

        guard !recordsToSave.isEmpty else {
            // Rien à reprendre : on (re)seede tout de même le snapshot
            // mémoire pour que le diff push de la session soit exact.
            seedSnapshotFromLocal(folders: localFolders, items: localItems)
            return
        }

        log("resumePendingUploads: resuming \(recordsToSave.count) record(s) — \(missingCount) missing item(s), \(changedCount) changed item(s)")
        do {
            try await ensureZone()
            // Push progressif (per-record) : badge ↑ décrémenté à l'unité
            // pendant la reprise, comme flushPush/startSync. Ici
            // `recordsToSave` couvre TOUS les dossiers synced, donc le
            // nombre d'items est le total ↑ exact (pas de baseline).
            let pendingItemIDs = Set(
                recordsToSave.filter { $0.recordType == "Item" }.map { $0.recordID.recordName }
            )
            let totalPending = pendingItemIDs.count
            writeUploadCount(totalPending)
            let progressLock = NSLock()
            var savedCount = 0
            try await saveRecords(recordsToSave) { savedID in
                guard pendingItemIDs.contains(savedID.recordName) else { return }
                progressLock.lock()
                savedCount += 1
                let remaining = max(0, totalPending - savedCount)
                progressLock.unlock()
                self.writeUploadCount(remaining)
            }
            try? await ensureSubscription()
            seedSnapshotFromLocal(folders: localFolders, items: localItems)
            saveZoneChangeToken(nil)
            await refreshTransferCounts()
            log("resumePendingUploads: ✅ done")
        } catch {
            log("resumePendingUploads: push failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Logging

    /// Helper statique pour permettre à du code hors-actor (ex.
    /// `AppDelegate.didRegisterForRemoteNotifications…`) d'écrire dans
    /// la même destination que les logs internes de CloudSync : stdout
    /// + fichier `extension_debug.log` du container App Group quand
    /// l'utilisateur a activé Debug Logs. Évite la divergence entre
    /// les traces visibles dans Xcode et celles consultables depuis
    /// l'app après coup.
    static func externalLog(_ s: String) {
        let ts = timestampFormatter.string(from: Date())
        let line = "[CloudSync][\(ts)][\(UIDevice.current.name)] \(s)"
        print(line)
        appendToDebugFile(line)
    }

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
