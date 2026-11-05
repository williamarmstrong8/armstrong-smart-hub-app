import AppKit
import WebKit

/// The Mac app: the hub's web app in a native window. Everything (data, sign-in,
/// secrets) stays on the hub; this only hosts the page, keeps its cookies between
/// launches and adds the menus a Mac app needs.
@main
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    static let hub = URL(string: "https://armstrong-smart-hub.vercel.app")!
    /// Same order as the web app's nav (components/shell/nav.ts), on ⌘1–⌘7.
    static let tabs: [(String, String)] = [
        ("Home", "/home"), ("Finance", "/finance"), ("Calendar", "/calendar"), ("Fitness", "/fitness"),
        ("Habits", "/habits"), ("Food", "/food"), ("Agent", "/"),
    ]

    private var window: NSWindow!
    private var web: WKWebView!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        // The default store persists to disk, so the hub's session cookie survives a relaunch.
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true

        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        // Safari's user agent: Google refuses to sign in inside an app's web view otherwise.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        // Matches the page color (HubDesign.page) so launch and resize don't flash white.
        web.underPageBackgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x16 / 255, green: 0x14 / 255, blue: 0x14 / 255, alpha: 1)
                : NSColor(srgbRed: 0xF2 / 255, green: 0xF0 / 255, blue: 0xEE / 255, alpha: 1)
        }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Armstrong Hub"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = web.underPageBackgroundColor
        window.minSize = NSSize(width: 420, height: 560)
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("HubWindow")
        window.makeKeyAndOrderFront(nil)

        NSApp.mainMenu = makeMenu()
        NSApp.activate()
        open("/home")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with the window closed brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    private func open(_ path: String) {
        web.load(URLRequest(url: URL(string: path, relativeTo: Self.hub)!))
    }

    // MARK: Navigation

    /// The hub (and Google's sign-in, which returns to it) stays in the window; any other link opens in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let host = url.host else { return decisionHandler(.allow) }
        // Sign-in redirects through Google's hosts; a link the user clicks to Google opens in the browser.
        let signIn = host.hasSuffix(".google.com") && action.navigationType != .linkActivated
        if host == Self.hub.host || signIn || action.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    /// target="_blank" links (calendar events, Google Calendar) open in the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if url.host == Self.hub.host { webView.load(action.request) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    /// File inputs (food photos, receipts).
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    // MARK: Menus

    @objc private func goToTab(_ sender: NSMenuItem) { open(Self.tabs[sender.tag].1) }
    @objc private func reload(_ sender: Any?) { web.reload() }
    @objc private func goBack(_ sender: Any?) { web.goBack() }
    @objc private func goForward(_ sender: Any?) { web.goForward() }
    @objc private func actualSize(_ sender: Any?) { web.pageZoom = 1 }
    @objc private func zoomIn(_ sender: Any?) { web.pageZoom = min(web.pageZoom + 0.1, 2) }
    @objc private func zoomOut(_ sender: Any?) { web.pageZoom = max(web.pageZoom - 0.1, 0.5) }
    @objc private func openInBrowser(_ sender: Any?) { NSWorkspace.shared.open(web.url ?? Self.hub) }
    @objc private func showWindow(_ sender: Any?) { window.makeKeyAndOrderFront(nil) }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Armstrong Hub", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Armstrong Hub", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Armstrong Hub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: "Armstrong Hub"))

        // Without an Edit menu, ⌘C/⌘V/⌘A don't reach the page.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: #selector(reload(_:)), keyEquivalent: "r").target = self
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(actualSize(_:)), keyEquivalent: "0").target = self
        view.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+").target = self
        view.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-").target = self
        view.addItem(.separator())
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu(view, title: "View"))

        let go = NSMenu(title: "Go")
        go.addItem(withTitle: "Back", action: #selector(goBack(_:)), keyEquivalent: "[").target = self
        go.addItem(withTitle: "Forward", action: #selector(goForward(_:)), keyEquivalent: "]").target = self
        go.addItem(.separator())
        for (index, tab) in Self.tabs.enumerated() {
            let item = go.addItem(withTitle: tab.0, action: #selector(goToTab(_:)), keyEquivalent: "\(index + 1)")
            item.tag = index
            item.target = self
        }
        go.addItem(.separator())
        go.addItem(withTitle: "Open in Browser", action: #selector(openInBrowser(_:)), keyEquivalent: "").target = self
        main.addItem(submenu(go, title: "Go"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Armstrong Hub", action: #selector(showWindow(_:)), keyEquivalent: "").target = self
        main.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu

        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
