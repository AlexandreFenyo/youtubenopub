# 🎨 Générateur d'Icône pour ShareManager

## Comment générer et installer l'icône de l'application

### Méthode 1 : Directement depuis l'app (RECOMMANDÉ)

1. **Lancez l'application** sur votre iPhone ou dans le simulateur
2. **Cliquez sur l'icône 📱** dans la barre de navigation (en haut à droite)
3. **Appuyez sur "Sauvegarder dans Photos"**
4. L'icône sera générée en 1024x1024 pixels et sauvegardée dans votre bibliothèque Photos
5. **Autoriser l'accès** aux Photos si demandé

### Installation dans Xcode

1. Ouvrez votre projet dans **Xcode**
2. Dans le navigateur de projet (panneau de gauche), trouvez **Assets.xcassets**
3. Cliquez sur **AppIcon**
4. **Glissez-déposez** l'image depuis votre bibliothèque Photos vers l'emplacement **1024x1024 (iOS App Store)**
5. Xcode générera automatiquement toutes les tailles nécessaires

### Méthode 2 : Avec le script Python

Si vous préférez générer l'icône sans lancer l'app :

```bash
# Installer Pillow si nécessaire
pip install pillow

# Exécuter le script
python3 generate_icon.py
```

Cela créera un fichier `AppIcon.png` de 1024x1024 pixels que vous pourrez glisser dans Xcode.

## Description de l'icône

L'icône représente visuellement la fonctionnalité de l'application :

- 📄 **Rectangle blanc** : Document/URL à partager
- ⬇️ **Flèche** : Action de partage
- 📁 **Dossier jaune** : Stockage/destination des URLs partagées
- 🔵 **Fond bleu** : Design moderne et professionnel

## Caractéristiques techniques

- **Taille** : 1024x1024 pixels
- **Format** : PNG avec transparence
- **Résolution** : Optimisée pour tous les appareils iOS
- **Compatibilité** : iOS 15+ (App Store, écran d'accueil, Spotlight, etc.)

## Besoin d'aide ?

Si vous rencontrez des problèmes :
1. Assurez-vous d'avoir autorisé l'accès aux Photos
2. Vérifiez que l'image fait bien 1024x1024 pixels
3. Redémarrez Xcode si les changements ne sont pas visibles
