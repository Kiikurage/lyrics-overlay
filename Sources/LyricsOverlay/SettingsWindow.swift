import AppKit
import SwiftUI

/// 設定ウィンドウ。閉じても破棄せず、次に開いたときは同じものを出す。
@MainActor
final class SettingsWindowController {
    private let style: OverlayStyle
    private let controller: LyricsController
    private var window: NSWindow?

    init(style: OverlayStyle, controller: LyricsController) {
        self.style = style
        self.controller = controller
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Lyrics Overlay 設定"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(
                rootView: SettingsView(
                    style: style, controller: controller, status: controller.audioStatus))
            w.center()
            window = w
        }
        // アクセサリアプリなので、明示的に前面へ出さないとフォーカスが当たらない。
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var style: OverlayStyle
    let controller: LyricsController
    @ObservedObject var status: AudioStatus

    /// 環境にある全ファミリだと多すぎるので、日本語が出せるものを優先して並べる。
    private static let families: [String] = {
        let all = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
        let preferred = ["Rounded M+ 1c", "Hiragino Maru Gothic ProN", "Hiragino Sans",
                         "Hiragino Kaku Gothic ProN", "Hiragino Mincho ProN", "YuGothic", "YuMincho"]
        let head = preferred.filter(all.contains)
        return head + all.filter { !head.contains($0) }
    }()

    var body: some View {
        VStack(spacing: 0) {
            preview
            Divider()
            form
        }
        .frame(width: 460)
    }

    /// 設定した内容をそのまま確認できるように、オーバーレイと同じ描画で見本を出す。
    private var preview: some View {
        ZStack {
            // 明るい背景でも暗い背景でも縁取りの効きを確かめられるようにしておく。
            LinearGradient(
                colors: [Color(white: 0.85), Color(white: 0.15)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            OutlinedText("この街の夜明けを Sing a Song 123", style: style)
                .padding(.horizontal, 20)
        }
        .frame(height: max(120, style.fontSize * 3.6))
    }

    private var form: some View {
        Form {
            Section("フォント") {
                LabeledContent("書体") {
                    FontFamilyPicker(
                        selection: $style.fontFamily,
                        families: Self.families,
                        onHover: { style.previewFamily = $0 })
                }
                Picker("太さ", selection: $style.weight) {
                    ForEach(OverlayStyle.Weight.allCases) { w in
                        Text(w.label).tag(w)
                    }
                }
                .pickerStyle(.segmented)
                slider("文字サイズ", value: $style.fontSize, range: 12...80, unit: "pt")
            }
            Section("配置") {
                Picker("揃え", selection: $style.alignment) {
                    ForEach(OverlayStyle.Alignment.allCases) { a in
                        Text(a.label).tag(a)
                    }
                }
                .pickerStyle(.segmented)
                Text("揃えた側の端を固定したまま、歌詞の長さに合わせてウィンドウが伸び縮みします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("行の切り替え") {
                Picker("演出", selection: $style.transition) {
                    ForEach(OverlayStyle.Transition.allCases) { t in
                        Text(t.label).tag(t)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("スペクトラム") {
                Toggle("再生中の音を解析して表示", isOn: $style.showSpectrum)
                if style.showSpectrum {
                    LabeledContent("状態") {
                        Label(
                            status.isActive ? "音声を受信中" : "音声が届いていません",
                            systemImage: status.isActive ? "waveform" : "exclamationmark.triangle")
                            .foregroundStyle(status.isActive ? Color.green : Color.orange)
                    }
                    HStack {
                        Spacer()
                        Button("許可を求め直す") { controller.resetAudioPermission() }
                        Button("システム設定を開く") {
                            NSWorkspace.shared.open(URL(
                                string: "x-apple.systempreferences:com.apple.preference.security"
                                    + "?Privacy_AudioCapture")!)
                        }
                    }
                }
                Text("Spotify の音声だけを取り込みます。出力先の設定は変わりません。"
                     + "許可を拒否した場合、macOS は同じ確認を出しません。"
                     + "「許可を求め直す」で記録を消すと、もう一度確認が出ます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Spacer()
                    Button("既定に戻す") { style.reset() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func slider(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String
    ) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue))\(unit)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
