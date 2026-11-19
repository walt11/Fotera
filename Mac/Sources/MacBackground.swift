import SwiftUI
import ServiceManagement
import UserNotifications

extension Notification.Name {static let macShowBackup = Notification.Name("FoteraMacShowBackup")}
final class MacApplicationDelegate:NSObject,NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool {false}
}
@MainActor final class MacNotifications:NSObject,UNUserNotificationCenterDelegate {
    static let shared = MacNotifications()
    func register() {UNUserNotificationCenter.current().delegate = self}
    func request() async throws -> Bool {try await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound])}
    func completed(_ count:Int) {
        guard count > 0, UserDefaults.standard.bool(forKey:"mac.backup.notifications") else {return}
        let content = UNMutableNotificationContent(); content.title = "Fotera backup complete"; content.body = "\(count) photos verified on your NAS."; content.userInfo = ["route":"backup"]
        UNUserNotificationCenter.current().add(.init(identifier:"fotera-backup-complete",content:content,trigger:nil))
    }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping ()->Void) {
        Task {@MainActor in NSWorkspace.shared.open(URL(string:"fotera-mac://backup")!); NotificationCenter.default.post(name:.macShowBackup,object:nil); NSApp.activate(ignoringOtherApps:true); completionHandler()}
    }
}
struct MacStatusMenu:View {
    @EnvironmentObject var model:MacModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var queue:MacBackupQueue
    var body:some View {
        Button("Open Fotera") {openWindow(id:"main"); NSApp.activate(ignoringOtherApps:true)}
        Divider()
        Text("\(queue.completedPhotos) of \(queue.totalPhotos) photos verified")
        if queue.running {Button("Pause Backup") {queue.pause()}} else {Button("Resume Backup") {queue.retry()}.disabled(queue.totalPhotos == queue.completedPhotos)}
        Button("Backups…") {model.navigate(.backups); openWindow(id:"main"); NSApp.activate(ignoringOtherApps:true)}
        Divider()
        SettingsLink {Text("Settings…")}
        Button("Quit Fotera") {NSApp.terminate(nil)}.keyboardShortcut("q")
    }
}
struct MacBackgroundSettings:View {
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("mac.backup.notifications") private var notifications = false
    @State private var failure:String?
    var body:some View {
        Toggle("Open Fotera at login",isOn:Binding(get:{atLogin},set:{value in
            do {if value {try SMAppService.mainApp.register()} else {try SMAppService.mainApp.unregister()}; atLogin = SMAppService.mainApp.status == .enabled; if SMAppService.mainApp.status == .requiresApproval {failure = "Allow Fotera in System Settings → General → Login Items."}} catch {failure = error.localizedDescription}
        }))
        Toggle("Notify when backup completes",isOn:Binding(get:{notifications},set:{value in
            if !value {notifications = false; return}
            Task {do {notifications = try await MacNotifications.shared.request(); if !notifications {failure = "Allow notifications for Fotera in System Settings."}} catch {failure = error.localizedDescription}}
        }))
        Text("Closing the window keeps Fotera in the menu bar. Quitting Fotera or sleeping the Mac pauses backup.").font(.caption).foregroundStyle(.secondary)
        if let failure {Text(failure).foregroundStyle(.red)}
    }
}
