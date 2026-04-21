import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    let appGroup = "group.net.fenyo.apple.sharemanager"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.0)
        print("🎬 ShareViewController viewDidLoad() called")
        print("   Bundle ID: \(Bundle.main.bundleIdentifier ?? "N/A")")
        print("   Extension Context: \(extensionContext != nil ? "✅ Available" : "❌ Not available")")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        print("🎬 ShareViewController viewDidAppear() called")
        print("   Extension Context Available: \(extensionContext != nil)")
        
        // Explorer TOUS les types de données disponibles (pour debugging/découverte)
        exploreAllDataTypes()
        
        // Puis extraire et sauvegarder comme d'habitude
        extractAndSaveURL()
    }

    private func extractAndSaveURL() {
        print("\n" + String(repeating: "=", count: 80))
        print("🚀 SHARE EXTENSION ACTIVATED")
        print(String(repeating: "=", count: 80))
        
        guard let extensionContext = extensionContext else {
            print("❌ No extension context available")
            complete()
            return
        }
        
        // ===== INSPECTION COMPLÈTE DE L'EXTENSION CONTEXT =====
        print("\n📦 EXTENSION CONTEXT INFO:")
        print("   Input Items Count: \(extensionContext.inputItems.count)")
        
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
            complete()
            return
        }
        
        // Récupérer l'app source qui partage le contenu
        let sourceApp = getSourceApplication()

        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                print("✅ Found URL type identifier")
                attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] data, error in
                    print("\n📥 URL DATA LOADED:")
                    print("   Data Type: \(type(of: data))")
                    print("   Error: \(error?.localizedDescription ?? "None")")
                    
                    var urlString: String?
                    if let url = data as? URL {
                        urlString = url.absoluteString
                        print("   ✅ URL Object: \(urlString!)")
                    } else if let str = data as? String, URL(string: str) != nil {
                        urlString = str
                        print("   ✅ String URL: \(urlString!)")
                    }
                    
                    if let urlString = urlString {
                        // IMPORTANT: Détecter la source AVANT la transformation
                        let detectedSource = self?.detectSourceBeforeTransform(urlString) ?? sourceApp
                        let transformedURL = self?.transform(urlString: urlString) ?? urlString
                        
                        print("   📊 URL Processing:")
                        print("      Original: \(urlString)")
                        print("      Transformed: \(transformedURL)")
                        print("      Source: \(detectedSource ?? "Unknown")")
                        
                        self?.save(urlString: transformedURL, sourceApp: detectedSource)
                        
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
                attachment.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] data, error in
                    print("\n📥 PLAIN TEXT DATA LOADED:")
                    print("   Data Type: \(type(of: data))")
                    print("   Error: \(error?.localizedDescription ?? "None")")
                    
                    var urlString: String?
                    if let str = data as? String, URL(string: str) != nil {
                        urlString = str
                        print("   ✅ Text contains URL: \(urlString!)")
                    }
                    
                    if let urlString = urlString {
                        // IMPORTANT: Détecter la source AVANT la transformation
                        let detectedSource = self?.detectSourceBeforeTransform(urlString) ?? sourceApp
                        let transformedURL = self?.transform(urlString: urlString) ?? urlString
                        
                        print("   📊 URL Processing:")
                        print("      Original: \(urlString)")
                        print("      Transformed: \(transformedURL)")
                        print("      Source: \(detectedSource ?? "Unknown")")
                        
                        self?.save(urlString: transformedURL, sourceApp: detectedSource)
                        
                        DispatchQueue.main.async {
                            self?.showCheckmark(sourceApp: detectedSource)
                        }
                    }
                }
                return
            }
        }

        print("⚠️  No URL or Plain Text found in attachments")
        complete()
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

    private func save(urlString: String, sourceApp: String?) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        var urls = defaults.stringArray(forKey: "sharedURLs") ?? []
        if !urls.contains(urlString) {
            urls.insert(urlString, at: 0)
        }
        defaults.set(urls, forKey: "sharedURLs")
        
        // Déterminer la source avec plusieurs méthodes
        let finalSource: String
        if let sourceApp = sourceApp {
            // Méthode 1 : Détection directe via iOS (rare)
            finalSource = sourceApp
            print("✅ URL saved from (detected): \(sourceApp)")
        } else if let fromParams = analyzeURLParameters(urlString) {
            // Méthode 2 : Analyse des paramètres d'URL (très fiable)
            finalSource = fromParams
            print("🔍 URL saved from (params): \(fromParams)")
        } else {
            // Méthode 3 : Deviner depuis le domaine (fallback)
            finalSource = guessSourceFromURL(urlString)
            print("🔍 URL saved from (guessed): \(finalSource)")
        }
        
        // Sauvegarder l'app source
        var sourceApps = defaults.dictionary(forKey: "sourceApps") as? [String: String] ?? [:]
        sourceApps[urlString] = finalSource
        defaults.set(sourceApps, forKey: "sourceApps")
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
