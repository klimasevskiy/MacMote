import AppKit
import SwiftUI
import ServiceManagement

/// Borderless, non-activating panel shaped like the remote: it takes keyboard focus
/// without pulling the frontmost app out of focus (like Spotlight / Control Center).
final class RemotePanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tv = TVClient()
    private let ui = UIState()
    private var statusItem: NSStatusItem!
    private var panel: RemotePanel? // created on open, released on close to keep memory low
    private var monitors: [Any] = []
    private var anchor = NSPoint.zero // top-centre under the status item

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "appletvremote.gen4", accessibilityDescription: "MacMote")
                ?? NSImage(systemSymbolName: "tv", accessibilityDescription: "MacMote")
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        tv.connect() // warm up so the first click is instant
        tv.scheduleIdleDisconnect()
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        panel == nil ? open() : close()
    }

    // MARK: panel

    private func open() {
        guard let button = statusItem.button, let bw = button.window else { return }
        tv.connect()
        let p = RemotePanel()
        let host = NSHostingController(rootView: RemoteView(tv: tv, ui: ui))
        host.sizingOptions = .preferredContentSize
        p.contentViewController = host
        panel = p

        let rect = bw.convertToScreen(button.convert(button.bounds, to: nil))
        anchor = NSPoint(x: rect.midX, y: rect.minY - 6)
        place()
        NotificationCenter.default.addObserver(self, selector: #selector(panelResized),
                                               name: NSWindow.didResizeNotification, object: p)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        startMonitors()
    }

    private func close() {
        guard let p = panel else { return }
        panel = nil
        stopMonitors()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: p)
        ui.keyboardOpen = false
        ui.typing = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; p.animator().alphaValue = 0 }) {
            p.orderOut(nil)
            p.contentViewController = nil
        }
        tv.scheduleIdleDisconnect()
    }

    /// Keep the panel hanging from the menu bar as cards appear/disappear.
    @objc private func panelResized() { place() }

    private func place() {
        guard let p = panel else { return }
        let size = p.frame.size
        var x = anchor.x - size.width / 2
        if let vis = (p.screen ?? statusItem.button?.window?.screen)?.visibleFrame {
            x = min(max(x, vis.minX + 8), vis.maxX - size.width - 8)
        }
        p.setFrameTopLeftPoint(NSPoint(x: x, y: anchor.y))
        p.invalidateShadow()
    }

    // MARK: events

    private func startMonitors() {
        // Close when clicking anywhere outside the app.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown],
                                                     handler: { [weak self] _ in self?.close() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            self?.handleKey(e) ?? e
        }) {
            monitors.append(m)
        }
    }

    private func stopMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        guard !ui.typing, e.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "w" { close(); return nil }
            return e
        }
        if let key = key(for: e) { tv.send(key); return nil }
        if e.keyCode == 53 { close(); return nil } // Esc
        if e.charactersIgnoringModifiers?.lowercased() == "k" { ui.keyboardOpen = true; return nil }
        return e
    }

    private func key(for e: NSEvent) -> Key? {
        switch e.keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 36, 76: return .center      // Return / keypad Enter
        case 51: return .back            // Backspace
        case 49: return .playPause       // Space
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "h": return .home
        case "m": return .mute
        case "=", "+": return .volumeUp
        case "-", "_": return .volumeDown
        default: return nil
        }
    }

    // MARK: menu

    private func showMenu() {
        close()
        let menu = NSMenu()
        menu.addItem(withTitle: "Головний екран", action: #selector(home), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let tvMenu = NSMenu()
        for d in tv.devices {
            let item = tvMenu.addItem(withTitle: d.name, action: #selector(pickTV(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d
            item.state = d.id == tv.device?.id ? .on : .off
        }
        if !tv.devices.isEmpty { tvMenu.addItem(.separator()) }
        tvMenu.addItem(withTitle: "Шукати телевізори…", action: #selector(searchTVs), keyEquivalent: "").target = self
        let tvItem = menu.addItem(withTitle: "Телевізор", action: nil, keyEquivalent: "")
        tvItem.submenu = tvMenu
        let login = menu.addItem(withTitle: "Запускати при вході", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Сполучити з TV заново", action: #selector(forget), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Про MacMote", action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Вийти з MacMote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func home() { tv.connect(); tv.send(.home) }
    @objc private func pickTV(_ item: NSMenuItem) { if let d = item.representedObject as? TVDevice { tv.select(d) } }

    @objc private func searchTVs() {
        if panel == nil { open() }
        tv.scan(choose: true)
    }
    @objc private func forget() { tv.forget() }

    @objc private func about() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Пульт для Android TV / Google TV у рядку меню.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11)]),
        ])
    }

    @objc private func toggleLogin() {
        let s = SMAppService.mainApp
        try? (s.status == .enabled ? s.unregister() : s.register())
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
