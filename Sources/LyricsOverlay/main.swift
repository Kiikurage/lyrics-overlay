import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let style = OverlayStyle()
    private lazy var controller = LyricsController(style: style)
    private lazy var settings = SettingsWindowController(style: style, controller: controller)
    private var panel: OverlayPanel!
    private var statusItem: NSStatusItem!
    private var clickThroughItem: NSMenuItem!
    private var spectrumObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = OverlayPanel(
            model: controller.model, spectrum: controller.spectrum, style: style)
        panel.delegate = self
        panel.orderFrontRegardless()

        setUpStatusItem()
        controller.start()

        // 設定でスペクトラムを切り替えたら、タップを開始/停止する。
        spectrumObserver = style.$showSpectrum.sink { [weak self] enabled in
            DispatchQueue.main.async { self?.controller.setSpectrumEnabled(enabled) }
        }
    }

    func windowDidMove(_ notification: Notification) {
        panel.savePosition()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "quote.bubble", accessibilityDescription: "Lyrics Overlay")

        let menu = NSMenu()

        // いま流れている曲。メニューを開いている間も表示は更新される。
        let header = NSMenuItem()
        let hosting = NSHostingView(rootView: MenuHeader(model: controller.model))
        hosting.frame = NSRect(
            x: 0, y: 0, width: MenuHeader.width, height: MenuHeader.height)
        header.view = hosting
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        clickThroughItem = NSMenuItem(
            title: "クリック透過", action: #selector(toggleClickThrough), keyEquivalent: "")
        clickThroughItem.target = self
        menu.addItem(clickThroughItem)
        let settingsItem = NSMenuItem(
            title: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
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

    @objc private func openSettings() {
        settings.show()
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
