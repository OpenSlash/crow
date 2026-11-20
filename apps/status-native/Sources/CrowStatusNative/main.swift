import AppKit
import Foundation

struct StatusAction: Codable {
    let id: String
    let type: String
    let createdAt: String
}

struct IslandState: Decodable {
    let status: String
    let title: String
    let phase: String
    let pendingApprovals: Int
}

final class StatusApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var stateItem: NSMenuItem?
    private var approvalItem: NSMenuItem?
    private var refreshTimer: Timer?
    private let isoFormatter = ISO8601DateFormatter()

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        refreshState()
        refreshTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(refreshTimerFired), userInfo: nil, repeats: true)
    }

    @MainActor
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 62)
        item.isVisible = true

        if let button = item.button {
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
            ]
            button.attributedTitle = NSAttributedString(string: "Crow", attributes: attributes)
            button.toolTip = "Crow"
        }

        let menu = NSMenu(title: "Crow")
        let stateItem = NSMenuItem(title: "Crow is ready", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        self.stateItem = stateItem
        menu.addItem(stateItem)

        let approvalItem = NSMenuItem(title: "No pending approvals", action: nil, keyEquivalent: "")
        approvalItem.isEnabled = false
        self.approvalItem = approvalItem
        menu.addItem(approvalItem)
        menu.addItem(.separator())

        menu.addItem(menuItem("Show Crow", #selector(showCrow)))
        menu.addItem(menuItem("Hide Crow", #selector(hideCrow)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Crow", #selector(quitCrow)))
        item.menu = menu

        statusItem = item
    }

    @MainActor private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showCrow() {
        writeAction("status.show")
    }

    @objc private func hideCrow() {
        writeAction("status.hide")
    }

    @objc private func quitCrow() {
        writeAction("status.quit")
    }

    private func writeAction(_ type: String) {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Crow", isDirectory: true) else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let action = StatusAction(id: UUID().uuidString, type: type, createdAt: isoFormatter.string(from: Date()))
            let data = try JSONEncoder().encode(action)
            try data.write(to: directory.appendingPathComponent("status-action.json"), options: .atomic)
        } catch {
            NSLog("Crow status action failed: \(error.localizedDescription)")
        }
    }

    private func refreshState() {
        guard let stateURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Crow", isDirectory: true)
            .appendingPathComponent("island-state.json") else {
            return
        }

        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(IslandState.self, from: data) else {
            stateItem?.title = "Crow is ready"
            approvalItem?.title = "No pending approvals"
            return
        }

        let label = stateLabel(for: state)
        stateItem?.title = label
        approvalItem?.title = state.pendingApprovals > 0
            ? "\(state.pendingApprovals) approval pending"
            : "No pending approvals"
    }

    @objc private func refreshTimerFired() {
        refreshState()
    }

    private func stateLabel(for state: IslandState) -> String {
        let title = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = title.isEmpty || title == "Crow" ? "Crow" : title

        switch state.phase {
        case "approval":
            return "Waiting for approval: \(subject)"
        case "speaking":
            return "Speaking: \(subject)"
        case "thinking", "planning":
            return "Thinking: \(subject)"
        case "running", "tool", "starting", "responding":
            return "Working: \(subject)"
        case "completed":
            return "Completed: \(subject)"
        case "failed":
            return "Needs review: \(subject)"
        default:
            return "Crow is ready"
        }
    }
}

let app = NSApplication.shared
let delegate = StatusApp()
app.delegate = delegate
app.run()
