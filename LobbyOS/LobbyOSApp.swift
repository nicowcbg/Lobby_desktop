import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import Sparkle

@main
struct LobbyOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No SwiftUI windows or scenes. AppKit only!
    }
}

private func focusAppWindow() {
    NSApp.activate(ignoringOtherApps: true)
    NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
}

private func normalizeForCompare(_ url: URL) -> String {
    var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    // Optional: ignore fragment (#...) so it doesn't force reload
    comps?.fragment = nil

    var s = (comps?.url?.absoluteString ?? url.absoluteString)
    if s.hasSuffix("/") { s.removeLast() }
    return s
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow!
    private var updater: SPUUpdater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Lobby"
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.zoom(nil)

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                print("[✅] Notifications allowed")
            } else if let error = error {
                print("[❌] Notification error: \(error)")
            }
        }

        try? SMAppService.mainApp.register()

        // Sparkle setup
        do {
            let driver = SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil)
            updater =  SPUUpdater(hostBundle: Bundle.main, applicationBundle: Bundle.main, userDriver: driver, delegate: nil)
            try updater?.start()
        } catch {
            print("Sparkle init failed: \(error)")
        }

        setupMenuBar()
    }


    private func setupMenuBar() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        appMenu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Reload App", action: #selector(reloadWebView), keyEquivalent: "r"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Lobby", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // --- Add standard Edit menu for system copy/paste/cut ---
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSStandardKeyBindingResponding.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        // -------------------------------------------------------

        NSApplication.shared.mainMenu = mainMenu
    }

    @objc private func checkForUpdates() {
        updater?.checkForUpdates()
    }

    @objc private func reloadWebView() {
        ContentView.webViewRef?.reload()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    private var lastInactiveTime: Date? = nil

       func applicationDidResignActive(_ notification: Notification) {
           lastInactiveTime = Date()
       }

       func applicationDidBecomeActive(_ notification: Notification) {
           setupMenuBar()
           updater?.checkForUpdatesInBackground()  // silent, will show dialog if update is found

           if let last = lastInactiveTime, Date().timeIntervalSince(last) > 1800 {
               ContentView.webViewRef?.reload()
               updater?.checkForUpdatesInBackground()

           }
       }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let incoming = urls.first else { return }
        print("[OpenURL] Received:", incoming.absoluteString)

        DispatchQueue.main.async {
            guard let webView = ContentView.webViewRef else {
                focusAppWindow()
                return
            }

            func navigateTo(_ target: URL) {
             

                if let current = webView.url,
                   normalizeForCompare(current) == normalizeForCompare(target) {
                    focusAppWindow()
                    return
                }
                
                // Same URL? => just focus, do NOT reload // ✅ Force hard-load for auth / API endpoints (must hit network to set cookies + follow redirects)
                let pathLower = target.path.lowercased()
                if pathLower.hasPrefix("/api/") || pathLower.contains("login-link") {
                    var req = URLRequest(url: target)
                    req.cachePolicy = .reloadIgnoringLocalCacheData
                    webView.load(req)
                    focusAppWindow()
                    return
                }

                // Same origin? Try SPA navigation (no reload). Fallback to full load.
                if let current = webView.url,
                   current.host == target.host,
                   current.scheme == target.scheme {

                    let path = target.path
                      + (target.query.map { "?\($0)" } ?? "")
                      + (target.fragment.map { "#\($0)" } ?? "")

                    let safePath = path
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")

                    let js = """
                    (function() {
                      try {
                        history.pushState({}, "", "\(safePath)");
                        window.dispatchEvent(new PopStateEvent("popstate"));
                        return "spa";
                      } catch(e) { return "error"; }
                    })();
                    """

                    webView.evaluateJavaScript(js) { _, error in
                        if error != nil {
                            webView.load(URLRequest(url: target))
                        }
                    }

                    focusAppWindow()
                    return
                }

                // Different origin => normal load
                webView.load(URLRequest(url: target))
                focusAppWindow()
            }

            // lobby://open?url=<percent-encoded https://...>
            if incoming.scheme == "lobby", incoming.host == "open" {
                if let comps = URLComponents(url: incoming, resolvingAgainstBaseURL: false),
                   let encoded = comps.queryItems?.first(where: { $0.name == "url" })?.value,
                   let decoded = encoded.removingPercentEncoding,
                   let target = URL(string: decoded) {
                    navigateTo(target)
                    return
                }

                focusAppWindow()
                return
            }

            // Universal link (https://...)
            if let scheme = incoming.scheme?.lowercased(), scheme == "https" || scheme == "http" {
                navigateTo(incoming)
                return
            }

            // Anything else
            NSWorkspace.shared.open(incoming)
            focusAppWindow()
        }
    }



}
