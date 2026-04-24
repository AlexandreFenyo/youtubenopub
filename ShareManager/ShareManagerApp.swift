import SwiftUI

@main
struct ShareManagerApp: App {
    init() {
        // Valeurs par défaut de la Settings.bundle : utilisées seulement si
        // l'utilisateur n'a jamais modifié le réglage depuis Réglages iOS.
        UserDefaults.standard.register(defaults: [
            "describeImagesEnabled": true,
            "describeImagesProvider": "apple",
            "simulateDateDelay": false,
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
