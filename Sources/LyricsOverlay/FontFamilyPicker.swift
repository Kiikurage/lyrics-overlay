import AppKit
import SwiftUI

/// フォント選択のポップアップ。フォント名は **そのフォント自身で** 描く。
/// さらに項目にカーソルを乗せた時点で `onHover` を呼ぶので、
/// 決定しなくてもプレビューで確認できる(SwiftUI の Picker では両方できない)。
struct FontFamilyPicker: NSViewRepresentable {
    @Binding var selection: String
    let families: [String]
    /// ハイライト中のファミリ。メニューを閉じたら nil。
    let onHover: (String?) -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))

        let menu = NSMenu()
        for family in families {
            let item = NSMenuItem()
            item.attributedTitle = Self.label(for: family)
            item.representedObject = family
            menu.addItem(item)
        }
        menu.delegate = context.coordinator
        button.menu = menu
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if let index = families.firstIndex(of: selection), button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// フォント名をそのフォントで描く。和文が出せるフォントなら見本も添える。
    /// 記号フォントなど名前を表示できないものは、読めなくなるのでシステムフォントに逃がす。
    private static func label(for family: String) -> NSAttributedString {
        let size: CGFloat = 14
        guard let font = NSFontManager.shared.font(
            withFamily: family, traits: [], weight: 5, size: size) else {
            return NSAttributedString(string: family)
        }
        let covered = font.coveredCharacterSet
        guard family.unicodeScalars.allSatisfy(covered.contains) else {
            return NSAttributedString(
                string: family, attributes: [.font: NSFont.systemFont(ofSize: size)])
        }

        let sample = "あア亜"
        let text = sample.unicodeScalars.allSatisfy(covered.contains)
            ? "\(family)  —  \(sample)" : family
        return NSAttributedString(string: text, attributes: [.font: font])
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: FontFamilyPicker

        init(parent: FontFamilyPicker) {
            self.parent = parent
        }

        @objc func select(_ sender: NSPopUpButton) {
            guard let family = sender.selectedItem?.representedObject as? String else { return }
            parent.selection = family
        }

        // ホバー(キーボードでの移動も含む)しただけでプレビューを更新する。
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            parent.onHover(item?.representedObject as? String)
        }

        func menuDidClose(_ menu: NSMenu) {
            parent.onHover(nil)
        }
    }
}
