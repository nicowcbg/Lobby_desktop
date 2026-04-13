import SwiftUI
import WebKit
import Network
import UserNotifications

struct ContentView: View {
    static var webViewRef: WKWebView? = nil
    @State private var isLoading: Bool = true

    var body: some View {
        ZStack {
            WebView(isLoading: $isLoading)
                .ignoresSafeArea()
            if isLoading {
                LoaderOverlay()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
    }
}

struct LoaderOverlay: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 10) {
                Image("loader") // Your asset, see earlier note
                    .resizable()
                    .frame(width: 56, height: 56)
                    .cornerRadius(12)
                    .shadow(radius: 8)


                // Animated gradient loading text
                AnimatedLoadingText()
                    .frame(height: 18)
                    .padding(.top, 1)
            }
        }
    }
}


struct AnimatedLoadingText: View {
    @State private var offset: CGFloat = 0
    let text = "Loading"

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // The loading text is always centered in its available width
            ZStack {
                // The animated gradient "filling" the width of the page
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(hex: "#A8A8A8"),
                        Color(hex: "#666666"),
                        Color(hex: "#A8A8A8")
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: width * 4, height: geo.size.height)
                .offset(x: -width * 3 + offset)
                .mask(
                    HStack {
                        Spacer()
                        Text(text)
                            .font(Font.custom("Inter-Regular", size: 12))
                            .frame( alignment: .center)
                        Spacer()
                    }
                )
            }
            .onAppear {
                offset = 0
                withAnimation(Animation.linear(duration: 1).repeatForever(autoreverses: false)) {
                    offset = width * 4
                }
            }
        }
        .frame(height: 18)
    }
}



// Color hex helper as before
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int = UInt64()
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: 1.0)
    }
}

struct WebView: NSViewRepresentable {
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(isLoading: $isLoading) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            config.applicationNameForUserAgent = "LobbyDesktop/\(v)"
        }
        // Desktop app flag injection (main frame only + DOM + storage)
        let desktopFlag = WKUserScript(
            source: """
            // Reliable cross-world signals:
            try { document.documentElement.setAttribute('data-runtime','desktop'); } catch(e) {}
            try { localStorage.setItem('runtime','desktop'); } catch(e) {}

            // Optional window flags (may be isolated in some WK worlds)
            window.__LOBBY_RUNTIME__ = 'desktop';
            window.IS_LOBBY_DESKTOP_APP = true;
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(desktopFlag)

        let ensureDesktopModeForSettings = WKUserScript(
            source: """
            (function () {
              function ensureMode() {
                try {
                  var u = new URL(window.location.href);

                  // Adjust path if your Settings route is different:
                  var isSettings = u.pathname.startsWith('/lobby/Settings');

                  if (isSettings && !u.searchParams.has('mode')) {
                    u.searchParams.set('mode', 'desktop');
                    // Replace URL without reloading (avoids breaking SPA nav)
                    window.history.replaceState({}, '', u.toString());
                  }
                } catch (e) {}
              }

              // Run on initial load
              ensureMode();

              // Run on SPA navigations
              var _pushState = history.pushState;
              history.pushState = function () {
                _pushState.apply(this, arguments);
                ensureMode();
              };

              var _replaceState = history.replaceState;
              history.replaceState = function () {
                _replaceState.apply(this, arguments);
                ensureMode();
              };

              window.addEventListener('popstate', ensureMode);

              // Extra safety (Bubble sometimes updates URL asynchronously)
              setInterval(ensureMode, 500);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )

        contentController.addUserScript(ensureDesktopModeForSettings)

        // JS to Swift bridge for notifications
        let notificationScript = """
        if (location.hostname.endsWith('thelobby.ai')) {
          window.Notification = function(title, options) {
            window.webkit?.messageHandlers?.sendNotification?.postMessage({
              title: title,
              body: (options && options.body) || ""
            });
            return { permission: "granted" };
          };
          Notification.requestPermission = function(cb) { if (cb) cb("granted"); };
          Notification.permission = "granted";
        }
        """
        let script = WKUserScript(
          source: notificationScript,
          injectionTime: .atDocumentStart,
          forMainFrameOnly: true // was false
        )

        contentController.addUserScript(script)
        contentController.add(context.coordinator, name: "sendNotification")

        let webView = WKWebView(frame: .zero, configuration: config)
        ContentView.webViewRef = webView
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        if let url = URL(string: "https://thelobby.ai/lobby/Briefing") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private var isLoading: Binding<Bool>
        init(isLoading: Binding<Bool>) { self.isLoading = isLoading }

        // Native loading triggers
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading.wrappedValue = true
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading.wrappedValue = false
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading.wrappedValue = false
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading.wrappedValue = false
        }

        // Notifications
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "sendNotification",
               let payload = message.body as? [String: Any],
               let title = payload["title"] as? String,
               let body = payload["body"] as? String {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request)
            }
        }

        // File uploader support
        func webView(_ webView: WKWebView,
                     runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            panel.begin { result in
                if result == .OK {
                    completionHandler(panel.urls)
                } else {
                    completionHandler(nil)
                }
            }
        }

        // Open window (e.g., Bubble "Open in new tab")
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {

            if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        // External links handler
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let allowedHost = "thelobby.ai"

            func hostMatches(_ host: String?, anyOf list: [String]) -> Bool {
                guard let host = host?.lowercased() else { return false }
                return list.contains(where: { host == $0 || host.hasSuffix("." + $0) })
            }

            // Block about:blank
            if url.scheme == "about" {
                decisionHandler(.cancel)
                return
            }

            // Only http(s) is supported in-app; open other schemes externally (mailto:, etc.)
            let scheme = (url.scheme ?? "").lowercased()
            if scheme != "http" && scheme != "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            let isMainFrameNav = (navigationAction.targetFrame?.isMainFrame ?? false)
            let isPopup = (navigationAction.targetFrame == nil)

            let isLobbyDomain = hostMatches(url.host, anyOf: [allowedHost])

            // ------------------------------------------------------------
            // 1) Stripe handling
            // ------------------------------------------------------------

            // Stripe.js loads background frames like:
            // https://js.stripe.com/v3/m-outer-....html#...
            // This MUST stay inside the webview or you'll get blank browser tabs.
            if hostMatches(url.host, anyOf: ["js.stripe.com"]) {
                decisionHandler(.allow)
                return
            }

            // Only open real Stripe UX externally (Checkout / Billing portal / Pay)
            let stripeExternalHosts = ["checkout.stripe.com", "billing.stripe.com", "pay.stripe.com"]
            if hostMatches(url.host, anyOf: stripeExternalHosts) {
                
                decisionHandler(.allow)
                return
            }

            // ------------------------------------------------------------
            // 2) OAuth (external)
            // ------------------------------------------------------------

            let oauthExternalHosts = ["accounts.google.com", "appleid.apple.com"]
            if hostMatches(url.host, anyOf: oauthExternalHosts) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            // ------------------------------------------------------------
            // 3) App routing sandbox for thelobby.ai
            //    Allow only /login... and /lobby...
            //    Everything else -> redirect to /login?mode=desktop
            // ------------------------------------------------------------

            if isLobbyDomain {
                let path = url.path
                // Allow specific same-host paths to open externally WITHOUT navigating the webview.
                if path.hasPrefix("/api/") {
                      decisionHandler(.allow)
                      return
                  }
                let isUserNav = isPopup || isMainFrameNav

                if isUserNav && (path == "/app_redirect" || path.hasPrefix("/app_redirect/")) {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }


                func redirectInWebView(_ newURL: URL) {
                    // Avoid infinite loops

                    if newURL != url {
                        webView.load(URLRequest(url: newURL))
                    }
                    decisionHandler(.cancel)
                }
      

                // Force /login -> /login?mode=desktop (preserve existing params)
                if path == "/login" || path.hasPrefix("/login/") {
                    var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    var items = comps?.queryItems ?? []

                    let hasMode = items.contains(where: { $0.name.lowercased() == "mode" })
                    if !hasMode {
                        items.append(URLQueryItem(name: "mode", value: "desktop"))
                        comps?.queryItems = items
                        if let newURL = comps?.url {
                            redirectInWebView(newURL)
                            return
                        }
                    }

                    // already has mode=..., allow
                    decisionHandler(.allow)
                    return
                }
                // Allow Bubble API endpoints used for auth/session establishment
               
                // Allow /lobby...
                if path == "/lobby" || path.hasPrefix("/lobby/") {
                    decisionHandler(.allow)
                    return
                }
                

                // Any other thelobby.ai path -> redirect to /login?mode=desktop (inside app)
                if let loginURL = URL(string: "https://\(allowedHost)/login?mode=desktop") {
                    redirectInWebView(loginURL)
                    return
                }
                

                // Fallback
                decisionHandler(.allow)
                return
            }

            // ------------------------------------------------------------
            // 4) Popups / external domains safety
            // ------------------------------------------------------------

            // Popups from non-lobby domains: open externally
            if isPopup {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            // Prevent subframes/iframes from triggering external browser opens.
            // If it's not a main-frame nav, just allow it to load silently.
            if !isMainFrameNav {
                decisionHandler(.allow)
                return
            }

            // Any other top-level non-lobby navigation -> external browser
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }


    }
}
