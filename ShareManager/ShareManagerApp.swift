import SwiftUI
import UIKit

@main
struct ShareManagerApp: App {
    /// Permet de relier un AppDelegate UIKit minimal au cycle de vie
    /// SwiftUI. On en a besoin uniquement pour recevoir les push
    /// silencieuses des subscriptions CloudKit (le SwiftUI lifecycle
    /// ne propose pas équivalent à
    /// `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

/// AppDelegate minimal : enregistre l'app pour les push silencieuses
/// (nécessaire pour que iOS livre les notifications de
/// `CKDatabaseSubscription`) et route ces pushes vers `CloudSync`.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Inscription aux remote notifications : nécessaire pour que
        // les CKDatabaseSubscription nous livrent leurs payloads
        // silencieux (content-available). On ne demande PAS l'autorisation
        // utilisateur (UNUserNotificationCenter) car nos notifications
        // sont 100 % silencieuses (jamais d'alerte / son / badge).
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // Toute push reçue ici déclenche un pull CloudKit. Le
        // CloudSync vérifie qu'il y a effectivement un changement
        // via le `serverChangeToken` ; aucun trafic inutile en cas
        // de payload non pertinent.
        Task {
            await CloudSync.shared.pullChanges()
            completionHandler(.newData)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Silencieux : en simulateur ou sans capacity APS provisionnée,
        // l'enregistrement peut échouer ; on ne casse rien — l'app
        // continue à pull sur didBecomeActive.
    }
}
