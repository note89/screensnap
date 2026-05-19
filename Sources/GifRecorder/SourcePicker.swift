import AppKit
import ScreenCaptureKit

/// Small modal pickers for "which display?" and "which window?". These are
/// used when the user chose Capture = Display or Capture = Window but we
/// need to ask them to pick a specific one.
@MainActor
enum SourcePicker {

    /// Returns the chosen display, or nil if cancelled.
    static func pickDisplay() async -> SCDisplay? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            return nil
        }
        let displays = content.displays
        if displays.isEmpty { return nil }
        if displays.count == 1 { return displays[0] }

        let alert = NSAlert()
        alert.messageText = "Choose display to record"
        alert.informativeText = "Pick which screen you want to capture."

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        for (i, d) in displays.enumerated() {
            popup.addItem(withTitle: "Display \(i + 1) — \(d.width)×\(d.height)")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return displays[popup.indexOfSelectedItem]
    }

    /// Returns the chosen window, or nil if cancelled.
    static func pickWindow() async -> SCWindow? {
        let content: SCShareableContent
        do {
            // `onScreenWindowsOnly: false` so we also see minimized/other-Space windows.
            content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false
            )
        } catch {
            return nil
        }
        // Filter to windows that are reasonable capture targets.
        let windows = content.windows.filter { w in
            guard let title = w.title, !title.isEmpty else { return false }
            guard w.frame.width >= 100, w.frame.height >= 100 else { return false }
            // Skip our own windows.
            if w.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier { return false }
            return true
        }
        if windows.isEmpty { return nil }

        let alert = NSAlert()
        alert.messageText = "Choose window to record"
        alert.informativeText = "Window captures work even when the window is on another Space or minimized."

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
        for w in windows {
            let app = w.owningApplication?.applicationName ?? "Unknown"
            let title = w.title ?? "(untitled)"
            popup.addItem(withTitle: "\(app) — \(title)")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return windows[popup.indexOfSelectedItem]
    }
}
