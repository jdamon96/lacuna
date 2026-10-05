import AppKit
@preconcurrency import Sparkle

/// Sparkle owns update scheduling, permission, downloads, and installation UI.
final class AppUpdater: NSObject, NSMenuItemValidation, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?
    private var hasStarted = false
    private var unavailableReason: String?
    var willShowUI: (() -> Void)?

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        if let reason = Self.configurationIssue(in: .main) {
            unavailableReason = reason
            return
        }

        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        do {
            // Leave automatic checks and downloads to Sparkle's standard opt-in
            // permission and the user's saved choices; never reset them on launch.
            try controller.updater.start()
            self.controller = controller
        } catch {
            // A source build with incomplete packaging should still be usable.
            unavailableReason = "Updates are unavailable in this build."
            NSLog("Lacuna updater could not start: %@", error.localizedDescription)
        }
    }

    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = canCheckForUpdates
        item.toolTip = unavailableReason
        return item
    }

    func makeAutomaticChecksMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for updates automatically", action: #selector(toggleAutomaticChecks(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = controller != nil
        item.state = controller?.updater.automaticallyChecksForUpdates == true ? .on : .off
        item.toolTip = unavailableReason
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.toolTip = unavailableReason
        if menuItem.action == #selector(toggleAutomaticChecks(_:)) {
            menuItem.state = controller?.updater.automaticallyChecksForUpdates == true ? .on : .off
            return controller != nil
        }
        return menuItem.action == #selector(checkForUpdates(_:)) && canCheckForUpdates
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard canCheckForUpdates else { return }
        willShowUI?()
        // Lacuna is an accessory app: foreground explicit checks without adding
        // a Dock icon or changing its normal menu-bar activation policy.
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(sender)
    }

    @objc func toggleAutomaticChecks(_ sender: NSMenuItem) {
        guard let controller else { return }
        // This is an explicit user setting change; Sparkle persists the choice.
        controller.updater.automaticallyChecksForUpdates.toggle()
        sender.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
    }

    func standardUserDriverWillShowModalAlert() {
        willShowUI?()
        NSApp.activate(ignoringOtherApps: true)
    }

    static func configurationIssue(in bundle: Bundle) -> String? {
        guard bundle.bundleURL.pathExtension == "app" else {
            return "Updates are available in an installed Lacuna app."
        }
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return "This build does not have a secure update feed configured."
        }
        guard let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let key = Data(base64Encoded: publicKey), key.count == 32 else {
            return "This build does not have an update verification key configured."
        }
        return nil
    }
}
