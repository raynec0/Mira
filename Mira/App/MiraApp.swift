import SwiftUI
import UIKit
import UserNotifications

@main
struct MiraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore.shared
    @StateObject private var engine = AgentEngine.shared
    @StateObject private var lock = LockManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(engine)
                .environmentObject(lock)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                store.isForeground = true
                UNUserNotificationCenter.current().setBadgeCount(0, withCompletionHandler: nil)
                if let id = store.activeConversationID { store.markRead(id) }
                Task {
                    await lock.unlock()
                    await RoutineScheduler.shared.runDue()
                }
            case .background:
                store.isForeground = false
                store.saveNow()
                lock.lockIfEnabled()
                RoutineScheduler.shared.scheduleBackgroundRefresh()
            default:
                break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        RoutineScheduler.registerBackgroundTask()
        NotificationService.requestAuthorization()
        Task { @MainActor in await RoutineScheduler.shared.reschedule() }
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let convID = (info["conversationID"] as? String).flatMap { UUID(uuidString: $0) }
        let isRoutine = info["routineID"] != nil
        completionHandler()
        Task { @MainActor in
            let store = AppStore.shared
            store.selectedTab = .messages
            if let convID { store.openConversationRequest = convID }
            if isRoutine { await RoutineScheduler.shared.runDue() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var lock: LockManager
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $store.selectedTab) {
            ConversationListView()
                .tabItem { Label("信息", systemImage: "message.fill") }
                .tag(AppTab.messages)
                .badge(store.unreadCount)
            TasksView()
                .tabItem { Label("任务", systemImage: "checklist") }
                .tag(AppTab.tasks)
            ActivityView()
                .tabItem { Label("动态", systemImage: "waveform.path.ecg") }
                .tag(AppTab.activity)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .overlay {
            if lock.isLocked { LockScreen() }
        }
        .onReceive(ticker) { _ in
            Task { await RoutineScheduler.shared.runDue() }
        }
    }
}

struct LockScreen: View {
    @EnvironmentObject private var lock: LockManager

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.iMessageBlue)
                Text("Mira 已锁定").font(.title3.weight(.semibold))
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Text("解锁").font(.headline).padding(.horizontal, 30).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
            }
        }
        .task { await lock.unlock() }
    }
}
