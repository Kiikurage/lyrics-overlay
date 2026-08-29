import AppKit
import SwiftUI

/// 常に最前面に浮かぶ、枠なし・透過のパネル。
/// フォーカスを奪わないよう .nonactivatingPanel を使う。
final class OverlayPanel: NSPanel {
    private static let frameKey = "OverlayFrameOrigin"

    init(model: OverlayModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 132),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // 全 Space と、他アプリのフルスクリーン上にも表示する。
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        contentView = NSHostingView(rootView: OverlayView(model: model))
        restorePosition()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// クリック透過。有効な間はドラッグで動かせなくなる。
    var isClickThrough: Bool = false {
        didSet { ignoresMouseEvents = isClickThrough }
    }

    private func restorePosition() {
        if let s = UserDefaults.standard.string(forKey: Self.frameKey) {
            setFrameOrigin(NSPointFromString(s))
        } else if let screen = NSScreen.main {
            let v = screen.visibleFrame
            setFrameOrigin(NSPoint(x: v.midX - frame.width / 2, y: v.minY + 80))
        }
    }

    func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.frameKey)
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack(spacing: 6) {
            if let status = model.status {
                Text(status)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                line(model.previous, size: 16, opacity: 0.35)
                Text(model.current)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .id(model.current)
                    .transition(.opacity)
                line(model.next, size: 16, opacity: 0.35)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .shadow(color: .black.opacity(0.85), radius: 4, y: 1)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 16))
        .animation(.easeInOut(duration: 0.22), value: model.current)
    }

    @ViewBuilder
    private func line(_ text: String, size: CGFloat, opacity: Double) -> some View {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(.white.opacity(opacity))
    }
}
