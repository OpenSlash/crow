import Foundation
@preconcurrency import UserNotifications

/// Posts reminder notifications. Needs the app bundle (scripts/run-crow-mac.sh);
/// a bare executable has no bundle identifier, so it falls back to AppleScript.
enum CrowReminderNotifier {
    static func post(_ text: String, id: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            postWithAppleScript(text)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                CrowMacLog("reminder notification not allowed")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Crow"
            content.body = text
            content.sound = .default
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    private static func postWithAppleScript(_ text: String) {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \"\(escaped)\" with title \"Crow\" sound name \"default\""]
        try? process.run()
    }
}
