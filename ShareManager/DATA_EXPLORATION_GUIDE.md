# 🔬 Guide d'Exploration des Données Partagées

## 🎯 Objectif

Ce guide explique comment utiliser les nouveaux logs détaillés pour découvrir **tous les types de données** que votre Share Extension peut recevoir.

## 📊 Ce qui a été modifié

### 1. Logs détaillés complets

Maintenant, lorsque quelque chose est partagé avec votre app, vous verrez dans la console Xcode :

```
================================================================================
🚀 SHARE EXTENSION ACTIVATED
================================================================================

📦 EXTENSION CONTEXT INFO:
   Input Items Count: 1

┌─ Input Item #1
│
│  📄 BASIC INFO:
│     Type: NSExtensionItem
│     Attachments Count: 1
│
│  📌 ATTRIBUTED TITLE:
│     String: Page Title
│     Length: 10
│     Attributes: [...]
│
│  📝 ATTRIBUTED CONTENT TEXT:
│     String: Some content
│     Length: 12
│     Attributes: [...]
│
│  🔍 USER INFO:
│     [key1]: value1
│        Type: String
│     [key2]: value2
│        Type: Dictionary
│
│  📎 ATTACHMENTS: 1 item(s)
│
│  ├─ Attachment #1
│  │  Type: NSItemProvider
│  │  Registered Type Identifiers:
│  │     • public.url
│  │     • public.plain-text
└────────────────────────────────────────────────────────────────────────────

================================================================================
🔬 EXPLORING ALL POSSIBLE DATA TYPES
================================================================================

┌─ Attachment #1 Type Discovery
│
│  ✅ HAS: public.url
│     Description: URL
│  ❌ NO: public.plain-text
│  ✅ HAS: public.image
│     Description: image
│  ❌ NO: public.jpeg
│  ...
│
│  🔍 Registered Type Identifiers:
│     • public.url
│     • public.file-url
│     • com.apple.property-list
└────────────────────────────────────────────────────────────────────────────

   📦 LOADED DATA for public.url:
      Type: URL
      ✅ URL: https://example.com/page
         Scheme: https
         Host: example.com
         Path: /page
         Query: param=value

================================================================================
🔍 STARTING DATA EXTRACTION
================================================================================
```

## 🔍 Types de données explorés

### URLs et Texte
- `public.url` - URLs
- `public.plain-text` - Texte simple
- `public.utf8-plain-text` - Texte UTF-8
- `public.utf16-plain-text` - Texte UTF-16

### Images
- `public.image` - Images génériques
- `public.png` - PNG
- `public.jpeg` - JPEG
- `public.heic` - HEIC (iOS)
- `public.gif` - GIF animé
- `public.bmp` - Bitmap
- `public.tiff` - TIFF

### Vidéos
- `public.movie` - Vidéos génériques
- `public.video` - Vidéos
- `public.mpeg-4` - MP4
- `com.apple.quicktime-movie` - QuickTime

### Audio
- `public.audio` - Audio générique
- `public.mp3` - MP3
- `public.mpeg-4-audio` - AAC/M4A

### Documents
- `com.adobe.pdf` - PDF
- `public.rtf` - Rich Text Format
- `public.html` - HTML

### Données structurées
- `public.data` - Données binaires
- `public.json` - JSON
- `public.xml` - XML

### Contact
- `public.vcard` - vCard
- `public.contact` - Contact

### Autres
- `public.file-url` - URL de fichier
- `public.folder` - Dossier
- `public.item` - Item générique

## 📋 Comment utiliser ces informations

### 1. Lancer l'app en mode Debug

```bash
# Dans Xcode:
1. Sélectionnez votre Share Extension comme cible
2. Lancez sur simulateur ou appareil
3. Ouvrez la Console (View > Debug Area > Activate Console)
```

### 2. Partager différents types de contenu

Testez avec :
- 📱 Safari → Partager une page web
- 📷 Photos → Partager une image
- 🎬 Vidéos → Partager une vidéo
- 📄 Fichiers → Partager un document PDF
- 📧 Mail → Partager un lien
- 💬 Messages → Partager du texte

### 3. Analyser les logs

Cherchez dans les logs :

#### Pour découvrir les types disponibles :
```
✅ HAS: public.image
✅ HAS: public.jpeg
```

#### Pour voir le contenu réel :
```
📦 LOADED DATA for public.url:
   Type: URL
   ✅ URL: https://example.com
```

#### Pour identifier la source :
```
🔎 Detecting source from original URL: https://youtube.com/watch?v=xxx
   ✓ Detected from params: YouTube
```

## 🛠️ Implémenter des traitements spécifiques

### Exemple 1 : Traiter les images

Une fois que vous avez vu `public.image` dans les logs, ajoutez :

```swift
// Dans extractAndSaveURL(), ajouter après le traitement des URLs:

for attachment in attachments {
    if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        attachment.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] data, error in
            if let image = data as? UIImage {
                print("📷 Image received: \(image.size)")
                // Sauvegarder l'image, l'uploader, etc.
                self?.handleImage(image)
            }
        }
        return
    }
}
```

### Exemple 2 : Traiter les PDFs

```swift
for attachment in attachments {
    if attachment.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
        attachment.loadItem(forTypeIdentifier: UTType.pdf.identifier, options: nil) { [weak self] data, error in
            if let url = data as? URL {
                print("📄 PDF received: \(url.path)")
                // Traiter le PDF
                self?.handlePDF(url)
            }
        }
        return
    }
}
```

### Exemple 3 : Traiter les vidéos

```swift
for attachment in attachments {
    if attachment.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
        attachment.loadItem(forTypeIdentifier: UTType.movie.identifier, options: nil) { [weak self] data, error in
            if let url = data as? URL {
                print("🎬 Video received: \(url.path)")
                // Traiter la vidéo
                self?.handleVideo(url)
            }
        }
        return
    }
}
```

## 🔬 Découvertes communes

### Safari partageant une page web
```
✅ HAS: public.url
✅ HAS: public.plain-text
📌 ATTRIBUTED TITLE: "Page Title"
```

### Photos partageant une image
```
✅ HAS: public.image
✅ HAS: public.jpeg
✅ HAS: public.file-url
📦 LOADED DATA: UIImage (Size: 1024x768)
```

### Fichiers partageant un PDF
```
✅ HAS: com.adobe.pdf
✅ HAS: public.file-url
📦 LOADED DATA: URL (file:///path/to/document.pdf)
```

### Messages partageant du texte
```
✅ HAS: public.plain-text
✅ HAS: public.utf8-plain-text
📦 LOADED DATA: String ("Hello world")
```

## 🎯 Modification de la détection de source

### Important : Détection AVANT transformation

Le code utilise maintenant `detectSourceBeforeTransform()` qui :

1. Analyse l'URL **ORIGINALE** (youtube.com)
2. Détecte la source (YouTube)
3. **PUIS** transforme l'URL (yout-ube.com)
4. Sauvegarde avec la source originale

### Dans les logs, vous verrez :

```
📊 URL Processing:
   Original: https://www.youtube.com/watch?v=abc
   Transformed: https://www.yout-ube.com/watch?v=abc
   Source: YouTube  ← Basé sur l'URL originale!
```

## 🚀 Prochaines étapes

### 1. Désactiver les logs en production

Quand vous aurez fini vos tests, commentez l'appel dans `viewDidAppear` :

```swift
override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    
    // Explorer TOUS les types de données (DÉSACTIVER EN PRODUCTION)
    // exploreAllDataTypes()
    
    extractAndSaveURL()
}
```

### 2. Implémenter des handlers personnalisés

Créez des fonctions spécialisées :

```swift
private func handleImage(_ image: UIImage) {
    // Sauvegarder, compresser, uploader...
}

private func handleVideo(_ videoURL: URL) {
    // Extraire des frames, uploader...
}

private func handlePDF(_ pdfURL: URL) {
    // Lire, extraire du texte...
}

private func handleContact(_ contact: CNContact) {
    // Sauvegarder les infos de contact...
}
```

### 3. Créer une architecture modulaire

```swift
protocol ShareContentHandler {
    func canHandle(_ attachment: NSItemProvider) -> Bool
    func handle(_ attachment: NSItemProvider, completion: @escaping (Bool) -> Void)
}

class URLHandler: ShareContentHandler { ... }
class ImageHandler: ShareContentHandler { ... }
class VideoHandler: ShareContentHandler { ... }
```

## 📝 Exemples de logs réels

### Partage depuis Safari (YouTube)

```
================================================================================
🚀 SHARE EXTENSION ACTIVATED
================================================================================

📦 EXTENSION CONTEXT INFO:
   Input Items Count: 1

┌─ Input Item #1
│  📄 BASIC INFO:
│     Attachments Count: 1
│  📌 ATTRIBUTED TITLE:
│     String: Best Video Ever - YouTube
│  📎 ATTACHMENTS: 1 item(s)
│  ├─ Attachment #1
│  │  Registered Type Identifiers:
│  │     • public.url
│  │     • public.plain-text
└────────────────────────────────────────────────────────────────────────────

✅ Found URL type identifier

📥 URL DATA LOADED:
   Data Type: URL
   ✅ URL Object: https://www.youtube.com/watch?v=dQw4w9WgXcQ

🔎 Detecting source from original URL: https://www.youtube.com/watch?v=dQw4w9WgXcQ
   ✓ Guessed from domain: YouTube

📊 URL Processing:
   Original: https://www.youtube.com/watch?v=dQw4w9WgXcQ
   Transformed: https://www.yout-ube.com/watch?v=dQw4w9WgXcQ
   Source: YouTube
```

## 💡 Astuces

1. **Filtrer les logs** : Dans Xcode Console, cherchez les emojis (🚀, 📦, etc.)
2. **Copier les logs** : Clic droit > Copy Console Output
3. **Logs persistants** : Activez "Show timestamps" dans la console
4. **Tests systématiques** : Créez une checklist de types à tester

## ⚠️ Notes importantes

- Les logs sont **très verbeux** maintenant - c'est intentionnel pour la découverte
- **Désactivez-les en production** pour éviter la pollution de la console
- Certains types peuvent apparaître mais **ne pas charger** de données
- Le chargement est **asynchrone** - les logs peuvent être dans le désordre

---

**Bon debugging ! 🔬**

Utilisez ces logs pour découvrir exactement ce que chaque app partage, puis implémentez des traitements personnalisés.
