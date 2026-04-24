import UIKit
import UniformTypeIdentifiers
import ImageIO
import os.log

class ShareViewController: UIViewController {

    let appGroup = "group.net.fenyo.apple.sharemanager"
    private let logger = Logger(subsystem: "net.fenyo.apple.sharemanager", category: "ShareExtension")
    
    // MARK: - Debug Configuration
    
    private var isDebugEnabled: Bool {
        let defaults = UserDefaults(suiteName: appGroup)
        return defaults?.bool(forKey: "debugLogsEnabled") ?? false
    }
    
    // MARK: - File Logging
    
    private func log(_ message: String) {
        guard isDebugEnabled else { return }

        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)\n"

        // Console de debug Xcode (stdout)
        print(logMessage, terminator: "")

        // Fichier partagé lu par l'app pour l'affichage dans le popup
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return
        }
        let logFileURL = containerURL.appendingPathComponent("extension_debug.log")

        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL, options: .atomic)
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.0)
        
        log("🎬 ShareViewController viewDidLoad() called")
        log("   Bundle ID: \(Bundle.main.bundleIdentifier ?? "N/A")")
        log("   Extension Context: \(extensionContext != nil ? "✅ Available" : "❌ Not available")")
        log("   Debug Enabled: \(isDebugEnabled)")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        log("🎬 ShareViewController viewDidAppear() called")
        log("   Extension Context Available: \(extensionContext != nil)")
        
        // Explorer TOUS les types de données disponibles (pour debugging/découverte)
        if isDebugEnabled {
            exploreAllDataTypes()
        }
        
        // Puis extraire et sauvegarder comme d'habitude
        extractAndSaveURL()
    }

    private func extractAndSaveURL() {
        print("\nALEXDEBUG " + String(repeating: "=", count: 80))
        print("ALEXDEBUG 🚀 SHARE EXTENSION ACTIVATED")
        print("ALEXDEBUG " + String(repeating: "=", count: 80))
        
        log("🚀 extractAndSaveURL() called")

        guard let extensionContext = extensionContext else {
            print("ALEXDEBUG ❌ No extension context available")
            log("❌ No extension context available")
            complete()
            return
        }
        
        // ===== INSPECTION COMPLÈTE DE L'EXTENSION CONTEXT =====
        print("\nALEXDEBUG 📦 EXTENSION CONTEXT INFO:")
        print("ALEXDEBUG    Input Items Count: \(extensionContext.inputItems.count)")
        
        for (index, inputItem) in extensionContext.inputItems.enumerated() {
            print("\n┌─ Input Item #\(index + 1)")
            
            guard let item = inputItem as? NSExtensionItem else {
                print("│  ⚠️  Not an NSExtensionItem")
                continue
            }
            
            // Informations de base
            print("│")
            print("│  📄 BASIC INFO:")
            print("│     Type: \(type(of: item))")
            print("│     Attachments Count: \(item.attachments?.count ?? 0)")
            
            // Attributed Title
            if let title = item.attributedTitle {
                print("│")
                print("│  📌 ATTRIBUTED TITLE:")
                print("│     String: \(title.string)")
                print("│     Length: \(title.length)")
                if title.length > 0 {
                    var range = NSRange(location: 0, length: title.length)
                    let attributes = title.attributes(at: 0, effectiveRange: &range)
                    print("│     Attributes: \(attributes)")
                }
            }
            
            // Attributed Content Text
            if let contentText = item.attributedContentText {
                print("│")
                print("│  📝 ATTRIBUTED CONTENT TEXT:")
                print("│     String: \(contentText.string)")
                print("│     Length: \(contentText.length)")
                if contentText.length > 0 {
                    var range = NSRange(location: 0, length: contentText.length)
                    let attributes = contentText.attributes(at: 0, effectiveRange: &range)
                    print("│     Attributes: \(attributes)")
                }
            }
            
            // User Info
            if let userInfo = item.userInfo {
                print("│")
                print("│  🔍 USER INFO:")
                for (key, value) in userInfo {
                    print("│     [\(key)]: \(value)")
                    print("│        Type: \(type(of: value))")
                }
            } else {
                print("│  ℹ️  No User Info")
            }
            
            // Attachments
            if let attachments = item.attachments {
                print("│")
                print("│  📎 ATTACHMENTS: \(attachments.count) item(s)")
                
                for (attachIndex, attachment) in attachments.enumerated() {
                    print("│")
                    print("│  ├─ Attachment #\(attachIndex + 1)")
                    print("│  │  Type: \(type(of: attachment))")
                    
                    // Registered Type Identifiers
                    if #available(iOS 15.0, *) {
                        print("│  │  Registered Type Identifiers:")
                        for typeId in attachment.registeredTypeIdentifiers {
                            print("│  │     • \(typeId)")
                            print("│  │       Has Item: \(attachment.hasItemConformingToTypeIdentifier(typeId))")
                        }
                    } else {
                        print("│  │  Registered Type Identifiers: \(attachment.registeredTypeIdentifiers)")
                    }
                }
            }
            
            print("└" + String(repeating: "─", count: 78))
        }
        
        print("\n" + String(repeating: "=", count: 80))
        print("🔍 STARTING DATA EXTRACTION")
        print(String(repeating: "=", count: 80) + "\n")
        
        // Continuer avec l'extraction normale
        guard let item = extensionContext.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else {
            log("❌ No NSExtensionItem or no attachments — completing silently")
            complete()
            return
        }
        log("📦 Found \(attachments.count) attachment(s) on first input item")
        
        // IMPORTANT: Extraire le titre ICI, au bon endroit, avant les closures asynchrones
        let pageTitle = item.attributedTitle?.string
        if let pageTitle = pageTitle {
            print("📌 Page title will be saved: \(pageTitle)")
            logger.info("📌 PAGE TITLE FOUND: \(pageTitle)")
        } else {
            print("⚠️ No page title available")
            logger.warning("⚠️ NO PAGE TITLE - attributedTitle is nil")
        }
        
        // LOG SUPPLÉMENTAIRE : Afficher TOUTES les propriétés de l'item
        logger.info("🔍 Item properties:")
        logger.info("   - attributedTitle: \(String(describing: item.attributedTitle?.string))")
        logger.info("   - attributedContentText: \(String(describing: item.attributedContentText?.string))")
        logger.info("   - userInfo keys: \(item.userInfo?.keys.map { String(describing: $0) }.joined(separator: ", ") ?? "none")")
        
        // Récupérer l'app source qui partage le contenu
        let sourceApp = getSourceApplication()

        // -- Branche photo (public.image) traitée avant la branche URL,
        //    car une photo partagée arrive généralement avec UTI public.jpeg
        //    qui ne conforme pas à public.url.
        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                log("🖼 Image branch matched (hasItem public.image). Loading…")
                attachment.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] data, error in
                    self?.log("📥 Image loadItem: type=\(type(of: data)) err=\(error?.localizedDescription ?? "none")")

                    // Images iOS sont presque toujours fournies comme URL.
                    guard let imageURL = data as? URL, imageURL.isFileURL else {
                        self?.log("⚠️ Image loadItem ne renvoie pas de file URL — fallback unsupported")
                        DispatchQueue.main.async {
                            self?.logUnsupportedPayloadAndComplete()
                        }
                        return
                    }

                    // Lectures AVANT la copie (sinon on perd l'accès
                    // security-scoped et on mesure notre propre copie).
                    let (srcModDate, gps): (Double?, (lat: Double, lon: Double)?) = {
                        let didStart = imageURL.startAccessingSecurityScopedResource()
                        defer { if didStart { imageURL.stopAccessingSecurityScopedResource() } }
                        var mod: Double? = nil
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: imageURL.path),
                           let d = attrs[.modificationDate] as? Date {
                            mod = d.timeIntervalSince1970
                        }
                        let gpsRead = Self.readGPS(from: imageURL)
                        return (mod, gpsRead)
                    }()

                    guard let copied = self?.copyFileToAppGroup(originalURL: imageURL) else {
                        self?.log("⚠️ Échec de la copie de la photo dans l'App Group — unsupported.")
                        DispatchQueue.main.async {
                            self?.logUnsupportedPayloadAndComplete()
                        }
                        return
                    }
                    let filename = imageURL.lastPathComponent
                    let title = (pageTitle?.isEmpty == false) ? pageTitle : filename
                    let finalSource = sourceApp ?? "Photos"
                    self?.log("🖼 Photo imported: \(copied.lastPathComponent) modDate=\(String(describing: srcModDate)) gps=\(String(describing: gps))")
                    self?.save(urlString: copied.absoluteString,
                               sourceApp: finalSource,
                               pageTitle: title,
                               kind: "photo",
                               modifiedAt: srcModDate,
                               latitude: gps?.lat,
                               longitude: gps?.lon)
                    DispatchQueue.main.async {
                        self?.showCheckmark(sourceApp: finalSource)
                    }
                }
                return
            }
        }

        // -- Branche vidéo (public.movie) traitée avant URL : un mp4 partagé
        //    arrive typiquement avec UTI public.mpeg-4 qui conforme à
        //    public.movie → public.audiovisual-content → public.data, mais pas
        //    à public.url.
        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                log("🎬 Video branch matched (hasItem public.movie). Loading…")
                attachment.loadItem(forTypeIdentifier: UTType.movie.identifier, options: nil) { [weak self] data, error in
                    self?.log("📥 Video loadItem: type=\(type(of: data)) err=\(error?.localizedDescription ?? "none")")

                    guard let videoURL = data as? URL, videoURL.isFileURL else {
                        self?.log("⚠️ Video loadItem ne renvoie pas de file URL — fallback unsupported")
                        DispatchQueue.main.async {
                            self?.logUnsupportedPayloadAndComplete()
                        }
                        return
                    }

                    let srcModDate: Double? = {
                        let didStart = videoURL.startAccessingSecurityScopedResource()
                        defer { if didStart { videoURL.stopAccessingSecurityScopedResource() } }
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: videoURL.path),
                           let d = attrs[.modificationDate] as? Date {
                            return d.timeIntervalSince1970
                        }
                        return nil
                    }()

                    guard let copied = self?.copyFileToAppGroup(originalURL: videoURL) else {
                        self?.log("⚠️ Échec de la copie de la vidéo dans l'App Group — unsupported.")
                        DispatchQueue.main.async {
                            self?.logUnsupportedPayloadAndComplete()
                        }
                        return
                    }
                    let filename = videoURL.lastPathComponent
                    let title = (pageTitle?.isEmpty == false) ? pageTitle : filename
                    let finalSource = sourceApp ?? "Videos"
                    self?.log("🎬 Video imported: \(copied.lastPathComponent) modDate=\(String(describing: srcModDate))")
                    self?.save(urlString: copied.absoluteString,
                               sourceApp: finalSource,
                               pageTitle: title,
                               kind: "video",
                               modifiedAt: srcModDate)
                    DispatchQueue.main.async {
                        self?.showCheckmark(sourceApp: finalSource)
                    }
                }
                return
            }
        }

        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                print("✅ Found URL type identifier")
                log("🔗 URL branch matched (hasItem public.url). Loading…")
                attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] data, error in
                    print("\n📥 URL DATA LOADED:")
                    print("   Data Type: \(type(of: data))")
                    print("   Error: \(error?.localizedDescription ?? "None")")
                    self?.log("📥 URL loadItem: type=\(type(of: data)) err=\(error?.localizedDescription ?? "none") value=\(String(describing: data))")

                    // Cas fichier : on le copie dans l'App Group pour le
                    // rendre persistant puis on l'enregistre comme entrée.
                    if let fileURL = data as? URL, fileURL.isFileURL {
                        // Lire la date de modification AVANT la copie
                        // pour ne pas récupérer la date de notre propre copie.
                        let srcModDate: Double? = {
                            let didStart = fileURL.startAccessingSecurityScopedResource()
                            defer { if didStart { fileURL.stopAccessingSecurityScopedResource() } }
                            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                               let date = attrs[.modificationDate] as? Date {
                                return date.timeIntervalSince1970
                            }
                            return nil
                        }()

                        guard let copied = self?.copyFileToAppGroup(originalURL: fileURL) else {
                            self?.log("⚠️ Échec de la copie du fichier dans l'App Group — unsupported.")
                            DispatchQueue.main.async {
                                self?.logUnsupportedPayloadAndComplete()
                            }
                            return
                        }
                        let filename = fileURL.lastPathComponent
                        let title = (pageTitle?.isEmpty == false) ? pageTitle : filename
                        let finalSource = sourceApp ?? "Files"
                        self?.log("📁 File imported: \(copied.lastPathComponent) (from \(fileURL.path)) modDate=\(String(describing: srcModDate))")
                        self?.save(urlString: copied.absoluteString,
                                   sourceApp: finalSource,
                                   pageTitle: title,
                                   kind: "file",
                                   modifiedAt: srcModDate)
                        DispatchQueue.main.async {
                            self?.showCheckmark(sourceApp: finalSource)
                        }
                        return
                    }

                    var urlString: String?
                    if let url = data as? URL, url.scheme == "http" || url.scheme == "https" {
                        urlString = url.absoluteString
                        print("   ✅ URL Object: \(urlString!)")
                    } else if let str = data as? String,
                              let url = URL(string: str),
                              url.scheme == "http" || url.scheme == "https" {
                        urlString = str
                        print("   ✅ String URL: \(urlString!)")
                    }

                    guard let urlString = urlString else {
                        self?.log("⚠️ public.url matched but no http(s) URL extracted — treating as unsupported.")
                        DispatchQueue.main.async {
                            self?.logUnsupportedPayloadAndComplete()
                        }
                        return
                    }

                    // IMPORTANT: Détecter la source AVANT la transformation
                    let detectedSource = self?.detectSourceBeforeTransform(urlString) ?? sourceApp
                    let transformedURL = self?.transform(urlString: urlString) ?? urlString

                    print("   📊 URL Processing:")
                    print("      Original: \(urlString)")
                    print("      Transformed: \(transformedURL)")
                    print("      Source: \(detectedSource ?? "Unknown")")
                    print("      Title from attributedTitle: \(pageTitle ?? "None")")

                    if pageTitle == nil || pageTitle!.isEmpty {
                        print("   🔄 No title from attributedTitle, fetching from original URL...")
                        self?.fetchTitleFromURL(urlString) { fetchedTitle in
                            let finalTitle = fetchedTitle ?? pageTitle
                            print("   📌 Final title to save: \(finalTitle ?? "None")")
                            self?.save(urlString: transformedURL, sourceApp: detectedSource, pageTitle: finalTitle)
                            DispatchQueue.main.async {
                                self?.showCheckmark(sourceApp: detectedSource)
                            }
                        }
                    } else {
                        self?.save(urlString: transformedURL, sourceApp: detectedSource, pageTitle: pageTitle)
                        DispatchQueue.main.async {
                            self?.showCheckmark(sourceApp: detectedSource)
                        }
                    }
                }
                return
            }
        }

        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                print("✅ Found Plain Text type identifier")
                log("📝 Plain Text branch matched. Loading…")
                attachment.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] data, error in
                    print("\n📥 PLAIN TEXT DATA LOADED:")
                    print("   Data Type: \(type(of: data))")
                    print("   Error: \(error?.localizedDescription ?? "None")")
                    self?.log("📥 Plain Text loadItem: type=\(type(of: data)) err=\(error?.localizedDescription ?? "none")")

                    guard let str = data as? String else {
                        self?.log("⚠️ plainText data isn't a String — unsupported.")
                        DispatchQueue.main.async {
                            self?.logUnsupportedPayloadAndComplete()
                        }
                        return
                    }

                    // Cas 1 : le texte est une URL http(s) → on reprend le flux URL.
                    var urlString: String?
                    if let url = URL(string: str),
                       url.scheme == "http" || url.scheme == "https" {
                        urlString = str
                        print("   ✅ Text contains URL: \(urlString!)")
                    }

                    // Cas 2 : texte sans URL web → on sauve en tant que texte.
                    guard let urlString = urlString else {
                        let firstLine = str.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? str
                        let textTitle = (pageTitle?.isEmpty == false) ? pageTitle : String(firstLine.prefix(80))
                        let finalSource = sourceApp ?? "Text"
                        self?.log("📝 Saving text content (\(str.count) chars)")
                        self?.save(urlString: str, sourceApp: finalSource, pageTitle: textTitle, kind: "text")
                        DispatchQueue.main.async {
                            self?.showCheckmark(sourceApp: finalSource)
                        }
                        return
                    }

                    // IMPORTANT: Détecter la source AVANT la transformation
                    let detectedSource = self?.detectSourceBeforeTransform(urlString) ?? sourceApp
                    let transformedURL = self?.transform(urlString: urlString) ?? urlString

                    print("   📊 URL Processing:")
                    print("      Original: \(urlString)")
                    print("      Transformed: \(transformedURL)")
                    print("      Source: \(detectedSource ?? "Unknown")")
                    print("      Title from attributedTitle: \(pageTitle ?? "None")")

                    if pageTitle == nil || pageTitle!.isEmpty {
                        print("   🔄 No title from attributedTitle, fetching from original URL...")
                        self?.fetchTitleFromURL(urlString) { fetchedTitle in
                            let finalTitle = fetchedTitle ?? pageTitle
                            print("   📌 Final title to save: \(finalTitle ?? "None")")
                            self?.save(urlString: transformedURL, sourceApp: detectedSource, pageTitle: finalTitle)
                            DispatchQueue.main.async {
                                self?.showCheckmark(sourceApp: detectedSource)
                            }
                        }
                    } else {
                        self?.save(urlString: transformedURL, sourceApp: detectedSource, pageTitle: pageTitle)
                        DispatchQueue.main.async {
                            self?.showCheckmark(sourceApp: detectedSource)
                        }
                    }
                }
                return
            }
        }

        print("⚠️  No URL or Plain Text found in attachments")
        log("⚠️ No URL or Plain Text attachment found — dumping payload details")
        logUnsupportedPayloadAndComplete()
    }

    /// Aucun type pris en charge n'a été trouvé : on capture TOUT ce qu'on
    /// peut sur l'extension item (titres, userInfo, attachments, UTI déclarés,
    /// aperçu du contenu chargé par type) dans le log fichier lu par l'app.
    /// Utile pour découvrir quelles apps partagent quoi, et ajouter ensuite
    /// le support du type correspondant.
    private func logUnsupportedPayloadAndComplete() {
        // Affiche l'indicateur visuel « non supporté » avec le même timing
        // que showCheckmark. complete() sera appelé par showUnsupported
        // après son fondu de sortie.
        DispatchQueue.main.async { [weak self] in
            self?.showUnsupported()
        }

        guard isDebugEnabled else { return }

        log("⚠️ Aucun type supporté par le code — capture du payload :")
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        log("   inputItems.count = \(items.count)")

        for (itemIdx, item) in items.enumerated() {
            log("   ── Item #\(itemIdx) ──")
            log("     attributedTitle: \(item.attributedTitle?.string ?? "nil")")
            log("     attributedContentText: \(item.attributedContentText?.string ?? "nil")")
            if let userInfo = item.userInfo, !userInfo.isEmpty {
                log("     userInfo (\(userInfo.count) entries):")
                for (k, v) in userInfo {
                    log("       [\(k)] = \(v)")
                }
            } else {
                log("     userInfo: nil/empty")
            }

            let attachments = item.attachments ?? []
            log("     attachments.count = \(attachments.count)")

            for (attIdx, att) in attachments.enumerated() {
                log("     · Attachment #\(attIdx)")
                log("         suggestedName: \(att.suggestedName ?? "nil")")
                log("         registeredTypeIdentifiers: \(att.registeredTypeIdentifiers)")

                for typeId in att.registeredTypeIdentifiers {
                    att.loadItem(forTypeIdentifier: typeId, options: nil) { [weak self] data, error in
                        DispatchQueue.main.async {
                            self?.logLoadedPreview(typeIdentifier: typeId, data: data, error: error)
                        }
                    }
                }
            }
        }
    }

    /// Affiche un indicateur visuel « contenu non supporté » pendant ~1 s
    /// puis appelle complete(). Même rythme que showCheckmark(sourceApp:).
    private func showUnsupported() {
        let container = UIView()
        container.backgroundColor = UIColor.systemBackground
        container.layer.cornerRadius = 20
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.15
        container.layer.shadowRadius = 12
        container.translatesAutoresizingMaskIntoConstraints = false

        let imageView = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
        imageView.tintColor = .systemOrange
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = NSLocalizedString("Unsupported content", comment: "")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .label
        label.numberOfLines = 2
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imageView)
        container.addSubview(label)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            container.widthAnchor.constraint(equalToConstant: 240),
            container.heightAnchor.constraint(equalToConstant: 120),

            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            imageView.widthAnchor.constraint(equalToConstant: 36),
            imageView.heightAnchor.constraint(equalToConstant: 36),

            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
        ])

        container.alpha = 0
        UIView.animate(withDuration: 0.2) {
            container.alpha = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            UIView.animate(withDuration: 0.2, animations: {
                container.alpha = 0
            }) { _ in
                self?.complete()
            }
        }
    }

    private func logLoadedPreview(typeIdentifier: String, data: Any?, error: Error?) {
        if let error = error {
            log("         [\(typeIdentifier)] erreur: \(error.localizedDescription)")
            return
        }
        guard let data = data else {
            log("         [\(typeIdentifier)] data = nil")
            return
        }
        let typeStr = String(describing: type(of: data))
        switch data {
        case let url as URL:
            log("         [\(typeIdentifier)] URL (\(typeStr)): \(url.absoluteString)")
        case let str as String:
            let preview = String(str.prefix(300))
            log("         [\(typeIdentifier)] String (\(typeStr), len=\(str.count)): \(preview)")
        case let d as Data:
            let hex = d.prefix(32).map { String(format: "%02x", $0) }.joined()
            if let s = String(data: d.prefix(300), encoding: .utf8) {
                log("         [\(typeIdentifier)] Data (\(d.count) bytes, utf8): \(s)")
            } else {
                log("         [\(typeIdentifier)] Data (\(d.count) bytes, hex head): \(hex)")
            }
        case let image as UIImage:
            log("         [\(typeIdentifier)] UIImage size=\(image.size) scale=\(image.scale)")
        case let attr as NSAttributedString:
            log("         [\(typeIdentifier)] AttributedString (len=\(attr.length)): \(attr.string.prefix(300))")
        default:
            log("         [\(typeIdentifier)] \(typeStr): \(String(describing: data).prefix(300))")
        }
    }
    
    /// Détecte la source AVANT toute transformation de l'URL
    private func detectSourceBeforeTransform(_ urlString: String) -> String? {
        print("\n🔎 Detecting source from original URL: \(urlString)")
        
        // Méthode 1: Analyse des paramètres
        if let fromParams = analyzeURLParameters(urlString) {
            print("   ✓ Detected from params: \(fromParams)")
            return fromParams
        }
        
        // Méthode 2: Deviner depuis le domaine
        let guessed = guessSourceFromURL(urlString)
        print("   ✓ Guessed from domain: \(guessed)")
        return guessed
    }
    
    /// Récupère le nom de l'application source qui partage le contenu
    private func getSourceApplication() -> String? {
        print("\n🔍 Attempting to detect source application...")
        
        guard let extensionContext = extensionContext else {
            print("   ❌ No extension context")
            return nil
        }
        
        // Informations sur le context lui-même
        print("   Extension Context Info:")
        print("      Type: \(type(of: extensionContext))")
        
        // Méthode 1 : Via les user info de l'extension context
        if let item = extensionContext.inputItems.first as? NSExtensionItem {
            print("\n   📦 Examining NSExtensionItem:")
            
            if let userInfo = item.userInfo {
                print("      User Info Keys:")
                for (key, value) in userInfo {
                    print("         • \(key)")
                    print("           Type: \(type(of: value))")
                    print("           Value: \(value)")
                    
                    // Essayer de détecter des patterns connus
                    let keyString = String(describing: key)
                    if keyString.contains("source") || keyString.contains("Source") || 
                       keyString.contains("app") || keyString.contains("App") ||
                       keyString.contains("bundle") || keyString.contains("Bundle") {
                        print("           ⚠️ POTENTIALLY USEFUL KEY!")
                    }
                }
                
                // Chercher des clés spécifiques
                if let sourceAppIdentifier = userInfo["NSExtensionItemAttributedContentTextKey"] as? String {
                    print("      ✅ Found NSExtensionItemAttributedContentTextKey: \(sourceAppIdentifier)")
                    return sourceAppIdentifier
                }
            } else {
                print("      ℹ️ No userInfo dictionary")
            }
            
            // Essayer via l'attributedContentText
            if let contentText = item.attributedContentText {
                print("\n      📝 Attributed Content Text:")
                print("         String: \(contentText.string)")
                if contentText.length > 0 {
                    print("         Length: \(contentText.length)")
                    var range = NSRange(location: 0, length: contentText.length)
                    let attrs = contentText.attributes(at: 0, effectiveRange: &range)
                    print("         Attributes:")
                    for (attrKey, attrValue) in attrs {
                        print("            • \(attrKey): \(attrValue)")
                    }
                }
            }
            
            // Essayer via l'attributedTitle
            if let title = item.attributedTitle {
                print("\n      📌 Attributed Title:")
                print("         String: \(title.string)")
                if title.length > 0 {
                    print("         Length: \(title.length)")
                    var range = NSRange(location: 0, length: title.length)
                    let attrs = title.attributes(at: 0, effectiveRange: &range)
                    print("         Attributes:")
                    for (attrKey, attrValue) in attrs {
                        print("            • \(attrKey): \(attrValue)")
                    }
                }
            }
        }
        
        print("\n   ⚠️ Source app identifier not directly available (iOS privacy)")
        return nil
    }
    
    /// Devine l'application source basée sur l'URL partagée
    /// Cette méthode ne peut identifier que le service web, pas l'app iOS spécifique
    private func guessSourceFromURL(_ urlString: String) -> String {
        let url = urlString.lowercased()
        
        // Services de vidéo
        if url.contains("youtube.com") || url.contains("youtu.be") {
            return "YouTube"
        }
        if url.contains("vimeo.com") {
            return "Vimeo"
        }
        if url.contains("dailymotion.com") {
            return "Dailymotion"
        }
        
        // Réseaux sociaux
        if url.contains("twitter.com") || url.contains("x.com") {
            return "Twitter/X"
        }
        if url.contains("facebook.com") || url.contains("fb.com") {
            return "Facebook"
        }
        if url.contains("instagram.com") {
            return "Instagram"
        }
        if url.contains("linkedin.com") {
            return "LinkedIn"
        }
        if url.contains("reddit.com") {
            return "Reddit"
        }
        if url.contains("tiktok.com") {
            return "TikTok"
        }
        
        // Services de messagerie
        if url.contains("whatsapp.com") {
            return "WhatsApp"
        }
        if url.contains("telegram.org") || url.contains("t.me") {
            return "Telegram"
        }
        
        // Médias et actualités
        if url.contains("medium.com") {
            return "Medium"
        }
        if url.contains("substack.com") {
            return "Substack"
        }
        
        // Services Apple
        if url.contains("apple.com") {
            return "Apple"
        }
        
        // Navigateurs (difficile à détecter, mais on peut essayer avec des patterns)
        if url.contains("google.com") || url.contains("google.fr") {
            return "Google/Web"
        }
        
        // Services de musique
        if url.contains("spotify.com") {
            return "Spotify"
        }
        if url.contains("music.apple.com") {
            return "Apple Music"
        }
        if url.contains("soundcloud.com") {
            return "SoundCloud"
        }
        
        // Shopping
        if url.contains("amazon.com") || url.contains("amazon.fr") {
            return "Amazon"
        }
        
        // Autres
        if url.contains("github.com") {
            return "GitHub"
        }
        if url.contains("stackoverflow.com") {
            return "Stack Overflow"
        }
        
        // Si aucune correspondance, essayer d'extraire le domaine
        if let domain = extractDomain(from: urlString) {
            return domain.capitalized
        }
        
        return "Web Browser"
    }
    
    /// Extrait le domaine principal d'une URL
    private func extractDomain(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host else {
            return nil
        }
        
        // Enlever "www." et prendre le domaine principal
        let components = host.components(separatedBy: ".")
        if components.count >= 2 {
            // Prendre l'avant-dernier composant (ex: "google" dans "www.google.com")
            return components[components.count - 2]
        }
        
        return host
    }

    private func transform(urlString: String) -> String {
        for prefix in ["https://www.youtube.com", "https://youtube.com"] {
            if urlString.hasPrefix(prefix) {
                return "https://www.yout-ube.com" + urlString.dropFirst(prefix.count)
            }
        }
        let shortPrefix = "https://youtu.be/"
        if urlString.hasPrefix(shortPrefix) {
            return "https://www.yout-ube.com/watch?v=\(urlString.dropFirst(shortPrefix.count))"
        }
        return urlString
    }
    
    /// Récupère le titre d'une page web depuis son URL
    private func fetchTitleFromURL(_ urlString: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: urlString) else {
            print("   ❌ Invalid URL for title fetching")
            completion(nil)
            return
        }
        
        // Pour YouTube, utiliser l'API oEmbed qui est plus fiable
        if urlString.contains("youtube.com") || urlString.contains("youtu.be") {
            fetchYouTubeTitleFromOEmbed(urlString, completion: completion)
            return
        }
        
        print("   🌐 Fetching title from: \(urlString)")
        logger.info("🌐 Fetching title from original URL: \(urlString)")
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                print("   ❌ Error fetching title: \(error.localizedDescription)")
                self.logger.error("❌ Error fetching title: \(error.localizedDescription)")
                completion(nil)
                return
            }
            
            guard let data = data,
                  let html = String(data: data, encoding: .utf8) else {
                print("   ❌ Could not decode HTML")
                self.logger.error("❌ Could not decode HTML data")
                completion(nil)
                return
            }
            
            // Extraire le titre avec regex
            if let match = html.range(of: "<title[^>]*>([^<]+)</title>", options: .regularExpression) {
                let tag = html[match]
                if let start = tag.firstIndex(of: ">"),
                   let end = tag.range(of: "</title>") {
                    let title = tag[tag.index(after: start)..<end.lowerBound]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if !title.isEmpty {
                        print("   ✅ Title fetched from HTML: \(title)")
                        self.logger.info("✅ Title fetched from HTML: \(title)")
                        completion(String(title))
                        return
                    }
                }
            }
            
            print("   ⚠️ No title found in HTML")
            self.logger.warning("⚠️ No <title> tag found in HTML")
            completion(nil)
        }
        
        task.resume()
    }
    
    /// Récupère le titre d'une vidéo YouTube via l'API oEmbed
    private func fetchYouTubeTitleFromOEmbed(_ urlString: String, completion: @escaping (String?) -> Void) {
        // Construire l'URL oEmbed
        let encodedURL = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString
        let oembedURLString = "https://www.youtube.com/oembed?url=\(encodedURL)&format=json"
        
        guard let oembedURL = URL(string: oembedURLString) else {
            print("   ❌ Invalid oEmbed URL")
            completion(nil)
            return
        }
        
        print("   🎬 Fetching YouTube title from oEmbed API...")
        logger.info("🎬 Fetching YouTube title from oEmbed: \(oembedURLString)")
        
        let task = URLSession.shared.dataTask(with: oembedURL) { data, response, error in
            if let error = error {
                print("   ❌ Error fetching from oEmbed: \(error.localizedDescription)")
                self.logger.error("❌ oEmbed error: \(error.localizedDescription)")
                completion(nil)
                return
            }
            
            guard let data = data else {
                print("   ❌ No data from oEmbed")
                completion(nil)
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let title = json["title"] as? String {
                    print("   ✅ YouTube title from oEmbed: \(title)")
                    self.logger.info("✅ YouTube title from oEmbed: \(title)")
                    completion(title)
                } else {
                    print("   ⚠️ No title in oEmbed response")
                    self.logger.warning("⚠️ No title field in oEmbed JSON")
                    completion(nil)
                }
            } catch {
                print("   ❌ Error parsing oEmbed JSON: \(error.localizedDescription)")
                self.logger.error("❌ JSON parse error: \(error.localizedDescription)")
                completion(nil)
            }
        }
        
        task.resume()
    }

    /// Lit les tags GPS EXIF d'une image et renvoie (lat, lon) signés en
    /// degrés décimaux. Nil si l'image n'a pas de GPS ou si la lecture échoue.
    static func readGPS(from fileURL: URL) -> (lat: Double, lon: Double)? {
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              var lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
              var lon = gps[kCGImagePropertyGPSLongitude as String] as? Double else {
            return nil
        }
        if let ref = gps[kCGImagePropertyGPSLatitudeRef as String] as? String, ref.uppercased() == "S" {
            lat = -lat
        }
        if let ref = gps[kCGImagePropertyGPSLongitudeRef as String] as? String, ref.uppercased() == "W" {
            lon = -lon
        }
        return (lat, lon)
    }

    private func save(urlString: String, sourceApp: String?, pageTitle: String?, kind: String = "url", modifiedAt: Double? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        guard let defaults = UserDefaults(suiteName: appGroup) else {
            print("❌ ERROR: Cannot access UserDefaults for app group: \(appGroup)")
            print("   Make sure App Groups capability is enabled in both targets!")
            return
        }

        let finalSource: String
        if let sourceApp = sourceApp {
            finalSource = sourceApp
        } else if kind == "url", let fromParams = analyzeURLParameters(urlString) {
            finalSource = fromParams
        } else if kind == "url" {
            finalSource = guessSourceFromURL(urlString)
        } else {
            finalSource = "Share"
        }

        // Charger la liste d'items existante (format JSON).
        var items: [[String: Any]] = []
        if let data = defaults.data(forKey: "items"),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            items = arr
        }

        let now = Date().timeIntervalSince1970
        var newItem: [String: Any] = [
            "id": UUID().uuidString,
            "url": urlString,
            "sourceApp": finalSource,
            "folder": "Default",
            "timestamp": now,
            "kind": kind,
        ]
        if let title = pageTitle, !title.isEmpty {
            newItem["title"] = title
        }
        // Pour les fichiers ET les photos, si on a réussi à lire la date on
        // l'utilise, sinon on tombe sur "now". Pour les textes : "now".
        // Pour les URLs, modifiedAt reste absent — l'app ira le chercher.
        if kind == "file" || kind == "photo" || kind == "video" {
            newItem["modifiedAt"] = modifiedAt ?? now
        } else if kind == "text" {
            newItem["modifiedAt"] = now
        }

        // Métadonnées GPS (photos uniquement).
        if let latitude = latitude { newItem["latitude"] = latitude }
        if let longitude = longitude { newItem["longitude"] = longitude }

        items.insert(newItem, at: 0)

        if let data = try? JSONSerialization.data(withJSONObject: items) {
            defaults.set(data, forKey: "items")
            defaults.synchronize()
            print("✅ Item saved (kind=\(kind)) in folder Default")
            logger.info("✅ Item saved (kind=\(kind))")
        } else {
            print("❌ Failed to serialize items array")
            logger.error("❌ Failed to serialize items array")
        }
    }
    
    /// Analyse les paramètres d'URL pour identifier l'app source
    /// Cette méthode est très efficace car beaucoup d'apps ajoutent des paramètres spécifiques
    private func analyzeURLParameters(_ urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }
        
        for item in queryItems {
            let name = item.name.lowercased()
            
            // Instagram utilise "igshid" ou "igsh"
            if name == "igshid" || name == "igsh" {
                return "Instagram"
            }
            
            // Facebook utilise "fbclid"
            if name == "fbclid" {
                return "Facebook"
            }
            
            // Twitter utilise parfois "s" ou "t" avec twitter.com
            if (name == "s" || name == "t") {
                if let host = url.host, (host.contains("twitter.com") || host.contains("x.com")) {
                    return "Twitter/X"
                }
            }
            
            // TikTok utilise "is_from_webapp"
            if name == "is_from_webapp" || name == "is_copy_url" {
                return "TikTok"
            }
            
            // LinkedIn utilise "trk"
            if name == "trk" {
                return "LinkedIn"
            }
            
            // Reddit utilise "context" ou "share_id"
            if (name == "context" || name == "share_id") {
                if let host = url.host, host.contains("reddit.com") {
                    return "Reddit"
                }
            }
            
            // YouTube utilise "feature" avec différentes valeurs
            if name == "feature" {
                if let host = url.host, (host.contains("youtube.com") || host.contains("youtu.be")) {
                    if let value = item.value?.lowercased() {
                        if value == "share" || value == "youtu.be" {
                            return "YouTube"
                        }
                    }
                }
            }
            
            // WhatsApp Web
            if name == "text" {
                if let host = url.host, host.contains("whatsapp.com") {
                    return "WhatsApp"
                }
            }
            
            // Telegram
            if name == "url" {
                if let host = url.host, host.contains("t.me") {
                    return "Telegram"
                }
            }
        }
        
        return nil
    }

    private func showCheckmark(sourceApp: String?) {
        let container = UIView()
        container.backgroundColor = UIColor.systemBackground
        container.layer.cornerRadius = 20
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.15
        container.layer.shadowRadius = 12
        container.translatesAutoresizingMaskIntoConstraints = false

        let imageView = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        imageView.tintColor = .systemGreen
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = NSLocalizedString("URL saved", comment: "")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        
        // Ajouter un label pour l'app source si disponible
        let sourceLabel = UILabel()
        if let sourceApp = sourceApp {
            sourceLabel.text = "From: \(sourceApp)"
        } else {
            sourceLabel.text = "Source: Unknown"
        }
        sourceLabel.font = .systemFont(ofSize: 11, weight: .regular)
        sourceLabel.textColor = .secondaryLabel
        sourceLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imageView)
        container.addSubview(label)
        container.addSubview(sourceLabel)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            container.widthAnchor.constraint(equalToConstant: 220),
            container.heightAnchor.constraint(equalToConstant: 120),

            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            imageView.widthAnchor.constraint(equalToConstant: 36),
            imageView.heightAnchor.constraint(equalToConstant: 36),

            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),
            
            sourceLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            sourceLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
        ])

        container.alpha = 0
        UIView.animate(withDuration: 0.2) {
            container.alpha = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            UIView.animate(withDuration: 0.2, animations: {
                container.alpha = 0
            }) { _ in
                self?.complete()
            }
        }
    }

    private func complete() {
        print("\n✅ Share Extension completing...")
        print(String(repeating: "=", count: 80) + "\n")
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Copie un fichier fourni par une app source (souvent via File Provider)
    /// dans le conteneur de l'App Group afin qu'il survive à la fermeture de
    /// l'extension et puisse être rouvert plus tard par l'app principale.
    /// Le nom de destination est préfixé d'un timestamp pour éviter les
    /// collisions tout en préservant l'extension d'origine.
    private func copyFileToAppGroup(originalURL: URL) -> URL? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            log("❌ copyFileToAppGroup: containerURL introuvable")
            return nil
        }
        let dir = containerURL.appendingPathComponent("SharedFiles", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log("❌ copyFileToAppGroup: createDirectory échec: \(error.localizedDescription)")
            return nil
        }

        let didStart = originalURL.startAccessingSecurityScopedResource()
        defer { if didStart { originalURL.stopAccessingSecurityScopedResource() } }

        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let name = originalURL.lastPathComponent
        let destName = "\(ts)_\(name)"
        let destURL = dir.appendingPathComponent(destName)

        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: originalURL, to: destURL)
            return destURL
        } catch {
            log("❌ copyFileToAppGroup: copyItem échec: \(error.localizedDescription)")
            // Fallback: lire puis écrire (utile si la copie directe échoue
            // à cause d'un accès sandbox particulier).
            if let data = try? Data(contentsOf: originalURL) {
                do {
                    try data.write(to: destURL, options: .atomic)
                    return destURL
                } catch {
                    log("❌ copyFileToAppGroup: write fallback échec: \(error.localizedDescription)")
                }
            }
            return nil
        }
    }
    
    // MARK: - Advanced Data Type Discovery
    
    /// Explore tous les types de données disponibles dans les attachments
    private func exploreAllDataTypes() {
        print("\n" + String(repeating: "=", count: 80))
        print("🔬 EXPLORING ALL POSSIBLE DATA TYPES")
        print(String(repeating: "=", count: 80))
        
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else {
            print("❌ No attachments to explore")
            return
        }
        
        let commonTypes: [(UTType, String)] = [
            // URLs et texte
            (.url, "URL"), (.plainText, "Plain Text"), (.utf8PlainText, "UTF-8 Text"), (.utf16PlainText, "UTF-16 Text"),
            
            // Images
            (.image, "Image"), (.png, "PNG"), (.jpeg, "JPEG"), (.heic, "HEIC"), (.gif, "GIF"), (.bmp, "BMP"), (.tiff, "TIFF"),
            
            // Vidéos
            (.movie, "Movie"), (.video, "Video"), (.mpeg4Movie, "MPEG-4 Movie"), (.quickTimeMovie, "QuickTime Movie"),
            
            // Audio
            (.audio, "Audio"), (.mp3, "MP3"), (.mpeg4Audio, "MPEG-4 Audio"),
            
            // Documents
            (.pdf, "PDF"), (.rtf, "RTF"), (.html, "HTML"),
            
            // Data
            (.data, "Data"), (.json, "JSON"), (.xml, "XML"),
            
            // Contact
            (.vCard, "vCard"), (.contact, "Contact"),
            
            // Autres
            (.fileURL, "File URL"), (.folder, "Folder"), (.item, "Item")
        ]
        
        for (index, attachment) in attachments.enumerated() {
            print("\n┌─ Attachment #\(index + 1) Type Discovery")
            print("│")
            
            for (type, description) in commonTypes {
                if attachment.hasItemConformingToTypeIdentifier(type.identifier) {
                    print("│  ✅ HAS: \(type.identifier)")
                    print("│     Description: \(description)")
                    
                    // Essayer de charger le contenu
                    attachment.loadItem(forTypeIdentifier: type.identifier, options: nil) { [weak self] data, error in
                        DispatchQueue.main.async {
                            self?.logLoadedData(typeIdentifier: type.identifier, data: data, error: error)
                        }
                    }
                } else {
                    print("│  ❌ NO: \(type.identifier)")
                }
            }
            
            print("│")
            print("│  🔍 Registered Type Identifiers:")
            for registeredType in attachment.registeredTypeIdentifiers {
                print("│     • \(registeredType)")
            }
            
            print("└" + String(repeating: "─", count: 78))
        }
        
        print(String(repeating: "=", count: 80) + "\n")
    }
    
    /// Log les données chargées pour un type spécifique
    private func logLoadedData(typeIdentifier: String, data: Any?, error: Error?) {
        print("\n   📦 LOADED DATA for \(typeIdentifier):")
        
        if let error = error {
            print("      ❌ Error: \(error.localizedDescription)")
            return
        }
        
        guard let data = data else {
            print("      ⚠️ Data is nil")
            return
        }
        
        print("      Type: \(type(of: data))")
        
        // Analyser selon le type de données
        switch data {
        case let url as URL:
            print("      ✅ URL: \(url.absoluteString)")
            print("         Scheme: \(url.scheme ?? "N/A")")
            print("         Host: \(url.host ?? "N/A")")
            print("         Path: \(url.path)")
            print("         Query: \(url.query ?? "N/A")")
            
        case let string as String:
            print("      ✅ String: \(string.prefix(200))...")
            print("         Length: \(string.count)")
            print("         Is URL?: \(URL(string: string) != nil)")
            
        case let data as Data:
            print("      ✅ Data:")
            print("         Size: \(data.count) bytes")
            // Essayer de convertir en string
            if let string = String(data: data, encoding: .utf8) {
                print("         UTF-8: \(string.prefix(100))...")
            }
            // Essayer de convertir en JSON
            if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
                print("         JSON: \(json)")
            }
            
        case let image as UIImage:
            print("      ✅ UIImage:")
            print("         Size: \(image.size)")
            print("         Scale: \(image.scale)")
            
        case let attributedString as NSAttributedString:
            print("      ✅ NSAttributedString:")
            print("         String: \(attributedString.string)")
            print("         Length: \(attributedString.length)")
            
        default:
            print("      ⚠️ Unknown data type: \(type(of: data))")
            print("         Value: \(data)")
        }
    }
}
