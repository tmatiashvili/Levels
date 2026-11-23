// SPIKE-001 throwaway code. Not kept after the spike.

import CloudKit
import SwiftUI
import UIKit

@main
struct PushCheckApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(log: PushLog.shared)
        }
        .onChange(of: scenePhase) { _, phase in
            // Lets you see in the log that the app really was in the background.
            PushLog.shared.add("PHASE", "\(phase)")
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushLog.shared.add("LAUNCH", "didFinishLaunching, state=\(describe(application.applicationState))")
        // R1: register at every launch. No notification permission is needed for silent pushes.
        application.registerForRemoteNotifications()
        Task {
            await CloudSetup.run(log: PushLog.shared)
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let prefix = deviceToken.prefix(4).map { String(format: "%02x", $0) }.joined()
        PushLog.shared.add("APNS", "registered, token \(prefix)… (\(deviceToken.count) bytes)")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PushLog.shared.add("ERROR", "APNs registration failed: \(error.localizedDescription)")
    }

    // R1: log every silent push with a timestamp (added by PushLog) and the subscription ID.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let state = describe(application.applicationState)
        if let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) {
            let subscriptionID = notification.subscriptionID ?? "nil"
            PushLog.shared.add(
                "PUSH",
                "subscriptionID=\(subscriptionID) type=\(describe(notification.notificationType)) state=\(state)"
            )
        } else {
            PushLog.shared.add("PUSH", "not a CloudKit notification, state=\(state), keys=\(userInfo.keys.map { "\($0)" })")
        }
        // The spike fetches nothing. The line is already on disk.
        completionHandler(.noData)
    }

    private func describe(_ state: UIApplication.State) -> String {
        switch state {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    private func describe(_ type: CKNotification.NotificationType) -> String {
        switch type {
        case .database: "database"
        case .recordZone: "recordZone"
        case .query: "query"
        case .readNotification: "readNotification"
        @unknown default: "unknown"
        }
    }
}
