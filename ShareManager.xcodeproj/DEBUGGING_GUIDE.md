# 🐛 Guide de Debugging des Share Extensions

## ❌ Problème : "Je ne vois pas les logs dans la console"

C'est un problème courant ! Les Share Extensions s'exécutent dans un **processus séparé** de votre app principale, donc vous devez débugger le bon processus.

## ✅ Solutions

### Solution 1 : Débugger la Share Extension directement (RECOMMANDÉ)

1. **Sélectionnez le bon target** :
   - En haut à gauche dans Xcode, cliquez sur le scheme
   - Sélectionnez votre **Share Extension** (pas l'app principale)

2. **Configurez le scheme** :
   - Cliquez sur le scheme → **Edit Scheme...**
   - Allez dans **Run** → **Info**
   - Pour **Executable**, sélectionnez **"Ask on Launch"**
   - Cliquez sur **Close**

3. **Lancez le debugging** :
   - Appuyez sur **Cmd+R** ou cliquez sur le bouton Play
   - Une fenêtre apparaît : "Choose an app to run"
   - Sélectionnez **Safari** (ou l'app que vous voulez tester)
   - Safari s'ouvre avec le debugger attaché

4. **Testez** :
   - Dans Safari, allez sur une vidéo YouTube
   - Cliquez sur le bouton **Partager** (icône ⎋)
   - Sélectionnez votre Share Extension
   - **Les logs apparaissent maintenant dans Xcode !** 🎉

### Solution 2 : Attacher au processus en cours

Si votre Share Extension est déjà en cours d'exécution :

1. Dans Xcode, menu **Debug** → **Attach to Process by PID or Name...**
2. Tapez le nom de votre extension (ex: "ShareManager Extension")
3. Cliquez sur **Attach**
4. Partagez du contenu
5. Les logs apparaissent !

### Solution 3 : Console.app (macOS)

Pour voir les logs système :

1. Ouvrez **Console.app** (dans Applications/Utilitaires)
2. Dans la barre de recherche, tapez le nom de votre app ou extension
3. Partagez du contenu
4. Les logs apparaissent dans Console.app

### Solution 4 : Logs de device (iOS physique)

Si vous testez sur un iPhone/iPad physique :

1. Connectez l'appareil à votre Mac
2. Ouvrez **Console.app**
3. Sélectionnez votre appareil dans la barre latérale gauche
4. Filtrez par le nom de votre app/extension
5. Partagez du contenu sur l'appareil
6. Les logs apparaissent dans Console.app

## 🔍 Vérifier que tout fonctionne

Avec les nouveaux logs ajoutés, vous devriez voir :

```
🎬 ShareViewController viewDidLoad() called
   Bundle ID: com.yourapp.ShareExtension
   Extension Context: ✅ Available

🎬 ShareViewController viewDidAppear() called
   Extension Context Available: true

================================================================================
🔬 EXPLORING ALL POSSIBLE DATA TYPES
================================================================================
...
```

Si vous ne voyez **RIEN**, alors :
1. ❌ Le debugger n'est pas attaché au bon processus
2. ❌ Vous regardez les logs de l'app principale, pas de l'extension
3. ❌ La Share Extension n'est pas configurée correctement dans Info.plist

## 🎯 Checklist de debugging

- [ ] J'ai sélectionné le target **Share Extension** (pas l'app principale)
- [ ] J'ai configuré le scheme avec "Ask on Launch"
- [ ] J'ai lancé l'app et choisi Safari
- [ ] J'ai ouvert la console Xcode (View → Debug Area → Activate Console)
- [ ] J'ai partagé du contenu depuis Safari
- [ ] Je vois au moins le log "🎬 ShareViewController viewDidLoad()"

## 💡 Astuces

### Filtrer les logs
Dans la console Xcode, utilisez la barre de recherche pour filtrer :
- Cherchez `🎬` ou `🚀` ou `📦` pour voir vos logs
- Ou cherchez "ShareViewController"

### Logs en temps réel
Activez "Automatically Continue After Evaluating" dans les breakpoints pour ne pas bloquer l'exécution.

### Ralentir l'animation
Pour avoir plus de temps pour lire les logs, augmentez le délai dans `showCheckmark()` :
```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { // Au lieu de 1.0
```

## 🚨 Problèmes communs

### "Extension Context: ❌ Not available"
➜ Votre Share Extension n'est pas correctement configurée. Vérifiez Info.plist.

### "Aucun log n'apparaît"
➜ Le debugger n'est pas attaché. Utilisez Solution 1 ou 2.

### "L'extension ne s'affiche pas dans le menu Partager"
➜ Vérifiez que `NSExtensionActivationRule` dans Info.plist permet les URLs.

### "L'app crash immédiatement"
➜ Vérifiez que l'App Group est correctement configuré dans Capabilities.

## 📝 Configuration minimale requise

### Dans Info.plist de la Share Extension :

```xml
<key>NSExtensionAttributes</key>
<dict>
    <key>NSExtensionActivationRule</key>
    <string>TRUEPREDICATE</string>
    <!-- OU pour les URLs uniquement : -->
    <dict>
        <key>NSExtensionActivationSupportsWebURLWithMaxCount</key>
        <integer>1</integer>
    </dict>
</dict>
```

### Dans Signing & Capabilities :

- ✅ App Groups activé
- ✅ Même groupe pour l'app et l'extension : `group.net.fenyo.apple.sharemanager`

## ✅ Tout est bon si vous voyez :

```
🎬 ShareViewController viewDidLoad() called
   Bundle ID: com.yourapp.ShareExtension
   Extension Context: ✅ Available

🎬 ShareViewController viewDidAppear() called
   Extension Context Available: true

================================================================================
🚀 SHARE EXTENSION ACTIVATED
================================================================================

📦 EXTENSION CONTEXT INFO:
   Input Items Count: 1

┌─ Input Item #1
│  📄 BASIC INFO:
│     Type: NSExtensionItem
│     Attachments Count: 1
│  📌 ATTRIBUTED TITLE:
│     String: YouTube Video Title
...
```

---

**Si après avoir suivi ces étapes vous ne voyez toujours rien, faites-moi savoir et je vous aiderai à diagnostiquer plus en profondeur !**
