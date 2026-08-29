import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let controller = LyricsController()
    private var panel: OverlayPanel!
    private var statusItem: NSStatusItem!
    private var clickThroughItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = OverlayPanel(model: controller.model)
        panel.delegate = self
        panel.orderFrontRegardless()

        setUpStatusItem()
        controller.start()
    }

    func windowDidMove(_ notification: Notification) {
        panel.savePosition()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "quote.bubble", accessibilityDescription: "Lyrics Overlay")

        let menu = NSMenu()
        clickThroughItem = NSMenuItem(
            title: "クリック透過", action: #selector(toggleClickThrough), keyEquivalent: "")
        clickThroughItem.target = self
        menu.addItem(clickThroughItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func toggleClickThrough() {
        panel.isClickThrough.toggle()
        clickThroughItem.state = panel.isClickThrough ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// main.swift のトップレベルは実際にはメインスレッドで走る。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // delegate は app が弱参照するため、run() の間だけ強参照を保つ。
    withExtendedLifetime(delegate) { app.run() }
}
