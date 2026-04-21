# 🔍 Guide Avancé : Améliorer la Détection de Source

## Méthodes avancées pour identifier l'app source

### 1. 🎯 Analyse des User-Agent (si disponible)

Certaines apps incluent parfois un User-Agent dans les métadonnées partagées :

```swift
private func checkUserAgent() -> String? {
    guard let item = extensionContext?.inputItems.first as? NSExtensionItem else {
        return nil
    }
    
    // Chercher dans userInfo
    if let userInfo = item.userInfo,
       let userAgent = userInfo["User-Agent"] as? String {
        return parseUserAgent(userAgent)
    }
    
    return nil
}

private func parseUserAgent(_ userAgent: String) -> String? {
    // Exemples de User-Agents
    if userAgent.contains("Instagram") {
        return "Instagram"
    }
    if userAgent.contains("FB") || userAgent.contains("Facebook") {
        return "Facebook"
    }
    if userAgent.contains("Twitter") {
        return "Twitter"
    }
    return nil
}
```

### 2. 📋 Analyse du Clipboard (avec permission)

Si l'utilisateur a copié l'URL avant de la partager :

```swift
import UIKit

private func checkClipboard() -> String? {
    let pasteboard = UIPasteboard.general
    
    // Vérifier si le clipboard contient des métadonnées
    if let items = pasteboard.items.first {
        for (key, value) in items {
            print("Clipboard key: \(key), value: \(value)")
        }
    }
    
    return nil
}
```

**⚠️ Attention** : Cela nécessite des permissions et peut poser des problèmes de confidentialité.

### 3. 🕐 Pattern de timing

Analyser le temps entre les partages pour détecter des patterns :

```swift
struct ShareEvent {
    let url: String
    let timestamp: Date
    let source: String?
}

private func analyzeSharePattern(_ events: [ShareEvent]) -> String? {
    // Si plusieurs partages rapides du même domaine,
    // c'est probablement une app native
    let recentEvents = events.filter { 
        Date().timeIntervalSince($0.timestamp) < 60 
    }
    
    if recentEvents.count >= 2 {
        let domains = recentEvents.compactMap { extractDomain(from: $0.url) }
        let uniqueDomains = Set(domains)
        
        if uniqueDomains.count == 1 {
            // Probablement l'app native de ce service
            return uniqueDomains.first
        }
    }
    
    return nil
}
```

### 4. 📊 Machine Learning (avancé)

Créer un modèle ML qui apprend des patterns :

```swift
import CoreML
import CreateML

// Entrainer un modèle avec :
// - Patterns d'URL
// - Temps de partage
// - Métadonnées disponibles
// - Comportement utilisateur

// Exemple simplifié :
struct ShareFeatures {
    let urlLength: Int
    let hasMobileParam: Bool
    let hasAppParam: Bool
    let timeOfDay: Int
    let dayOfWeek: Int
}

private func predictSource(from features: ShareFeatures) -> String {
    // Utiliser CoreML pour prédire
    // Basé sur des données d'entrainement
    return "PredictedSource"
}
```

### 5. 🌐 Analyse des paramètres d'URL

Beaucoup d'apps ajoutent des paramètres spécifiques :

```swift
private func analyzeURLParameters(_ urlString: String) -> String? {
    guard let url = URL(string: urlString),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let queryItems = components.queryItems else {
        return nil
    }
    
    for item in queryItems {
        // Instagram utilise souvent "igshid"
        if item.name == "igshid" {
            return "Instagram"
        }
        
        // Facebook utilise "fbclid"
        if item.name == "fbclid" {
            return "Facebook"
        }
        
        // Twitter utilise parfois "s" ou "t"
        if item.name == "s" && url.host?.contains("twitter.com") == true {
            return "Twitter"
        }
        
        // TikTok utilise "is_from_webapp"
        if item.name == "is_from_webapp" {
            return "TikTok"
        }
        
        // LinkedIn utilise "trk"
        if item.name == "trk" {
            return "LinkedIn"
        }
        
        // Reddit utilise "context"
        if item.name == "context" && url.host?.contains("reddit.com") == true {
            return "Reddit"
        }
        
        // YouTube utilise "feature"
        if item.name == "feature" && url.host?.contains("youtube.com") == true {
            if let value = item.value {
                if value == "share" {
                    return "YouTube App"
                }
            }
        }
    }
    
    return nil
}
```

### 6. 🔗 Analyse des UTM parameters

Les paramètres marketing peuvent révéler la source :

```swift
private func analyzeUTMParameters(_ urlString: String) -> String? {
    guard let url = URL(string: urlString),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let queryItems = components.queryItems else {
        return nil
    }
    
    // Chercher utm_source
    if let utmSource = queryItems.first(where: { $0.name == "utm_source" })?.value {
        return utmSource.capitalized
    }
    
    // Chercher utm_medium
    if let utmMedium = queryItems.first(where: { $0.name == "utm_medium" })?.value {
        if utmMedium == "ios" || utmMedium == "app" {
            return "Mobile App"
        }
    }
    
    return nil
}
```

### 7. 🎨 Analyse du Referrer (rarement disponible)

```swift
private func checkReferrer() -> String? {
    guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
          let userInfo = item.userInfo,
          let referrer = userInfo["Referer"] as? String ?? userInfo["Referrer"] as? String else {
        return nil
    }
    
    // Analyser le referrer
    if let url = URL(string: referrer) {
        return extractDomain(from: url.absoluteString)
    }
    
    return nil
}
```

## 🔄 Fonction combinée optimale

Voici comment combiner toutes ces méthodes :

```swift
private func detectSourceApp(from urlString: String) -> String {
    // 1. Essayer la détection directe iOS (rarement disponible)
    if let direct = getSourceApplication() {
        return direct
    }
    
    // 2. Analyser les paramètres d'URL (très fiable)
    if let fromParams = analyzeURLParameters(urlString) {
        return fromParams
    }
    
    // 3. Analyser les UTM (si présent)
    if let fromUTM = analyzeUTMParameters(urlString) {
        return fromUTM
    }
    
    // 4. Deviner depuis le domaine (fallback fiable)
    return guessSourceFromURL(urlString)
}
```

## 📈 Statistiques et apprentissage

Collecter des données pour améliorer la détection :

```swift
struct SourceDetectionStats {
    var successRate: [String: Int] = [:]
    var failureCount: Int = 0
    
    mutating func recordSuccess(method: String) {
        successRate[method, default: 0] += 1
    }
    
    mutating func recordFailure() {
        failureCount += 1
    }
    
    var bestMethod: String? {
        successRate.max(by: { $0.value < $1.value })?.key
    }
}
```

## 🎯 Recommandations

### Pour la meilleure précision :

1. ✅ **Toujours** implémenter `analyzeURLParameters()` (très efficace)
2. ✅ **Toujours** implémenter `guessSourceFromURL()` (bon fallback)
3. ⚠️ **Optionnel** : UTM analysis si vous trackez du marketing
4. ❌ **Éviter** : Clipboard analysis (problèmes de confidentialité)
5. ❌ **Éviter** : ML pour un cas simple (overkill)

### Code recommandé à ajouter :

Ajoutez `analyzeURLParameters()` à votre `ShareViewController.swift` et modifiez `save()` :

```swift
private func save(urlString: String, sourceApp: String?) {
    // ...
    
    let finalSource: String
    if let sourceApp = sourceApp {
        finalSource = sourceApp
    } else if let fromParams = analyzeURLParameters(urlString) {
        finalSource = fromParams
        print("🔍 Detected from URL params: \(fromParams)")
    } else {
        finalSource = guessSourceFromURL(urlString)
        print("🔍 Guessed from domain: \(finalSource)")
    }
    
    // ...
}
```

## 🧪 Test et Validation

Pour tester votre détection :

```swift
// Tests unitaires
func testSourceDetection() {
    // Instagram
    assert(analyzeURLParameters("https://instagram.com/p/xxx?igshid=xxx") == "Instagram")
    
    // Facebook
    assert(analyzeURLParameters("https://facebook.com/post?fbclid=xxx") == "Facebook")
    
    // YouTube avec feature=share
    assert(analyzeURLParameters("https://youtube.com/watch?v=xxx&feature=share") == "YouTube App")
}
```

---

**💡 Astuce** : Activez les logs dans la console Xcode pour voir les métadonnées réellement disponibles lors du partage, cela vous aidera à affiner la détection pour vos cas d'usage spécifiques.
