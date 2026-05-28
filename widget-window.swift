import AppKit
import WebKit
import Carbon

// ── Global ref for C-compatible hotkey callback (no captures allowed) ─────────
private var _delegate: AppDelegate?

private func _hotKeyCallback(
    _: EventHandlerCallRef?,
    _: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async { _delegate?.togglePanel() }
    return noErr
}

// ── Draggable WKWebView ────────────────────────────────────────────────────────
class DraggableWebView: WKWebView {
    override var mouseDownCanMoveWindow: Bool { true }
}

// ── App delegate ───────────────────────────────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {

    var panel: NSPanel!
    var webView: DraggableWebView!
    var isPinned = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        registerHotKey()
    }

    // ── Panel ─────────────────────────────────────────────────────────────────
    func buildPanel() {
        let w: CGFloat = 290, h: CGFloat = 390
        let x: CGFloat = 1100
        let screenH = NSScreen.main?.frame.height ?? 900
        let y = screenH - h - 44

        panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: w, height: h),
            styleMask:   [.borderless, .nonactivatingPanel, .resizable],
            backing:     .buffered,
            defer:       false
        )
        panel.level                       = .floating
        panel.isFloatingPanel             = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor             = .clear
        panel.isOpaque                    = false
        panel.hasShadow                   = true
        panel.collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize                     = NSSize(width: 240, height: 260)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.cornerRadius  = 12
        container.layer?.masksToBounds = true

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "widgetControl")

        webView                    = DraggableWebView(frame: container.bounds, configuration: cfg)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask   = [.width, .height]
        container.addSubview(webView)
        panel.contentView = container

        if let url = URL(string: "http://localhost:2727") {
            webView.load(URLRequest(url: url))
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ── Global hotkey: ⌥⌘C ───────────────────────────────────────────────────
    // Uses Carbon RegisterEventHotKey — no Accessibility / Input Monitoring
    // permission required.
    func registerHotKey() {
        _delegate = self

        var hkID  = EventHotKeyID(signature: 0x434C5744 /* CLWD */, id: 1)
        var hkRef: EventHotKeyRef?

        // ⌥⌘C  →  keyCode = kVK_ANSI_C (0x08), mods = optionKey | cmdKey
        let mods = UInt32(optionKey) | UInt32(cmdKey)
        RegisterEventHotKey(0x08, mods, hkID, GetApplicationEventTarget(), 0, &hkRef)

        var spec = EventTypeSpec(
            eventClass: UInt32(kEventClassKeyboard),
            eventKind:  UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), _hotKeyCallback, 1, &spec, nil, nil)
    }

    // ── Toggle show / hide ────────────────────────────────────────────────────
    func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // ── JS → Swift bridge ─────────────────────────────────────────────────────
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "widgetControl",
              let body   = message.body as? [String: Any],
              let action = body["action"] as? String
        else { return }

        DispatchQueue.main.async {
            switch action {
            case "togglePin":
                self.isPinned.toggle()
                self.panel.level = self.isPinned ? .floating : .normal
                self.webView.evaluateJavaScript("setPinned(\(self.isPinned))", completionHandler: nil)
            case "openURL":
                // Open in the user's real browser (respects existing sessions — no new profile)
                if let urlStr = body["url"] as? String, let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                }
            case "hide":
                // Hide only — process stays alive so ⌥⌘C can reopen it
                self.panel.orderOut(nil)
            case "close":
                NSApp.terminate(nil)
            default: break
            }
        }
    }

    // Stay alive when window is closed so hotkey can reopen it
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Retry on load failure
    func webView(_ wv: WKWebView, didFail _: WKNavigation!, withError _: Error) { retry() }
    func webView(_ wv: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) { retry() }
    private func retry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let url = URL(string: "http://localhost:2727") { self.webView.load(URLRequest(url: url)) }
        }
    }
}

// ── Entry point ────────────────────────────────────────────────────────────────
let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
