import SwiftUI
import AVFoundation
import UserNotifications

// MARK: - App Delegate for Notification Handling

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Set notification delegate
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Handle notification when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handleSleepTimerNotification(notification)
        completionHandler([]) // Don't show the notification
    }

    // Handle notification when user taps it (app was in background)
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        handleSleepTimerNotification(response.notification)
        completionHandler()
    }

    private func handleSleepTimerNotification(_ notification: UNNotification) {
        if notification.request.identifier == "xonora.sleepTimer" {
            print("[AppDelegate] Sleep timer notification received - pausing playback")
            Task { @MainActor in
                // Pause playback
                try? await XonoraClient.shared.pause()
                PlayerManager.shared.playbackState = .paused

                // Clear the timer state
                PlayerManager.shared.cancelSleepTimer()
            }
        }
    }
}

@main
struct XonoraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var playerViewModel = PlayerViewModel()
    @StateObject private var libraryViewModel = LibraryViewModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Configure tab bar to be transparent and floating
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)

        // Add blur effect
        let blurEffect = UIBlurEffect(style: .systemMaterial)
        appearance.backgroundEffect = blurEffect

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(playerViewModel)
                .environmentObject(libraryViewModel)
                .onAppear {
                    // Configure audio session asynchronously to avoid blocking startup
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.configureAudioSession()
                    }
                }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                print("[XonoraApp] App became active, refreshing state...")
                if playerViewModel.isConnected {
                    Task {
                        await XonoraClient.shared.fetchPlayers()
                    }
                } else if !playerViewModel.serverURL.isEmpty {
                    // The MA socket is commonly torn down while the app is suspended and
                    // doesn't come back on its own. Reconnect with saved credentials; the
                    // connect flow re-fetches players (and mirrors remote now-playing) once
                    // it's back up, so the card / Live Activity resync to live state.
                    print("[XonoraApp] Not connected on foreground — reconnecting…")
                    playerViewModel.connectToServer()
                }
            } else if newPhase == .background {
                // Dismiss keyboard when going to background to prevent snapshotting errors
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }

    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Pre-set the category so SendspinKit can activate the session quickly when
            // the phone actually produces audio (Mode P). We deliberately do NOT activate
            // it here: in Mode R (remote control) the phone produces no audio and must
            // hold no active/contending session, or merely opening the app to control a
            // speaker would interrupt a podcast already playing in the user's AirPods.
            // Activation is deferred to SendspinKit, which activates on real playback.
            try audioSession.setCategory(.playback, mode: .default, options: [])
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
}
